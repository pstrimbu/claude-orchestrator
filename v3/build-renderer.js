const esbuild = require('esbuild');
const { copyFileSync, mkdirSync, existsSync } = require('fs');
const { join } = require('path');

const outdir = join(__dirname, 'dist', 'renderer');
mkdirSync(outdir, { recursive: true });

// Bundle renderer TS + xterm into a single JS file
esbuild.buildSync({
  entryPoints: [join(__dirname, 'src', 'renderer', 'renderer.ts')],
  bundle: true,
  outfile: join(outdir, 'renderer.js'),
  format: 'iife',
  platform: 'browser',
  target: 'chrome120',
  sourcemap: true,
  external: ['electron'],
});

// Copy static files
copyFileSync(
  join(__dirname, 'src', 'renderer', 'index.html'),
  join(outdir, 'index.html'),
);
copyFileSync(
  join(__dirname, 'src', 'renderer', 'styles.css'),
  join(outdir, 'styles.css'),
);
copyFileSync(
  join(__dirname, 'node_modules', '@xterm', 'xterm', 'css', 'xterm.css'),
  join(outdir, 'xterm.css'),
);

console.log('Renderer built.');
