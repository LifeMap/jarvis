import react from "@vitejs/plugin-react";
import { defineConfig, loadEnv } from "vite";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const apiOrigin = env.AGENT_API_ORIGIN ?? "http://127.0.0.1:8787";
  const apiToken = env.JARVIS_API_TOKEN;

  return {
    plugins: [react()],
    server: {
      proxy: {
        "/api": {
          target: apiOrigin,
          changeOrigin: true,
          configure(proxy) {
            proxy.on("proxyReq", (proxyRequest) => {
              if (apiToken) proxyRequest.setHeader("authorization", `Bearer ${apiToken}`);
            });
          },
        },
      },
    },
    test: {
      environment: "jsdom",
      environmentOptions: { jsdom: { url: "http://localhost" } },
      setupFiles: "./src/test/setup.ts",
      css: true,
    },
  };
});
