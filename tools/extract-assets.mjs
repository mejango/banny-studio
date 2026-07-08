#!/usr/bin/env node
// Extracts the Banny art constants from the webapp source (index.html) and writes
// standalone SVG files + a machine-readable catalog for the native renderer.
//
// Composition semantics ported verbatim from the web recompose()/setMouth()/updateBlink():
// - render order: [2, BODY, 3, 4, EYES, 6, MOUTH, 8, 9, 10, 11, 12, 13]
// - Head(4) hides Eyes+Mouth layers and (in applyOutfit) Glasses(6)+HeadTop(12);
//   Suit(9) hides SuitBottom(10)+SuitTop(11)
// - eyes: open art per option (alien default swaps to ALIENEYES);
//   blink art = eo[4] || (closedFlag ? bodyEyes : BLINK); introspective = INTRO_DECOR + bodyEyes
// - brow1/brow2 frames are the global BLINK1/BLINK2 arts
// - mouth: open = OPENMOUTH recolored to option lip; tight = TIGHT recolored;
//   closed = option closed art || MOUTH
// - parts referencing CSS classes resolve against the body's palette → baked per body
//
// Usage: node tools/extract-assets.mjs [path-to-index.html]

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const SRC = process.argv[2] ?? '/Users/jango/Documents/banny/playground/index.html';
const OUT_SVG = `${ROOT}/App/Resources/BannyAssets/svg`;
const OUT_CATALOG = `${ROOT}/App/Resources/BannyAssets/catalog.json`;

// --- pull the constants out of the webapp source by evaluating its data lines ---
const lines = readFileSync(SRC, 'utf8').split('\n');
// line 263: OUTFITS + all art constants; 265: SHADOW; 271: SUN_SVG (1-based)
const code = [lines[262], lines[264], lines[270]].join('\n');
const C = {};
new Function('out', code + `
  out.OUTFITS = OUTFITS; out.BODY_PATHS = BODY_PATHS; out.BODY_CSS = BODY_CSS;
  out.EYE_OPTIONS = EYE_OPTIONS; out.MOUTH_OPTIONS = MOUTH_OPTIONS;
  out.EYES = EYES; out.ALIENEYES = ALIENEYES; out.BLINK = BLINK; out.BLINK1 = BLINK1;
  out.BLINK2 = BLINK2; out.MOUTH = MOUTH; out.OPENMOUTH = OPENMOUTH;
  out.NECKLACE = NECKLACE; out.PALETTE = PALETTE; out.INTRO_DECOR = INTRO_DECOR;
  out.CATNAMES = CATNAMES; out.SHADOW = SHADOW; out.SUN_SVG = SUN_SVG;
`)(C);

const BODIES = Object.keys(C.BODY_PATHS); // orange, original, pink, alien
const TIGHT = `<g class="o"><path d="M183 160v-4h-20v4h-3v3h3v4h24v-7h-4z" fill="#AC71C8"/><path d="M170 161h10v1h-10z"/></g>`;

mkdirSync(OUT_SVG, { recursive: true });

