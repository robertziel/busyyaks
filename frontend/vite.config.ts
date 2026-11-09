/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Builds into ../public/app; Hanami serves /app/* statically and reads .vite/manifest.json for the hashed names
// (app/actions/spa/show.rb). No HTML here: the shell is app/templates/app.html.erb (it carries the CSRF meta).
export default defineConfig({
  plugins: [react()],
  base: "/app/",
  publicDir: false,
  build: {
    outDir: "../public/app",
    emptyOutDir: true,
    manifest: true,
    sourcemap: false,
    rollupOptions: { input: "src/main.tsx" },
  },
  test: { include: ["src/**/*.test.ts"] },
});
