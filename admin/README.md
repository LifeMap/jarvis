# Jarvis Admin

Phase 7 single-user control center. Requires Node.js 22.11 or newer.

```bash
cp .env.example .env.local
npm install
npm run dev
```

The Admin console is available at `http://127.0.0.1:5174`. Port 5174 is fixed so it does not
collide with the existing Web Playground on port 5173. The API must be running separately on the
`API_ORIGIN` address (port 8787 by default).

`VITE_API_BASE_URL` defaults to `/api`. During local development, Vite proxies `/api` to
`API_ORIGIN` and injects the server-only `JARVIS_API_TOKEN`; the token is not bundled into browser
JavaScript. For Cloudflare Pages, `functions/api/[[path]].ts` provides the equivalent server-side
proxy. Configure `JARVIS_API_ORIGIN` as a Pages environment variable and `JARVIS_API_TOKEN` as a
Pages Secret. Protect the whole Admin application with Cloudflare Access; the API Bearer token
remains defense in depth.

`VITE_PLAYGROUND_URL` can point the Playground navigation item to the deployed `web/` application.
API keys and OAuth tokens are never managed from Admin.
