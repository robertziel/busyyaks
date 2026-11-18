// The README's live captures (scripts/readme-images/capture-live.js): the SAMPLE pictures a card's attachments and
// covers show instead of their real pixels (a real screenshot can hold any word, and no text gate reads pixels).
// Each is a text-free SVG — shapes only, never a <text> element or a font — drawn from the attachment's id: the same
// id always gets the same picture, neighbouring ids get different kinds (a chart, a board, a terminal, a phone, a
// page, a donut), so a card's screenshot grid reads as a set of real screenshots, never as blank plates.
// Tested by frontend/src/lib/readmeImages.test.ts.
"use strict";

const W = 480;
const H = 300;
const BG = "#1b1e25";
const PANEL = "#262a33";
const LINE = "#3a4050";
const DIM = "#323845";
const ACCENTS = ["#5b8cff", "#3ecf8e", "#f5a524", "#c084fc", "#f87171", "#22d3ee"];

// a small deterministic generator: the picture of an id never changes between runs
function rng(seed) {
  let s = (Math.abs(Math.trunc(seed)) * 2654435761 + 1013904223) >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

const rect = (x, y, w, h, fill, rx = 4) =>
  `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${w.toFixed(1)}" height="${h.toFixed(1)}" rx="${rx}" fill="${fill}"/>`;
const bar = (x, y, w, fill) => rect(x, y, w, 10, fill, 5); // a line of "text", drawn as a bar
const frame = (body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">` +
  rect(0, 0, W, H, BG, 0) +
  rect(0, 0, W, 28, PANEL, 0) +
  `<circle cx="16" cy="14" r="5" fill="#f87171"/><circle cx="32" cy="14" r="5" fill="#f5a524"/>` +
  `<circle cx="48" cy="14" r="5" fill="#3ecf8e"/>` +
  body +
  "</svg>";

const KINDS = {
  // bars over a baseline, one accent
  chart(r, a) {
    let out = rect(24, 44, W - 48, H - 68, PANEL, 8) + bar(40, 58, 120, LINE);
    const n = 12;
    const step = (W - 96) / n;
    for (let i = 0; i < n; i++) {
      const h = 30 + r() * 150;
      out += rect(48 + i * step, H - 40 - h, step * 0.62, h, i === n - 1 ? a : DIM, 3);
    }
    return out + rect(40, H - 40, W - 80, 2, LINE, 1);
  },
  // a line with its area, a stat row above it
  line(r, a) {
    let out = "";
    for (let i = 0; i < 3; i++)
      out +=
        rect(24 + i * 148, 44, 136, 58, PANEL, 8) +
        bar(36 + i * 148, 58, 60, LINE) +
        rect(36 + i * 148, 78, 40 + r() * 50, 14, i === 0 ? a : DIM, 4);
    out += rect(24, 114, W - 48, H - 136, PANEL, 8);
    const pts = [];
    for (let i = 0; i <= 10; i++) pts.push([40 + i * ((W - 80) / 10), 250 - r() * 100]);
    const d = pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)} ${y.toFixed(1)}`).join(" ");
    out += `<path d="${d} L${W - 40} 262 L40 262 Z" fill="${a}" opacity="0.18"/>`;
    return out + `<path d="${d}" fill="none" stroke="${a}" stroke-width="3" stroke-linejoin="round"/>`;
  },
  // columns of cards
  board(r, a) {
    let out = "";
    for (let c = 0; c < 4; c++) {
      const x = 20 + c * 113;
      out += rect(x, 42, 104, H - 58, PANEL, 8) + bar(x + 10, 54, 50, LINE);
      const cards = 1 + Math.floor(r() * 4);
      for (let k = 0; k < cards; k++) {
        const y = 74 + k * 52;
        out += rect(x + 8, y, 88, 44, DIM, 6) + bar(x + 16, y + 10, 50 + r() * 20, LINE);
        if (r() > 0.5) out += rect(x + 16, y + 28, 22, 8, ACCENTS[(c + k) % ACCENTS.length], 4);
      }
    }
    return out + rect(20, 42, 104, 4, a, 2); // the first column's accent strip
  },
  // a terminal: prompt lines, one accent run
  terminal(r, a) {
    let out = rect(16, 40, W - 32, H - 56, "#11131a", 8);
    for (let i = 0; i < 11; i++) {
      const y = 56 + i * 20;
      out += rect(32, y, 10, 10, i % 4 === 0 ? a : LINE, 2) + bar(50, y, 60 + r() * 300, i % 4 === 0 ? DIM : LINE);
    }
    return out + rect(32, 56 + 11 * 20, 12, 12, a, 1);
  },
  // a phone beside a list
  phone(r, a) {
    let out = rect(36, 40, 130, H - 56, PANEL, 16) + rect(48, 56, 106, 70, a, 8);
    for (let i = 0; i < 5; i++) out += bar(48, 138 + i * 20, 50 + r() * 50, i ? LINE : DIM);
    for (let i = 0; i < 6; i++) {
      const y = 48 + i * 38;
      out +=
        rect(190, y, W - 214, 30, i === 1 ? DIM : PANEL, 6) +
        rect(200, y + 9, 12, 12, ACCENTS[i], 6) +
        bar(222, y + 10, 80 + r() * 120, LINE);
    }
    return out;
  },
  // a page: a heading, paragraphs, a picture block
  page(r, a) {
    let out = rect(24, 40, W - 48, H - 56, PANEL, 8) + rect(40, 56, 180, 16, a, 6);
    for (let i = 0; i < 7; i++) out += bar(40, 88 + i * 20, 120 + r() * (i % 3 === 2 ? 60 : 140), LINE);
    return (
      out +
      rect(W - 190, 88, 150, 130, DIM, 8) +
      `<circle cx="${W - 115}" cy="140" r="26" fill="${a}" opacity="0.7"/>` +
      `<path d="M${W - 182} 210 L${W - 140} 170 L${W - 110} 196 L${W - 80} 160 L${W - 48} 210 Z" fill="${LINE}"/>`
    );
  },
  // a donut and its legend
  donut(r, a) {
    let out = rect(24, 40, W - 48, H - 56, PANEL, 8);
    const parts = [0.2 + r() * 0.3, 0.15 + r() * 0.2, 0.1 + r() * 0.15];
    parts.push(Math.max(0.05, 1 - parts.reduce((s, p) => s + p, 0)));
    const total = parts.reduce((s, p) => s + p, 0);
    const C = 2 * Math.PI * 70;
    let off = 0;
    parts.forEach((p, i) => {
      const len = (p / total) * C;
      const color = i === 0 ? a : ACCENTS[(ACCENTS.indexOf(a) + i + 1) % ACCENTS.length];
      out +=
        `<circle cx="140" cy="168" r="70" fill="none" stroke="${color}" stroke-width="28" ` +
        `stroke-dasharray="${len.toFixed(1)} ${(C - len).toFixed(1)}" stroke-dashoffset="${(-off).toFixed(1)}"/>`;
      out += rect(260, 110 + i * 30, 14, 14, color, 3) + bar(284, 112 + i * 30, 60 + r() * 80, LINE);
      off += len;
    });
    return out;
  },
};
const KIND_NAMES = Object.keys(KINDS);

// The sample picture for an attachment id: {kind, svg}
function samplePicture(id) {
  if (!/^\d+$/.test(String(id)))
    throw new Error(`readme-images: a sample picture needs a numeric attachment id, not ${JSON.stringify(id)}`);
  const n = Number(id);
  const kind = KIND_NAMES[n % KIND_NAMES.length];
  const r = rng(n);
  const accent = ACCENTS[Math.floor(r() * ACCENTS.length)];
  return { kind, svg: frame(KINDS[kind](r, accent)) };
}

if (typeof module !== "undefined") module.exports = { samplePicture, KIND_NAMES };
