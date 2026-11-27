// node --test .github/scripts/sense-text-gates.test.mjs  (sirsiz, agsiz)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fontCodepoints, missingGlyphs, dartStringChars, contrast, contrastViolations } from "./sense-text-gates.mjs";

const cps = fontCodepoints(readFileSync("flutter/assets/fonts/Poppins-Regular.ttf"));

test("Poppins temel Turkce harfleri kapsar", () => {
  for (const ch of "ğüşıöçĞÜŞİÖÇabcXYZ0-9 —·…•") assert.ok(cps.has(ch.codePointAt(0)), ch);
});
test("U+2011 ve oklar kapsam disi", () => {
  assert.equal(cps.has(0x2011), false);
  assert.equal(cps.has(0x2191), false);
});
test("dizgideki kapsam disi karakter bulunur, yorum satiri atlanir", () => {
  const src = "// 'a\u2011b'\nconst x = 'ok\u2011';\nconst y = \"\u2011\";\n";
  const bad = missingGlyphs(src, cps);
  assert.deepEqual([...bad.keys()], [0x2011]);
  assert.equal(bad.get(0x2011), 2);
  assert.equal(dartStringChars("'\u{2011}'")[0].ch, "\u2011");
});
test("karsitlik hesabi", () => {
  assert.ok(Math.abs(contrast("#000000", "#FFFFFF") - 21) < 0.01);
  const tokens = JSON.parse(readFileSync("design/tokens.json", "utf8"));
  assert.deepEqual(contrastViolations(tokens), []);
  const bad = structuredClone(tokens);
  bad.color.textMuted.value = "#333333";
  assert.ok(contrastViolations(bad).some((v) => v.startsWith("textMuted")));
});
