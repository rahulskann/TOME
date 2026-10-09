// Rasterise every build/svg/*.svg at its own size (1024 for icons) into build/png/.
// Lighting filters work per pixel, so icons are always rendered at 1024 and scaled
// down afterwards (build.py), never rendered small.
import { Resvg } from '@resvg/resvg-js';
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';

mkdirSync('build/png', { recursive: true });
for (const f of readdirSync('build/svg').filter((f) => f.endsWith('.svg'))) {
  const svg = readFileSync(`build/svg/${f}`, 'utf8');
  const png = new Resvg(svg, { font: { loadSystemFonts: true } }).render().asPng();
  writeFileSync(`build/png/${f.replace(/\.svg$/, '.png')}`, png);
}
console.log('rendered');
