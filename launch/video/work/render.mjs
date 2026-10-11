// Render the film page frame by frame with Playwright and pipe PNGs into ffmpeg.
//   node render.mjs <guide|short> <out.mp4> [--frames a-b] [--stills n1,n2,... --dir out/]
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import path from "node:path";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [cut, out, ...rest] = process.argv.slice(2);
const opt = {};
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, "")] = rest[i + 1];

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell",
  args: ["--font-render-hinting=none", "--disable-lcd-text", "--force-color-profile=srgb", "--hide-scrollbars"],
});
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
page.on("console", (m) => { if (m.type() === "error") console.error("page:", m.text()); });
page.on("pageerror", (e) => console.error("pageerror:", e.message));
await page.goto("file://" + path.join(HERE, "film", "index.html") + "?cut=" + cut);
await page.waitForFunction(() => window.ready || window.initError, null, { timeout: 60000 });
const err = await page.evaluate(() => window.initError);
if (err) { console.error(err); process.exit(1); }
const info = await page.evaluate(() => window.FILM);
fs.writeFileSync(path.join(HERE, "tmp", `timeline-${cut}.json`), JSON.stringify(info, null, 1));
console.log(`cut=${cut} frames=${info.frames} (${(info.frames / info.fps).toFixed(2)} s)`);

if (opt.stills) {
  fs.mkdirSync(opt.dir, { recursive: true });
  for (const s of opt.stills.split(",")) {
    const n = Math.round(Number(s));
    await page.evaluate((n) => window.renderFrame(n), n);
    await page.screenshot({ path: path.join(opt.dir, `${cut}-${String(n).padStart(5, "0")}.png`) });
  }
  await browser.close();
  process.exit(0);
}

let [a, b] = opt.frames ? opt.frames.split("-").map(Number) : [0, info.frames - 1];
const ff = spawn("ffmpeg", ["-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", "30", "-c:v", "png", "-i", "-",
  "-c:v", "libx264", "-profile:v", "high", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
  "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
  "-movflags", "+faststart", "-an", out], { stdio: ["pipe", "inherit", "inherit"] });
const t0 = Date.now();
for (let n = a; n <= b; n++) {
  await page.evaluate((n) => window.renderFrame(n), n);
  const png = await page.screenshot({ type: "png" });
  if (!ff.stdin.write(png)) await new Promise((r) => ff.stdin.once("drain", r));
  if (n % 150 === 0) console.log(`frame ${n}/${b} ${((Date.now() - t0) / 1000).toFixed(0)}s`);
}
ff.stdin.end();
await new Promise((r) => ff.on("close", r));
await browser.close();
console.log("done", out);
