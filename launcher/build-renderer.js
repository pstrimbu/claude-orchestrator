const esbuild = require('esbuild');
const { copyFileSync, mkdirSync } = require('fs');
const { join } = require('path');

const outdir = join(__dirname, 'dist', 'renderer');
mkdirSync(outdir, { recursive: true });

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

copyFileSync(join(__dirname, 'src', 'renderer', 'index.html'), join(outdir, 'index.html'));
copyFileSync(join(__dirname, 'src', 'renderer', 'styles.css'), join(outdir, 'styles.css'));

console.log('Launcher renderer built.');
