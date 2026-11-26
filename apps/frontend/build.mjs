// Bundles + minifies the SPA, fingerprints nothing (nginx sets cache headers
// by path instead), and bakes the build version in at compile time.
import { build } from 'esbuild';
import { cp, mkdir, rm } from 'node:fs/promises';

await rm('dist', { recursive: true, force: true });
await mkdir('dist/assets', { recursive: true });
await build({
  entryPoints: ['src/app.js', 'src/styles.css'],
  outdir: 'dist/assets',
  bundle: true,
  minify: true,
  sourcemap: false,
  target: ['es2022'],
  define: { __APP_VERSION__: JSON.stringify(process.env.APP_VERSION ?? 'dev') },
});
await cp('src/index.html', 'dist/index.html');
console.log('built dist/');
