// Layout proof for the film page, without rendering video:
//   node check-layout.mjs <guide|short> [step]
// For every `step`-th frame (and every caption's midpoint) it checks:
//   1. captions: at most 2 lines, and no line holds a single word (no orphans)
//   2. the opening caption breaks as "One task. One finish line." / "Your coding agents know both."
//   3. menu-bar titles and clock: either fully inside the 1920x1080 frame or invisible (opacity < 0.02)
// Exits 1 on any failure and prints each one.
import { chromium } from "playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const cut = process.argv[2] || "guide";
const step = Number(process.argv[3] || 3);
const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell",
  args: ["--font-render-hinting=none", "--disable-lcd-text", "--force-color-profile=srgb", "--hide-scrollbars"],
});
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
page.on("pageerror", (e) => console.error("pageerror:", e.message));
await page.goto("file://" + path.join(HERE, "film", "index.html") + "?cut=" + cut);
await page.waitForFunction(() => window.ready || window.initError, null, { timeout: 60000 });
const info = await page.evaluate(() => window.FILM);
const frames = new Set();
for (let n = 0; n < info.frames; n += step) frames.add(n);
for (const c of info.timeline.captions) frames.add(Math.round(((c.t0 + c.t1) / 2) * 30));

const fails = [];
const seen = new Map();
for (const n of [...frames].sort((a, b) => a - b)) {
  await page.evaluate((n) => window.renderFrame(n), n);
  const r = await page.evaluate(() => {
    const out = { lines: null, menu: [] };
    const cap = document.getElementById("caption");
    const line = cap.querySelector(".line");
    if (Number(getComputedStyle(cap).opacity) > 0.02 && line.textContent) {
      // group words by the top of their line box
      const rows = [];
      const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
      for (let node; (node = walker.nextNode()); ) {
        const re = /\S+/g;
        for (let m; (m = re.exec(node.data)); ) {
          const rg = document.createRange();
          rg.setStart(node, m.index); rg.setEnd(node, m.index + m[0].length);
          const top = Math.round(rg.getClientRects()[0].top);
          let row = rows.find((x) => Math.abs(x.top - top) < 6);
          if (!row) rows.push((row = { top, words: [] }));
          row.words.push(m[0]);
        }
      }
      out.lines = rows.sort((a, b) => a.top - b.top).map((x) => x.words.join(" "));
    }
    const vis = (el) => {
      let o = 1;
      for (let e = el; e; e = e.parentElement) o *= Number(getComputedStyle(e).opacity);
      return o;
    };
    for (const el of document.querySelectorAll("#menubar .menus span, #menubar .clock")) {
      const b = el.getBoundingClientRect();
      out.menu.push({ text: el.textContent, left: b.left, right: b.right, top: b.top, bottom: b.bottom, op: vis(el) });
    }
    return out;
  });
  const t = (n / 30).toFixed(2);
  if (r.lines) {
    const key = r.lines.join(" / ");
    if (!seen.has(key)) seen.set(key, t);
    if (r.lines.length > 2) fails.push(`${t}s caption has ${r.lines.length} lines: ${key}`);
    if (r.lines.length > 1 && r.lines.some((l) => !l.includes(" "))) fails.push(`${t}s caption orphan: ${key}`);
    if (r.lines.join(" ").startsWith("One task.") &&
        key !== "One task. One finish line. / Your coding agents know both.")
      fails.push(`${t}s opening caption breaks as: ${key}`);
  }
  for (const m of r.menu) {
    const clipped = m.left < 0 || m.right > 1920 || m.top < 0 || m.bottom > 1080;
    if (clipped && m.op >= 0.02) fails.push(`${t}s menu "${m.text}" clipped (${m.left.toFixed(0)}..${m.right.toFixed(0)}) at opacity ${m.op.toFixed(2)}`);
  }
}
await browser.close();
console.log(`cut=${cut} frames checked=${frames.size}`);
for (const [k, t] of seen) console.log(`  caption @${t}s: ${k}`);
const uniq = [...new Set(fails)];
for (const f of uniq.slice(0, 40)) console.log("FAIL", f);
if (uniq.length > 40) console.log(`... ${uniq.length - 40} more`);
console.log(uniq.length ? `layout: FAIL (${uniq.length})` : "layout: PASS");
process.exit(uniq.length ? 1 : 0);
