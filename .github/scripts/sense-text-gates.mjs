// Sense Remote: metin kapilari (S11 ALT). Bagimliligi yok; yalniz Node >= 20.
//  1) Karakter kapsami: flutter/lib/sense/** altindaki Dart dizgilerinde Poppins'te olmayan
//     karakter (ornek U+2011) var mi. Poppins gomulu yazi tipi: flutter/assets/fonts.
//  2) Karsitlik: design/tokens.json yazi renklerinin zeminlere orani (WCAG).
// Kullanim: node .github/scripts/sense-text-gates.mjs [--root <dizin>]
// Cikis 0 = temiz, 1 = ihlal. Bilinen istisna tablosu asagida; her istisnanin bir kalemi var.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

// ---- Yazi tipi cmap ayristirici (TrueType, bicim 4 ve 12) ----
export function fontCodepoints(buf) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const n = dv.getUint16(4);
  let cmapOff = -1;
  for (let i = 0; i < n; i++) {
    const o = 12 + i * 16;
    if (String.fromCharCode(buf[o], buf[o + 1], buf[o + 2], buf[o + 3]) === "cmap") cmapOff = dv.getUint32(o + 8);
  }
  if (cmapOff < 0) throw new Error("cmap tablosu yok");
  const sub = dv.getUint16(cmapOff + 2);
  const set = new Set();
  for (let i = 0; i < sub; i++) {
    const rec = cmapOff + 4 + i * 8;
    const off = cmapOff + dv.getUint32(rec + 4);
    const fmt = dv.getUint16(off);
    if (fmt === 4) {
      const segX2 = dv.getUint16(off + 6);
      const endO = off + 14, startO = endO + segX2 + 2;
      for (let s = 0; s < segX2; s += 2) {
        const end = dv.getUint16(endO + s), start = dv.getUint16(startO + s);
        if (start === 0xffff) continue;
        for (let c = start; c <= end; c++) set.add(c);
      }
    } else if (fmt === 12) {
      const groups = dv.getUint32(off + 12);
      for (let g = 0; g < groups; g++) {
        const go = off + 16 + g * 12;
        const start = dv.getUint32(go), end = dv.getUint32(go + 4);
        for (let c = start; c <= end; c++) set.add(c);
      }
    }
  }
  return set;
}

// ---- Dart dizgi cikarimi (tek/cift tirnak, ham dizgi dahil; yorum satirlari atlanir) ----
export function dartStringChars(src) {
  const out = []; // {ch, line}
  const lines = src.split(/\r?\n/);
  lines.forEach((raw, idx) => {
    const line = raw.replace(/^\s*\/\/.*$/, "");
    const re = /r?("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')/g;
    let m;
    while ((m = re.exec(line))) {
      let body = m[1].slice(1, -1);
      body = body.replace(/\\u\{([0-9a-fA-F]+)\}/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
        .replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
      for (const ch of body) out.push({ ch, line: idx + 1 });
    }
  });
  return out;
}

export function missingGlyphs(src, cps) {
  const bad = new Map();
  for (const { ch, line } of dartStringChars(src)) {
    const cp = ch.codePointAt(0);
    if (cp < 0x20 || cp === 0x7f) continue;
    if (cp === 0x200b || cp === 0x200d || cp === 0xfe0f) continue; // bicim karakterleri
    if (!cps.has(cp) && !bad.has(cp)) bad.set(cp, line);
  }
  return bad;
}

// ---- Karsitlik ----
export function luminance(hex) {
  const v = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2];
}
export function contrast(a, b) {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}

// Okunacak yazi renkleri ve en dusuk oran. Zeminler: bg, surface, raised.
const TEXT_MIN = {
  text: 4.5, textSecondary: 4.5, textMuted: 4.5, dangerText: 4.5, dangerTextSoft: 4.5,
  ok: 4.5, warn: 4.5, hot: 4.5,
  // Bilinen istisna (TS-2): okunmasi gereken metinde kullaniliyor, 2,8-3,2:1. Duzeltme UI/PW
  // paketlerinde (metin textMuted'a tasinir); bitince bu satir 4.5'a cekilir.
  textDim: 2.7,
};
const GROUNDS = ["bg", "surface", "raised"];

export function contrastViolations(tokens) {
  const c = tokens.color, bad = [];
  for (const [name, min] of Object.entries(TEXT_MIN)) {
    if (!c[name]) { bad.push(`${name}: tokens.json'da yok`); continue; }
    for (const g of GROUNDS) {
      const r = contrast(c[name].value, c[g].value);
      if (r < min) bad.push(`${name} (${c[name].value}) / ${g} (${c[g].value}) = ${r.toFixed(2)}:1 < ${min}:1`);
    }
  }
  return bad;
}

// Bilinen istisnalar (S11 oncesi var olanlar; duzeltme sahibi paket). Duzelince satir silinir;
// duzelmis ama listede kalan satir uyari verir (CI dusmez, paketler sirasiz birlesebilsin).
export const KNOWN_GLYPHS = {
  "flutter/lib/sense/screens/session/popups/display/display_model.dart": [0x2011],
  "flutter/lib/sense/screens/session/popups/status/status_format.dart": [0x2191, 0x2193],
  "flutter/lib/sense/screens/session/popups/status/status_model.dart": [0x2011],
  "flutter/lib/sense/screens/session/popups/status/status_strings.dart": [0x2011],
};

function walk(dir, acc = []) {
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) walk(p, acc);
    else if (p.endsWith(".dart") && !p.endsWith(".g.dart")) acc.push(p);
  }
  return acc;
}

function main() {
  const i = process.argv.indexOf("--root");
  const root = resolve(i > 0 ? process.argv[i + 1] : ".");
  let fail = 0;

  const cps = fontCodepoints(readFileSync(join(root, "flutter/assets/fonts/Poppins-Regular.ttf")));
  const medium = fontCodepoints(readFileSync(join(root, "flutter/assets/fonts/Poppins-Medium.ttf")));
  for (const c of [...cps]) if (!medium.has(c)) cps.delete(c); // her agirlikta olan karakter
  for (const f of walk(join(root, "flutter/lib/sense"))) {
    const rel = f.slice(root.length + 1).replaceAll("\\", "/");
    const known = new Set(KNOWN_GLYPHS[rel] || []);
    const bad = missingGlyphs(readFileSync(f, "utf8"), cps);
    for (const k of known) if (!bad.has(k)) console.log(`::warning file=${rel}::Bilinen istisna artik gerekmiyor: U+${k.toString(16).toUpperCase()} (listeden sil)`);
    for (const [cp, line] of bad) {
      if (known.has(cp)) continue;
      fail++;
      console.log(`::error file=${rel},line=${line}::Poppins'te olmayan karakter U+${cp.toString(16).toUpperCase().padStart(4, "0")}`);
    }
  }

  const tokens = JSON.parse(readFileSync(join(root, "design/tokens.json"), "utf8"));
  for (const v of contrastViolations(tokens)) { fail++; console.log(`::error file=design/tokens.json::Karsitlik: ${v}`); }

  console.log(fail === 0 ? "Metin kapilari temiz." : `${fail} ihlal.`);
  process.exit(fail === 0 ? 0 : 1);
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"))) main();
