# Jarvis Web Playground

Phase 2 React/Vite Playground for exercising the Jarvis Agent API.

## Local development

Requires Node.js 22.18 or newer. Start the API first, then the web app.

```bash
# api/
npx wrangler dev

# web/
cp .env.example .env.local
# Set JARVIS_API_TOKEN in .env.local to the same local API token.
npm install
npm run dev
```

`VITE_AGENT_API_URL` is browser-visible and defaults to `/api/agent/message`.
`AGENT_API_ORIGIN` and `JARVIS_API_TOKEN` are read only by the local Vite server; the
token is added by the development proxy and is not included in the browser bundle.

## Verify

```bash
npm test
npm run build
```
