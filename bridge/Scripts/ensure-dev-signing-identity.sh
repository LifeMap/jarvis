#!/bin/zsh
set -euo pipefail

# Creates a local self-signed code-signing certificate in the login keychain, once.
# Ad-hoc signatures bind TCC (Accessibility) to the binary CDHash, so every rebuild
# looks like a new app. A stable certificate keeps the same designated requirement.

cert_name="${JARVIS_CODESIGN_IDENTITY:-Jarvis Call Bridge Dev}"

if security find-identity -p codesigning | grep -F -q "$cert_name"; then
    echo "Codesigning identity already present: $cert_name"
    security find-identity -p codesigning | grep -F "$cert_name"
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cat > "$workdir/codesign.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[req_distinguished_name]
CN = $cert_name
O = Jarvis

[v3_codesign]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -new -x509 -days 3650 -nodes \
    -newkey rsa:2048 \
    -keyout "$workdir/dev.key" \
    -out "$workdir/dev.crt" \
    -config "$workdir/codesign.cnf"

p12_pass="jarvis-local-dev"
# OpenSSL 3's default PKCS12 is not importable by macOS Security.framework.
openssl pkcs12 -export -legacy \
    -inkey "$workdir/dev.key" \
    -in "$workdir/dev.crt" \
    -out "$workdir/dev.p12" \
    -passout "pass:$p12_pass" \
    -name "$cert_name"

security import "$workdir/dev.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$p12_pass" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Allow codesign to use the key without a prompt on later builds. Fails if the
# login keychain password is not empty and cannot be supplied here — first
# codesign will then show a keychain dialog; click Always Allow.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" \
    "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true

if ! security find-identity -p codesigning | grep -F -q "$cert_name"; then
    echo "error: certificate import did not produce a codesigning identity." >&2
    exit 1
fi

echo "Created codesigning identity: $cert_name"
echo "Grant Accessibility once after the next app launch. Later rebuilds should keep it."
