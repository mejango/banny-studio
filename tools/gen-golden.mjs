#!/usr/bin/env node
// Generates golden simulation fixtures by running the ORIGINAL webapp math
// (simulatePos + resetToTime, lifted verbatim from playground/index.html)
// against the real ep1 staging document. The Swift port must match these.
//
// Coordinate note: the web sims in px with W = stage width and serializes
// x as x/W. With W=900 the px math is exactly fraction*900, so we run at
// W=900 and emit fractions.

import { readFileSync, writeFileSync } from 'node:fs';

const STAGING = process.argv[2] ?? '/Users/jango/Documents/banny/show/ep1/beat1/staging/1.json';
const OUT = new URL('../Tests/BannyCoreTests/Fixtures/golden-ep1.json', import.meta.url).pathname;
const W = 900;
const SAMPLE_TIMES = [0, 0.5, 1, 2, 3, 5, 8, 13, 20, 30];

const BLINK_KEY = { Comma: 'closed', Slash: 'brow1', Period: 'brow2' };

// --- verbatim port of index.html simulatePos (fraction space via W=900) ---
function simulatePos(b, t, gScale) {
  const rs = b.recStart ?? { x: b.x, depth: b.depth || 0, face: b.face || 1 };
  let x = norm(rs.x) * W, depth = rs.depth || 0, face = rs.face || 1, turnUntil = 0, ei = 0;
  const kh = new Set();
  const DT = 1 / 60, dr = (b.speed / 320) * 0.36 / Math.max(gScale, 0.1), EM = Math.max(10, W * 0.044);
  let phase = 0;
  for (let tt = 0; tt < t - 1e-9;) {
    while (ei < b.events.length && b.events[ei].t <= tt) {
      const ev = b.events[ei++], d = ev.type === 'd';
      if (ev.code === 'ArrowRight' || ev.code === 'ArrowLeft') {
        const dir = ev.code === 'ArrowRight' ? 1 : -1;
        if (d) { if (!kh.has(ev.code) && face !== dir) { face = dir; turnUntil = tt + 0.1; } kh.add(ev.code); }
        else kh.delete(ev.code);
      } else if (ev.code === 'ArrowUp' || ev.code === 'ArrowDown') {
        if (d) kh.add(ev.code); else kh.delete(ev.code);
      }
    }
    const h = Math.min(DT, t - tt);
    let dx = 0, dz = (kh.has('ArrowUp') ? 1 : 0) - (kh.has('ArrowDown') ? 1 : 0);
    if (kh.has('ArrowRight') && face === 1 && tt >= turnUntil) dx = 1;
    else if (kh.has('ArrowLeft') && face === -1 && tt >= turnUntil) dx = -1;
    x = Math.max(EM, Math.min(W - EM, x + b.speed * (W / 900) * dx * h));
    depth = Math.max(-12, Math.min(1, depth + dz * h * dr));
    if (dx || dz) phase += h * b.speed / 22;
    tt += h;
  }
  return { x: x / W, depth, face, phase };
}

// --- verbatim port of index.html resetToTime state scan ---
function resetToTime(b, t) {
  const kh = new Set();
  let eyeExpr = 'open', tilt = 0, talking = false;
  for (const ev of b.events) {
    if (ev.t >= t) break;
    if (ev.code === 'outfit') continue;
    const d = ev.type === 'd';
    if (BLINK_KEY[ev.code]) eyeExpr = d ? BLINK_KEY[ev.code] : 'open';
    else if (ev.code === 'KeyM') talking = d;
    else if (ev.code === 'KeyT') tilt = d ? 9 : 0;
    else if (ev.code === 'KeyB') tilt = d ? -9 : 0;
    else if (ev.code.startsWith('Arrow')) { if (d) kh.add(ev.code); else kh.delete(ev.code); }
  }
  return { eye: eyeExpr, tilt, talking, held: [...kh].sort() };
}

// Legacy: x fractions, but values > 1.5 are absolute px (web fallback width 900).
const norm = (x) => (x > 1.5 ? x / 900 : x);

const raw = JSON.parse(readFileSync(STAGING, 'utf8'));
const fixture = { source: STAGING, sampleTimes: SAMPLE_TIMES, scenes: [] };

for (const scene of raw.studio.scenes) {
  const st = scene.state;
  if (!st) continue;
  const sc = { id: scene.id, name: scene.name, gScale: st.gScale, characters: [] };
  st.bannys.forEach((b0, i) => {
    const b = {
      speed: 320, // v1 never persisted speed; all replays used the default
      x: norm(b0.x), depth: b0.depth, face: b0.face,
      recStart: b0.recStart ? { x: norm(b0.recStart.x), depth: b0.recStart.depth, face: b0.recStart.face } : null,
      events: [...(b0.events || [])].sort((a, c) => a.t - c.t),
    };
    const ch = { index: i, name: b0.name || String(i + 1), eventCount: b.events.length, samples: [] };
    for (const t of SAMPLE_TIMES) {
      const pos = simulatePos(b, t, st.gScale);
      const state = resetToTime(b, t);
      ch.samples.push({ t, ...pos, ...state });
    }
    sc.characters.push(ch);
  });
  fixture.scenes.push(sc);
}

writeFileSync(OUT, JSON.stringify(fixture, null, 1));
const n = fixture.scenes.reduce((a, s) => a + s.characters.length, 0);
console.log(`wrote ${OUT}: ${fixture.scenes.length} scenes, ${n} characters`);
// sanity: fractions in range
for (const s of fixture.scenes) for (const c of s.characters) for (const p of c.samples) {
  if (p.x < 0.044 - 1e-9 || p.x > 0.956 + 1e-9) throw new Error(`x out of range: ${p.x}`);
  if (Math.abs(p.face) !== 1) throw new Error(`bad face ${p.face}`);
}
console.log('sanity ok');
