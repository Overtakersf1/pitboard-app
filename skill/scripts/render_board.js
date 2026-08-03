#!/usr/bin/env node
// Render a PitBoard board.json to PNG using the PitBoard web renderer.
// Usage: node render_board.js <index.html> <board.json> <out.png> [x0 y0 x1 y1 [zoom]]
//   No region args: auto-fit all content. With region: frame that world-rect.
// Needs: npm i playwright ; a chromium (set executablePath below if preinstalled,
// e.g. /opt/pw-browsers/chromium in Anthropic sandboxes).

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

(async () => {
  const [, , htmlPath, boardPath, outPath, x0, y0, x1, y1, zoom] = process.argv;
  if (!htmlPath || !boardPath || !outPath) {
    console.error('usage: render_board.js <index.html> <board.json> <out.png> [x0 y0 x1 y1 [zoom]]');
    process.exit(1);
  }
  const board = fs.readFileSync(boardPath, 'utf8');
  const exec = fs.existsSync('/opt/pw-browsers/chromium') ? '/opt/pw-browsers/chromium' : undefined;
  const browser = await chromium.launch({ executablePath: exec, headless: true });
  const page = await browser.newPage({ viewport: { width: 1500, height: 1000 } });
  await page.goto('file://' + path.resolve(htmlPath));
  await page.waitForTimeout(400);
  await page.evaluate(({ json, region }) => {
    const d = JSON.parse(json);
    elements = d.elements;
    let rx0, ry0, rx1, ry1;
    if (region) { [rx0, ry0, rx1, ry1] = region; }
    else {
      rx0 = 1e9; ry0 = 1e9; rx1 = -1e9; ry1 = -1e9;
      for (const el of elements) {
        const b = bbox(el);
        rx0 = Math.min(rx0, b.x); ry0 = Math.min(ry0, b.y);
        rx1 = Math.max(rx1, b.x + b.w); ry1 = Math.max(ry1, b.y + b.h);
      }
      if (rx0 > rx1) { rx0 = 0; ry0 = 0; rx1 = 1500; ry1 = 1000; }
    }
    const s = region && region[4] ? region[4]
      : Math.min(1460 / Math.max(1, rx1 - rx0), 940 / Math.max(1, ry1 - ry0), 1.5);
    view = { x: -rx0 * s + 20, y: -ry0 * s + 30, s };
    paint();
  }, { json: board, region: (x0 !== undefined && y1 !== undefined)
        ? [+x0, +y0, +x1, +y1, zoom ? +zoom : 0] : null });
  await page.waitForTimeout(400);
  await page.screenshot({ path: outPath });
  await browser.close();
  console.log('rendered', outPath);
})();