const usesClasses = (svg) => /class=/.test(svg);
const recolorLip = (svg, lip) => svg.replace(/#AC71C8/gi, lip);

/** Wrap an art fragment as a standalone SVG that Chrome bakes at `px`. */
function wrap(art, { css = '', viewBox = '0 0 400 400', px = 1600 } = {}) {
  const [, , w, h] = viewBox.split(' ').map(Number);
  const height = Math.round(px * (h / w));
  const style = css ? `<style>${css}</style>` : '';
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${height}" viewBox="${viewBox}">${style}${art}</svg>`;
}

const files = [];
function emit(name, art, opts = {}) {
  writeFileSync(`${OUT_SVG}/${name}.svg`, wrap(art, opts));
  files.push(name);
  return `${name}.png`;
}

/** Emit one file per body when the art uses palette classes, else a single file. */
function emitMaybePerBody(name, art, opts = {}) {
  if (!usesClasses(art)) return { file: emit(name, art, opts) };
  const perBody = {};
  for (const body of BODIES) {
    perBody[body] = emit(`${name}@${body}`, art, { ...opts, css: C.BODY_CSS[body] });
  }
  return { perBody };
}

const catalog = {
  generated: 'tools/extract-assets.mjs',
  canvas: { viewBox: [0, 0, 400, 400], bakeScale: 4 },
  renderOrder: [2, 'BODY', 3, 4, 'EYES', 6, 'MOUTH', 8, 9, 10, 11, 12, 13],
  catNames: C.CATNAMES,
  // Slot exclusivity (web applyOutfit): wearing key hides values.
  exclusivity: { 4: [6, 12], 9: [10, 11] },
  headHidesFace: true, // Head(4) also suppresses the EYES and MOUTH layers
  bodies: {},
  outfits: {},
  eyes: {},
  brows: {},
  mouths: {},
  necklace: null,
  shadow: null,
  sun: null,
};

// Bodies: palette + paths, one file each.
for (const body of BODIES) {
  catalog.bodies[body] = {
    file: emit(`body-${body}`, C.BODY_PATHS[body], { css: C.BODY_CSS[body] }),
    colors: Object.fromEntries(
      [...C.BODY_CSS[body].matchAll(/\.([a-z0-9]+)\{fill:([^;}]+)/g)].map((m) => [m[1], m[2]])),
  };
}

// Outfits (52).
for (const [key, o] of Object.entries(C.OUTFITS)) {
  catalog.outfits[key] = { slot: o.c, label: o.l, ...emitMaybePerBody(`outfit-${key}`, o.s) };
}

// Default necklace (slot 3 when nothing selected).
catalog.necklace = emitMaybePerBody('necklace', C.NECKLACE);

// Eyes: per option, open + blink frames (web recompose logic, verbatim).
for (const eo of C.EYE_OPTIONS) {
  const [name, label, rest, closedFlag, customBlink] = eo;
  const entry = { label, open: {}, blink: {} };

  for (const body of BODIES) {
    const bodyEyes = body === 'alien' ? C.ALIENEYES : C.EYES;
    let openArt = rest;
    if (name === 'default' && body === 'alien') openArt = bodyEyes;
    let blinkArt = customBlink || (closedFlag ? bodyEyes : C.BLINK);
    if (name === 'introspective') blinkArt = C.INTRO_DECOR + bodyEyes;
    entry.open[body] = { art: openArt };
    entry.blink[body] = { art: blinkArt };
  }

  // Collapse to a single file when the art is identical for every body.
  for (const frame of ['open', 'blink']) {
    const arts = BODIES.map((b) => entry[frame][b].art);
    if (arts.every((a) => a === arts[0]) && !usesClasses(arts[0])) {
      entry[frame] = { file: emit(`eyes-${name}-${frame}`, arts[0]) };
    } else {
      const perBody = {};
      for (const body of BODIES) {
        perBody[body] = emit(`eyes-${name}-${frame}@${body}`, entry[frame][body].art,
                             { css: C.BODY_CSS[body] });
      }
      entry[frame] = { perBody };
    }
  }
  catalog.eyes[name] = entry;
}

// Brow expressions (shared across options; web blink1/blink2 layers).
catalog.brows.brow1 = emitMaybePerBody('blink-brow1', C.BLINK1);
catalog.brows.brow2 = emitMaybePerBody('blink-brow2', C.BLINK2);

// Mouths: 3 states per option.
for (const mo of C.MOUTH_OPTIONS) {
  const [name, label, , lip, inverted, closedArt] = mo;
  catalog.mouths[name] = {
    label,
    lip,
    inverted: !!inverted,
    open: emitMaybePerBody(`mouth-${name}-open`, recolorLip(C.OPENMOUTH, lip || '#AC71C8')),
    tight: emitMaybePerBody(`mouth-${name}-tight`, recolorLip(TIGHT, lip || '#AC71C8')),
    closed: emitMaybePerBody(`mouth-${name}-closed`, closedArt || C.MOUTH),
  };
}

// Stage furniture.
catalog.shadow = { file: emit('shadow', C.SHADOW, { viewBox: '0 0 32 7', px: 512 }) };
catalog.sun = { file: emit('sun', C.SUN_SVG, { viewBox: '0 0 16 16', px: 256 }) };

writeFileSync(OUT_CATALOG, JSON.stringify(catalog, null, 1));
console.log(`wrote ${files.length} SVGs to Assets/svg + catalog.json`);
