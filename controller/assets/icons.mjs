// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { mkdir, readFile, writeFile } from 'node:fs/promises';

// Keep only the symbols used by Mondek; icon geometry comes from the locked package.
const icons = {
  grid: 'grid-2x2', pulse: 'activity', sliders: 'sliders-vertical', server: 'server',
  disk: 'hard-drive', globe: 'globe', code: 'code-xml', shield: 'shield-check',
  send: 'send', clock: 'clock', check: 'check', plus: 'plus',
  arrow: 'arrow-right', back: 'arrow-left', info: 'info', terminal: 'square-terminal',
};
const symbols = await Promise.all(Object.entries(icons).map(async ([name, file]) => {
  const source = await readFile(new URL(`./node_modules/lucide-static/icons/${file}.svg`, import.meta.url), 'utf8');
  const body = source.match(/<svg\b[^>]*>([\s\S]*?)<\/svg>/)?.[1];
  if (!body) throw new Error(`Invalid icon SVG: ${file}`);
  return `<symbol id="${name}" viewBox="0 0 24 24">${body}</symbol>`;
}));
const output = new URL('../priv/static/assets/', import.meta.url);
await mkdir(output, { recursive: true });
await writeFile(new URL('icons.svg', output), `<svg xmlns="http://www.w3.org/2000/svg">${symbols.join('')}</svg>\n`);
