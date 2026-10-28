// Contributor-only build. Emits exactly index.html, app.js, and styles.css into the skill's
// dashboard folder, which the PowerShell server serves as fixed static assets.
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

const root = fileURLToPath(new URL('.', import.meta.url));
const outDir = fileURLToPath(new URL('../skill/claudecx/dashboard', import.meta.url));

// React's production build links minified error codes to react.dev, and the Markdown libraries
// link deprecation messages to their GitHub pages. The dashboard must not reference any external
// origin, so those documentation links are replaced with neutral text at build time.
const offlineErrorText = {
  name: 'claudecx-offline-error-text',
  renderChunk(code) {
    const offline = code
      .replaceAll('https://react.dev/errors/', 'react-error:')
      .replace(/https:\/\/github\.com\/[A-Za-z0-9._\/#-]*/g, 'library-docs');
    return { code: offline, map: null };
  }
};

export default defineConfig({
  root,
  base: '/',
  publicDir: false,
  logLevel: 'warn',
  esbuild: { jsx: 'automatic', legalComments: 'none' },
  define: { 'process.env.NODE_ENV': '"production"' },
  plugins: [offlineErrorText],
  build: {
    outDir,
    emptyOutDir: true,
    sourcemap: false,
    modulePreload: false,
    cssCodeSplit: false,
    assetsInlineLimit: 0,
    target: 'es2022',
    rollupOptions: {
      onwarn(warning, warn) {
        // lucide-react marks modules "use client"; the directive is meaningless in this bundle.
        if (warning.code === 'MODULE_LEVEL_DIRECTIVE') { return; }
        warn(warning);
      },
      output: {
        entryFileNames: 'app.js',
        chunkFileNames: 'app-[name].js',
        assetFileNames: 'styles.css',
        inlineDynamicImports: true
      }
    }
  }
});
