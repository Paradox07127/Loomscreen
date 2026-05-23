import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const bundleOutDir = path.resolve(
  here,
  "..",
  "LiveWallpaper",
  "Resources",
  "wpe-webgl-runtime.bundle"
);

// WPE_DEV_BUILD=1 npm run build → keeps inline source maps + non-minified
// output so Safari Web Inspector can step through the TypeScript sources
// instead of the minified one-liner. Release/CI runs unchanged.
const isDevBuild = process.env.WPE_DEV_BUILD === "1";

export default defineConfig({
  root: here,
  base: "/",
  publicDir: false,
  build: {
    outDir: bundleOutDir,
    emptyOutDir: true,
    target: "es2022",
    modulePreload: false,
    minify: isDevBuild ? false : "esbuild",
    sourcemap: isDevBuild ? "inline" : false,
    rollupOptions: {
      output: {
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name][extname]"
      }
    }
  },
  server: {
    port: 5173,
    strictPort: true,
    host: "127.0.0.1"
  }
});
