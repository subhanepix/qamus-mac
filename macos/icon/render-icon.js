// Renders the Mac app icon from the Desk's sidebar logo (ink square, paper-coloured ق in Amiri).
// Output: macos/icon/AppIcon.png (1024×1024, macOS icon grid: 824px rounded square with a soft shadow).
// Usage (from the repo root): node macos/icon/render-icon.js
// Needs network once for the Amiri web font, the same font the Desk loads.
const path = require('node:path');
const repo = path.resolve(__dirname, '..', '..');
const { chromium } = require(path.join(repo, 'node_modules', '@playwright', 'test'));

const HTML = `<!doctype html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Amiri:wght@400;700&display=block" rel="stylesheet">
<style>
  html, body { margin: 0; width: 1024px; height: 1024px; background: transparent; }
  .tile {
    position: absolute; left: 100px; top: 100px; width: 824px; height: 824px; border-radius: 185px;
    /* Same ink and paper as the logo (--ink / --bg), with a faint top light so it reads as a tile in the Dock */
    background: linear-gradient(180deg, #2a2d30 0%, #1d1f21 55%, #17191b 100%);
    box-shadow: 0 10px 24px rgba(0, 0, 0, 0.28), 0 2px 4px rgba(0, 0, 0, 0.18), inset 0 1px 0 rgba(255, 255, 255, 0.08);
    display: grid; place-items: center; overflow: hidden;
  }
  .glyph { font: 400 600px/1 "Amiri", serif; color: #f6f5f1; transform: translateY(-34px); }
</style></head><body><div class="tile"><span class="glyph" lang="ar">ق</span></div></body></html>`;

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  await page.setContent(HTML, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  const amiri = await page.evaluate(() => document.fonts.check('600px Amiri', 'ق'));
  if (!amiri) throw new Error('Amiri did not load; the icon would use a fallback font');
  await page.screenshot({ path: path.join(__dirname, 'AppIcon.png'), omitBackground: true });
  await browser.close();
  console.log('wrote macos/icon/AppIcon.png');
})().catch(e => { console.error(e); process.exit(1); });
