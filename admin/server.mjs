import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

const PORT = Number(process.env.PORT ?? 5174);
const DIST_DIR = join(import.meta.dirname, "dist");
const API_ORIGIN = process.env.API_ORIGIN ?? "http://127.0.0.1:8787";
const JARVIS_API_TOKEN = process.env.JARVIS_API_TOKEN;

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

const HOP_BY_HOP_HEADERS = new Set(["host", "connection", "content-length", "transfer-encoding"]);

async function proxyApi(req, res, url) {
  const target = new URL(url.pathname + url.search, API_ORIGIN);
  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers)) {
    if (typeof value === "string" && !HOP_BY_HOP_HEADERS.has(key)) headers.set(key, value);
  }
  if (JARVIS_API_TOKEN) headers.set("authorization", `Bearer ${JARVIS_API_TOKEN}`);

  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = ["GET", "HEAD"].includes(req.method ?? "GET") ? undefined : Buffer.concat(chunks);

  const upstream = await fetch(target, { method: req.method, headers, body, redirect: "manual" });
  res.writeHead(upstream.status, {
    "content-type": upstream.headers.get("content-type") ?? "application/json",
    "cache-control": "no-store",
  });
  res.end(Buffer.from(await upstream.arrayBuffer()));
}

async function serveStatic(res, pathname) {
  const safePath = normalize(pathname).replace(/^(\.\.[/\\])+/, "");
  let filePath = join(DIST_DIR, safePath === "/" ? "index.html" : safePath);

  try {
    const stats = await stat(filePath);
    if (stats.isDirectory()) filePath = join(filePath, "index.html");
  } catch {
    filePath = join(DIST_DIR, "index.html");
  }

  try {
    const body = await readFile(filePath);
    res.writeHead(200, { "content-type": MIME_TYPES[extname(filePath)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("Not found");
  }
}

createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  try {
    if (url.pathname.startsWith("/api/")) {
      await proxyApi(req, res, url);
    } else {
      await serveStatic(res, url.pathname);
    }
  } catch {
    res.writeHead(502);
    res.end("Bad gateway");
  }
}).listen(PORT, "127.0.0.1", () => {
  console.log(`jarvis admin production server listening on http://127.0.0.1:${PORT}`);
});
