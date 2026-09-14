import { defineConfig } from "vite";
const proxy = {
  "/api": { target: "http://127.0.0.1:7070", changeOrigin: true },
};
export default defineConfig({
  server: { host: "127.0.0.1", port: 5173, strictPort: true, proxy },
  preview: { host: "127.0.0.1", port: 4173, strictPort: true, proxy },
});
