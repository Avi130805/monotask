// Monotask guide film. Everything on screen is a pure function of the frame number:
// window.renderFrame(n) sets the whole stage for frame n (30 fps). Springs are evaluated in
// closed form from the timeline, so any frame can be rendered on its own, in any order.
(function () {
  "use strict";
  const FPS = 30;
  const D = window.FILM_DATA;
  const CUT = new URLSearchParams(location.search).get("cut") || "guide";
  const S = 0.62;                     // notch frames in wide shots (2x sources; 1.0x = 1/S camera zoom)
  const ZMAX = 1 / S;                 // camera zoom at which the notch frames are shown 1:1
  const NOTCH = D.notch.frames;
  const HOLD = D.notch.hold;

  // ---------------------------------------------------------------------------------- maths
  const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
  const lerp = (a, b, p) => a + (b - a) * p;
  const smooth = (x) => { x = clamp(x, 0, 1); return x * x * (3 - 2 * x); };
  const easeOut = (x) => 1 - Math.pow(1 - clamp(x, 0, 1), 3);
  // Critically damped spring, step response (damping 1.0).
  function springCrit(t, response) {
    if (t <= 0) return 0;
    const w = (2 * Math.PI) / response;
    return 1 - (1 + w * t) * Math.exp(-w * t);
  }
  // Under-damped spring, step response (SwiftUI-style response/damping).
  function springUnder(t, response, zeta) {
    if (t <= 0) return 0;
    const w = (2 * Math.PI) / response;
    const wd = w * Math.sqrt(1 - zeta * zeta);
    return 1 - Math.exp(-zeta * w * t) * (Math.cos(wd * t) + ((zeta * w) / wd) * Math.sin(wd * t));
  }
  // A value driven by a list of keyframes {t, v (array), response}; each key springs from wherever the
  // previous motion was at that moment. Closed form and pure.
  function keyed(keys, t, defResponse) {
    let cur = keys[0].v.slice();
    for (let i = 1; i < keys.length && keys[i].t <= t; i++) {
      const k = keys[i];
      const until = i + 1 < keys.length && keys[i + 1].t <= t ? keys[i + 1].t : t;
      const p = springCrit(until - k.t, k.response || defResponse);
      cur = cur.map((s, j) => lerp(s, k.v[j], p));
    }
    return cur;
  }

  // ---------------------------------------------------------------------------------- geometry
  const notchLeft = 960 - 860 * S;
  const cw = (cx, cy) => [notchLeft + cx * S, cy * S];        // notch canvas px -> world px
  const NOTCH_HOME = cw(860, 34);                              // closed notch centre
  const ROW_PLAY = cw(991 + 300, 483);                         // v05b: the start control on "Fix login redirect"
  const FORM_START = cw(186 + 300, 381);                       // v06: Start button
  const HOLD_BTN = cw(HOLD.x + HOLD.w * 0.22, HOLD.y + HOLD.h / 2);
  const CHIN_HOVER = cw(690, 18);                              // hover point on the notch, clear of the chin text
  const REST = [1610, 960];                                    // where the pointer rests out of the way

  // Camera: world point (cx, cy) at screen centre, zoom z. Clamped so the desktop always fills the frame.
  function camFor(z, cx, cy) {
    const hw = 960 / z, hh = 540 / z;
    return [clamp(cx, hw, 1920 - hw), clamp(cy, hh, 1080 - hh), z];
  }
  const WIDE = [960, 540, 1];
  const notchShot = (z, cx = 960) => { const c = camFor(z, cx, 0); return [c[0], c[1], z]; };

  // ---------------------------------------------------------------------------------- terminal
  const termWins = {};
  function makeTerminal(key, title) {
    const cast = D.casts[key];
    const win = document.createElement("div");
    win.className = "win";
    win.innerHTML = `<div class="bar"><div class="lights"><i></i><i></i><i></i></div>${title}<div class="badge"></div></div><div class="body"></div>`;
    document.getElementById("windows").appendChild(win);
    const term = new Terminal({
      cols: cast.cols, rows: cast.rows, fontFamily: '"JetBrains Mono"', fontSize: 18, lineHeight: 1.0,
      cursorBlink: false, cursorStyle: "block", cursorInactiveStyle: "block", scrollback: 0,
      drawBoldTextInBrightColors: false, minimumContrastRatio: 1, allowProposedApi: true,
      theme: {
        background: "#1E1E1E", foreground: "#E8E8E8", cursor: "#C7C7C7", cursorAccent: "#1E1E1E",
        black: "#000000", red: "#E2513F", green: "#3FC24A", yellow: "#D8C72E", blue: "#5A8CF0",
        magenta: "#D35DD3", cyan: "#4FC2CE", white: "#CBCCCD",
        brightBlack: "#7F8184", brightRed: "#FC5E4A", brightGreen: "#58E35E", brightYellow: "#EDE55C",
        brightBlue: "#7DA6FF", brightMagenta: "#F06EF0", brightCyan: "#5DEDEF", brightWhite: "#F2F2F2",
      },
    });
    term.open(win.querySelector(".body"));
    const st = { key, cast, win, term, idx: 0, castT: -1, badge: win.querySelector(".badge") };
    termWins[key] = st;
    return st;
  }
  async function seekTerminal(st, castT) {
    if (castT < st.castT) { st.term.reset(); st.idx = 0; }
    st.castT = castT;
    const ev = st.cast.events;
    let chunk = "";
    while (st.idx < ev.length && ev[st.idx][0] <= castT) {
      if (ev[st.idx][1] === "o") chunk += ev[st.idx][2];
      st.idx++;
    }
    if (chunk) await new Promise((r) => st.term.write(chunk, r));
  }
  // A playback plan: segments [castStart, castEnd, speed] played back to back from film time t0.
  function plan(t0, segs) {
    let ft = t0;
    const s = segs.map(([a, b, speed]) => { const o = { a, b, speed, f0: ft, f1: ft + (b - a) / speed }; ft = o.f1; return o; });
    return {
      t0, end: ft, segs: s,
      castAt(t) {
        if (t <= s[0].f0) return s[0].a;
        for (const g of s) if (t < g.f1) return g.a + (t - g.f0) * g.speed;
        return s[s.length - 1].b;
      },
      filmAt(c) {               // film time at which cast time c plays (first segment containing it)
        for (const g of s) if (c >= g.a && c <= g.b) return g.f0 + (c - g.a) / g.speed;
        return null;
      },
      speedAt(t) { for (const g of s) if (t >= g.f0 && t < g.f1) return g.speed; return 1; },
    };
  }

  // ---------------------------------------------------------------------------------- notch
  const notchEl = document.getElementById("notch");
  const imgs = {};
  for (const name of Object.keys(NOTCH)) {
    const el = new Image();
    el.src = `../../assets/notch/${name}.png`;
    el.style.opacity = 0;
    notchEl.appendChild(el);
    imgs[name] = el;
  }
  const holdOverlay = new Image();
  holdOverlay.src = "../../assets/notch/v12b-holding-full.png";
  notchEl.appendChild(holdOverlay);
  const shape = document.createElement("div");
  shape.className = "shape";
  notchEl.insertBefore(shape, notchEl.firstChild);
  const extraImgs = [];   // clipped duplicates used during a morph (from / to)
  for (let i = 0; i < 2; i++) { const e = new Image(); notchEl.appendChild(e); extraImgs.push(e); }

  const box = (name) => NOTCH[name];
  function clipFor(b) {
    return `inset(${b.y}px ${1720 - (b.x + b.w)}px ${1200 - (b.y + b.h)}px ${b.x}px round 0 0 ${b.r}px ${b.r}px)`;
  }
  function renderNotch(events, t) {
    let i = -1;
    for (let k = 0; k < events.length; k++) if (events[k].t <= t) i = k;
    const e = events[Math.max(i, 0)];
    const prev = i > 0 ? events[i - 1].to : e.to;
    const tau = i >= 0 ? t - e.t : 999;
    for (const n in imgs) imgs[n].style.opacity = 0;
    shape.style.display = "none";
    extraImgs.forEach((x) => (x.style.display = "none"));
    holdOverlay.style.display = "none";

    const kind = i >= 0 ? e.kind : "cut";
    if (kind === "cut" || tau > 1.2) {
      imgs[e.to].style.opacity = 1;
      if (e.kind === "hold") showHold(e, tau);
      return;
    }
    if (kind === "fade") {
      imgs[prev].style.opacity = 1;
      imgs[e.to].style.opacity = smooth(tau / (e.dur || 0.22));
      return;
    }
    if (kind === "hold") { imgs[e.to].style.opacity = 1; showHold(e, tau); return; }
    // morph: one black shape springs between the two bodies; content cross-fades in the last 60 %
    const p = springUnder(tau, 0.45, 0.84);
    const A = box(prev), B = box(e.to);
    const b = { x: lerp(A.x, B.x, p), y: 0, w: lerp(A.w, B.w, p), h: lerp(A.h, B.h, p), r: lerp(A.r, B.r, p) };
    shape.style.display = "block";
    Object.assign(shape.style, { left: b.x + "px", top: "0px", width: b.w + "px", height: b.h + "px",
      borderRadius: `0 0 ${b.r}px ${b.r}px` });
    const q = clamp((p - 0.4) / 0.6, 0, 1);
    const [ea, eb] = extraImgs;
    ea.src = imgs[prev].src; eb.src = imgs[e.to].src;
    ea.style.display = eb.style.display = "block";
    ea.style.clipPath = eb.style.clipPath = clipFor(b);
    ea.style.opacity = clamp(1 - q * 1.4, 0, 1);
    eb.style.opacity = q;
    // the unclipped frame (ear flares, shadow) settles in at the end
    imgs[e.to].style.opacity = smooth((tau - 0.42) / 0.3);
    if (tau > 0.72) { shape.style.display = "none"; ea.style.display = eb.style.display = "none"; }
  }
  function showHold(e, tau) {
    // reveal v12b over v12a through a capsule growing left to right, linearly over e.dur (1.1 s)
    const f = clamp(tau / e.dur, 0, 1);
    if (f <= 0) return;
    const w = HOLD.w * f;
    holdOverlay.style.display = "block";
    holdOverlay.style.clipPath = `inset(${HOLD.y}px ${1720 - (HOLD.x + w)}px ${1200 - (HOLD.y + HOLD.h)}px ${HOLD.x}px round ${HOLD.h / 2}px)`;
  }

  // ---------------------------------------------------------------------------------- timelines
  function guideTimeline() {
    const T = { duration: 0, notch: [], cursor: [], clicks: [], presses: [], cam: [], captions: [], keys: [], wins: [] };
    const N = (t, to, kind = "morph", extra = {}) => T.notch.push({ t, to, kind, ...extra });
    const C = (t, xy, response) => T.cursor.push({ t, v: xy.slice(), response });
    const K = (t, v, response) => T.cam.push({ t, v, response });
    const cap = (t0, t1, step, line) => T.captions.push({ t0, t1, step, line });

    // 1 · cold open on the payoff (0-4 s)
    N(0, "v09-peek-chin", "cut");
    C(0, CHIN_HOVER);
    K(0, notchShot(ZMAX));
    K(0.6, notchShot(1.3), 3.2);
    cap(0.5, 3.85, "", "One task. One finish line.\nYour coding agents know both.");

    // 2 · capture (4-11 s)
    C(4.0, REST, 0.7);
    N(4.15, "v01-closed-idle");
    K(4.3, notchShot(ZMAX));
    T.keys.push({ t: 4.9, keys: ["⌥", "Space"] });
    N(5.0, "v02-capture-empty");
    N(5.9, "v03a-capture-typing-1", "fade", { dur: 0.12 });
    N(6.45, "v03b-capture-typing-2", "fade", { dur: 0.12 });
    N(7.0, "v03-capture-typed", "fade", { dur: 0.12 });
    T.keys.push({ t: 7.9, keys: ["Return"] });
    N(8.0, "v04-flash-added");
    N(10.3, "v01-closed-idle");
    cap(4.4, 10.75, "1 · Capture", "⌥Space from any app.\nType it, press Return. It waits in Do Next.");

    // 3 · start one task (11-21 s)
    K(10.9, [960, 540 / 1.42, 1.42]);
    C(11.0, NOTCH_HOME, 0.75);
    T.clicks.push(12.0);
    N(12.05, "v05-open-list");
    C(12.7, ROW_PLAY, 0.6);
    N(13.25, "v05b-open-row-hover", "fade", { dur: 0.16 });
    T.clicks.push(14.0);
    N(14.1, "v06a-start-form-typing-1");
    N(15.1, "v06b-start-form-typing-2", "fade", { dur: 0.12 });
    N(15.9, "v06-start-form", "fade", { dur: 0.12 });
    C(16.0, FORM_START, 0.55);
    T.keys.push({ t: 17.0, keys: ["Return"] });
    N(17.1, "v07-open-now");
    cap(11.2, 20.7, "2 · Start one task", "Write what done means. That's your finish line.");

    // 4 · it sits in the notch (21-25 s)
    C(20.6, REST, 0.7);
    N(21.0, "v08-closed-wings");
    K(21.0, notchShot(ZMAX));
    C(22.3, CHIN_HOVER, 0.7);
    N(23.0, "v09-peek-chin");
    cap(21.2, 24.85, "2 · Start one task", "It sits in your notch.\nHover to see the task and its finish line.");

    // 5 · Claude Code (25-~47 s)
    C(25.0, REST, 0.7);
    N(25.1, "v08-closed-wings");
    K(25.0, WIDE, 0.8);
    const p1 = plan(25.9, [
      [1.1, 4.5, 1], [4.5, 6.2, 1], [6.2, 8.0, 1],
      [8.0, 15.3, 6], [15.3, 16.4, 1], [16.4, 22.4, 6],
      [22.4, 27.4, 1], [27.4, 29.6, 4], [29.6, 31.9, 1],
      [31.9, 34.42, 1], [34.42, 35.6, 2], [35.6, 36.9, 1],
    ]);
    T.wins.push({ key: "r1", title: "shop – claude", plan: p1, tIn: 25.0, tOut: p1.end + 1.6, from: "below" });
    const reply = p1.filmAt(22.48), added = p1.filmAt(35.77), approve = p1.filmAt(34.42), yes = p1.filmAt(29.69);
    T.r1 = { reply, added };
    T.finishRowKey = { t: reply + 0.5, back: reply + 3.4 };
    N(added, "v10-flash-added-side");
    N(added + 2.6, "v08-closed-wings");
    cap(25.3, reply - 0.2, "3 · Claude Code knows it", "Your task and finish line reach every session. Nothing to paste.");
    cap(reply, yes - 0.1, "3 · Claude Code knows it", "It stops at your finish line and says what's left.");
    cap(yes, p1.end + 1.4, "3 · Claude Code knows it", "Side work goes to Do Next, only with your yes.");

    // 6 · Codex (no OPENAI_API_KEY in the VM: the 4-second card)
    const c0 = p1.end + 1.7;
    T.wins.push({ key: "codex-card", tIn: c0, tOut: c0 + 4.4, from: "right" });
    cap(c0 + 0.2, c0 + 4.3, "4 · Codex too", "Same plugin, same one task. Trust its hooks once with /hooks.");

    // 7 · only you finish it
    const h0 = c0 + 4.9;
    K(h0, [960, 540 / 1.25, 1.25]);
    C(h0 + 0.1, NOTCH_HOME, 0.7);
    T.clicks.push(h0 + 1.0);
    N(h0 + 1.05, "v11-open-side-task");
    C(h0 + 1.8, HOLD_BTN, 0.6);
    K(h0 + 2.0, camFor(ZMAX, 960, HOLD_BTN[1] + 120), 0.9);
    const press = h0 + 3.3;
    T.presses.push([press, press + 1.1]);
    N(press, "v12a-holding-start", "cut");
    N(press + 0.0001, "v12a-holding-start", "hold", { dur: 1.1 });
    N(press + 1.1 + 3 / FPS, "v13-done");
    N(press + 2.9, "v14-open-finished");
    cap(h0 + 0.6, press + 4.4, "5 · Only you finish it", "Hold to mark it done, once it's done end to end.");

    // 8 · end card
    const e0 = press + 4.8;
    C(e0 - 0.3, REST, 0.8);
    N(e0, "v01-closed-idle");
    K(e0 + 0.2, WIDE, 0.9);
    T.endcard = e0 + 1.0;
    T.duration = e0 + 7.6;
    return T;
  }

  function shortTimeline() {
    const T = { duration: 0, notch: [], cursor: [], clicks: [], presses: [], cam: [], captions: [], keys: [], wins: [] };
    const N = (t, to, kind = "morph", extra = {}) => T.notch.push({ t, to, kind, ...extra });
    const C = (t, xy, response) => T.cursor.push({ t, v: xy.slice(), response });
    const K = (t, v, response) => T.cam.push({ t, v, response });
    const cap = (t0, t1, step, line) => T.captions.push({ t0, t1, step, line });

    N(0, "v09-peek-chin", "cut");
    C(0, CHIN_HOVER);
    K(0, notchShot(ZMAX));
    K(0.4, notchShot(1.4), 2.6);
    cap(0.15, 2.9, "", "One task. One finish line.\nYour coding agents know both.");

    C(2.9, REST, 0.6);
    N(3.0, "v08-closed-wings");
    K(3.0, WIDE, 0.7);
    const p1 = plan(3.3, [
      [6.0, 8.0, 1], [8.0, 15.3, 8], [15.3, 16.2, 1], [16.2, 22.4, 8],
      [22.4, 25.6, 1], [25.6, 29.6, 8], [29.6, 31.9, 1], [31.9, 34.42, 1], [34.42, 35.6, 3], [35.6, 36.6, 1],
    ]);
    T.wins.push({ key: "r1", title: "shop – claude", plan: p1, tIn: 3.0, tOut: p1.end + 1.0, from: "below", preT: 6.0 });
    const reply = p1.filmAt(22.48), added = p1.filmAt(35.77), yes = p1.filmAt(29.69);
    T.r1 = { reply, added };
    T.finishRowKey = { t: reply + 0.35, back: reply + 2.6 };
    N(added, "v10-flash-added-side");
    N(added + 1.6, "v08-closed-wings");
    cap(3.2, reply - 0.1, "", "Claude Code gets your task and finish line.");
    cap(yes - 0.6, p1.end + 0.9, "", "Side work waits in Do Next. Only with your yes.");

    const h0 = p1.end + 1.2;
    K(h0, [960, 540 / 1.25, 1.25]);
    C(h0 + 0.05, NOTCH_HOME, 0.6);
    T.clicks.push(h0 + 0.7);
    N(h0 + 0.75, "v11-open-side-task");
    C(h0 + 1.3, HOLD_BTN, 0.5);
    K(h0 + 1.4, camFor(ZMAX, 960, HOLD_BTN[1] + 120), 0.8);
    const press = h0 + 2.5;
    T.presses.push([press, press + 1.1]);
    N(press, "v12a-holding-start", "cut");
    N(press + 0.0001, "v12a-holding-start", "hold", { dur: 1.1 });
    N(press + 1.1 + 3 / FPS, "v13-done");
    N(press + 2.6, "v14-open-finished");
    cap(h0 + 0.4, press + 3.8, "", "Only you mark it done.");

    const e0 = press + 4.0;
    C(e0 - 0.3, REST, 0.7);
    N(e0, "v01-closed-idle");
    K(e0 + 0.1, WIDE, 0.8);
    T.endcard = e0 + 0.7;
    T.duration = e0 + 4.6;
    return T;
  }

  // ---------------------------------------------------------------------------------- stage
  const world = document.getElementById("world");
  const cursorEl = document.getElementById("cursor");
  const capEl = document.getElementById("caption");
  const capStep = capEl.querySelector(".step"), capLine = capEl.querySelector(".line");
  const keysEl = document.getElementById("keys");
  const endEl = document.getElementById("endcard");
  let TL, winEls = {};
  // Menu-bar groups (titles, clock) with their world-space x extent, measured before any camera move.
  let menuGroups = [];
  const measureMenus = () => (menuGroups = [...document.querySelectorAll("#menubar .menus, #menubar .clock")].map((el) => {
    const b = el.getBoundingClientRect();
    return { el, x0: b.left, x1: b.right };
  }));

  function buildCodexCard() {
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `<h2>Codex: same plugin, same one task.</h2><pre><b>$</b> codex plugin marketplace add Avi130805/monotask
<b>$</b> codex plugin add monotask@monotask</pre>`;
    document.getElementById("windows").appendChild(card);
    return card;
  }

  async function init() {
    await document.fonts.load('18px "JetBrains Mono"');
    await document.fonts.load('700 18px "JetBrains Mono"');
    for (const w of [400, 500, 600, 700]) await document.fonts.load(`${w} 34px "Inter"`);
    measureMenus();
    await Promise.all(Object.values(imgs).map((i) => i.decode()));
    await holdOverlay.decode();
    TL = CUT === "short" ? shortTimeline() : guideTimeline();
    for (const w of TL.wins) {
      if (w.key === "codex-card") {
        const el = buildCodexCard();
        const r = el.getBoundingClientRect();
        winEls[w.key] = { el, x: (1920 - r.width) / 2, y: 330, w: r.width, h: r.height };
      } else {
        const st = makeTerminal(w.key, w.title);
        await new Promise((r) => requestAnimationFrame(r));
        const r = st.win.getBoundingClientRect();
        const x = Math.round((1920 - r.width) / 2), y = 118;
        winEls[w.key] = { el: st.win, st, x, y, w: r.width, h: r.height };
        const cell = st.term._core._renderService.dimensions.css.cell;
        st.cellH = cell.height; st.cellW = cell.width;
      }
    }
    // camera keys onto the finish-line sentence, now that the terminal is measured
    const r1 = winEls.r1;
    if (r1 && TL.finishRowKey) {
      const rowY = (row) => r1.y + 30 + 10 + (row + 0.5) * r1.st.cellH;
      const fl = rowY(D.casts.r1.rowsAt.finishLine), offer = rowY(D.casts.r1.rowsAt.offer);
      const z = CUT === "short" ? 1.45 : 1.38;
      TL.cam.push({ t: TL.finishRowKey.t, v: camFor(z, r1.x + 14 + 52 * r1.st.cellW, fl + 30), response: 0.9 });
      TL.cam.push({ t: TL.finishRowKey.back, v: camFor(CUT === "short" ? 1.2 : 1.12, 960, (fl + offer) / 2 + 40), response: 0.9 });
      TL.cam.push({ t: TL.r1.added - 0.9, v: WIDE, response: 0.7 });
    }
    TL.cam.sort((a, b) => a.t - b.t);
    TL.cursor.sort((a, b) => a.t - b.t);
    TL.notch.sort((a, b) => a.t - b.t);
    // Return keycaps for the Return presses typed into the recording
    for (const w of TL.wins) if (w.plan) {
      for (const e of D.casts[w.key].events) if (e[1] === "i" && e[2] === "\r") {
        const ft = w.plan.filmAt(e[0]);
        if (ft !== null && ft > w.tIn) TL.keys.push({ t: ft, keys: ["Return"] });
      }
    }
    TL.keys.sort((a, b) => a.t - b.t);
    window.FILM = { frames: Math.round(TL.duration * FPS), fps: FPS, cut: CUT, timeline: summary() };
    window.ready = true;
  }
  function summary() {
    return { duration: TL.duration, captions: TL.captions, notch: TL.notch.map((e) => [e.t.toFixed(2), e.to, e.kind]),
             wins: TL.wins.map((w) => ({ key: w.key, tIn: w.tIn, tOut: w.tOut, end: w.plan && w.plan.end,
               segs: w.plan && w.plan.segs.map((g) => [g.a, g.b, g.speed, +g.f0.toFixed(2), +g.f1.toFixed(2)]) })),
             r1: TL.r1, endcard: TL.endcard };
  }

  window.renderFrame = async function (n) {
    const t = n / FPS;
    // camera
    const [cx, cy, z] = keyed(TL.cam, t, 0.6);
    world.style.transform = `translate(960px, 540px) scale(${z}) translate(${-cx}px, ${-cy}px)`;
    // In close-ups the menu titles or the clock would run off the frame edge: fade each group out
    // before any of it is cut, and back in as the camera pulls back.
    for (const g of menuGroups) {
      const margin = Math.min((g.x0 - (cx - 960 / z)) * z, ((cx + 960 / z) - g.x1) * z);   // screen px
      g.el.style.opacity = smooth((margin - 4) / 36);
    }

    // notch
    notchEl.style.transform = `translate(${notchLeft}px, 0px) scale(${S})`;
    renderNotch(TL.notch, t);

    // windows
    for (const w of TL.wins) {
      const W = winEls[w.key];
      const pin = springCrit(t - w.tIn, 0.7), pout = springCrit(t - w.tOut, 0.7);
      let dx = 0, dy = 0;
      if (w.from === "below") { dy = (1 - pin) * 260 + pout * 220; }
      else { dx = (1 - pin) * 900 + pout * -40; dy = pout * 160; }
      const op = smooth((t - w.tIn) / 0.35) * (1 - smooth((t - w.tOut) / 0.45));
      W.el.style.display = op <= 0.001 ? "none" : "block";
      W.el.style.opacity = op;
      W.el.style.transform = `translate(${W.x + dx}px, ${W.y + dy}px)`;
      W.el.style.left = W.el.style.top = "0px";
      if (W.st && op > 0.001) {
        await seekTerminal(W.st, w.plan.castAt(t));
        const sp = w.plan.speedAt(t);
        W.st.badge.textContent = sp > 1 ? `${sp}×` : W.st.badge.textContent;
        W.st.badge.style.opacity = sp > 1 ? 1 : 0;
      }
    }

    // cursor
    const [mx, my] = keyed(TL.cursor, t, 0.6);
    let sc = 1;
    for (const c of TL.clicks) if (t >= c && t < c + 0.12) sc = 0.92;
    for (const [a, b] of TL.presses) if (t >= a && t < b) sc = 0.92;
    cursorEl.style.transform = `translate(${mx - 3}px, ${my - 3}px) scale(${sc})`;

    // end card
    endEl.style.opacity = TL.endcard ? smooth((t - TL.endcard) / 0.8) : 0;

    // caption
    capEl.style.opacity = 0;
    for (const c of TL.captions) {
      if (t >= c.t0 && t < c.t1 + 0.25) {
        const a = easeOut((t - c.t0) / 0.25) * (1 - smooth((t - c.t1) / 0.22));
        capEl.style.opacity = a;
        capEl.style.transform = `translateX(-50%) translateY(${(1 - easeOut((t - c.t0) / 0.25)) * 8}px)`;
        capStep.textContent = c.step; capStep.style.display = c.step ? "block" : "none";
        capLine.textContent = c.line;
      }
    }
    // keycaps
    keysEl.style.opacity = 0;
    for (const k of TL.keys) {
      if (t >= k.t && t < k.t + 0.7) {
        keysEl.innerHTML = k.keys.map((s) => `<div class="k">${s}</div>`).join("");
        keysEl.style.opacity = smooth((t - k.t) / 0.1) * (1 - smooth((t - k.t - 0.55) / 0.15));
      }
    }
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    return t;
  };

  init().catch((e) => { window.initError = String(e && e.stack || e); });
})();
