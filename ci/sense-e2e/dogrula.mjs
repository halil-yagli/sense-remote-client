// Sense Remote uçtan uca testi (E4), panelsiz kip: kayıt sunucusunun gördüğü istekleri doğrular.
// Beklenen rolde, `since` anından sonra gelen heartbeat'lerde:
//   - kimlik: gövdedeki uuid = MachineGuid'den hesaplanan (panel kaydında gidecek olanla aynı),
//   - `sense`: rol, app_version, `caps` içinde `role_all`,
//   - `sense.report`: imza, servisin AÇIK anahtarıyla doğrulanıyor (src/sense/report_sig.rs
//     sözleşmesi: "sense-remote/hb-report/v1\n" ‖ JCS{id, uuid, ts, imzalı alanlar}), `ts` artıyor.
// Bulgular satır satır yazılır ve GITHUB_STEP_SUMMARY'ye eklenir. Gizli değer yok (uuid ve
// anahtar yazılmaz; RustDesk kimliği tek kullanımlık koşucunundur).
//
// Kullanım: node dogrula.mjs <kayıt.jsonl> <kimlik.json> <rol> <since-ms> [bekleme-sn]

import { createPublicKey, verify } from "node:crypto";
import { appendFileSync, readFileSync } from "node:fs";

const [file, identityFile, role, sinceArg, waitArg] = process.argv.slice(2);
const since = Number(sinceArg);
const waitS = Number(waitArg ?? 240);
const identity = JSON.parse(readFileSync(identityFile, "utf8"));

const PREFIX = "sense-remote/hb-report/v1\n";
const SIGNED_FIELDS = ["applied_seq", "envelope_error", "clock_skew_s", "caps", "maintenance_curtain"];
const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

/** RFC 8785 (JCS) bu nesneler için yeterli: tamsayı, dize, dizi, nesne (anahtarlar sıralı). */
function jcs(value) {
  if (Array.isArray(value)) return `[${value.map(jcs).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${jcs(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

const publicKey = createPublicKey({
  key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(identity.pk, "base64url")]),
  format: "der",
  type: "spki",
});

function reportValid(body) {
  const sense = body.sense;
  if (!sense?.report || sense.applied_seq === undefined) return false;
  // Panelin biçim kuralları: rapor yalnız {ts, sig}; imza kanonik dolgusuz base64url.
  const { ts, sig, ...extra } = sense.report;
  if (Object.keys(extra).length > 0 || typeof sig !== "string") return false;
  if (Buffer.from(sig, "base64url").toString("base64url") !== sig || !Number.isInteger(ts)) return false;
  const object = { id: body.id, uuid: body.uuid, ts: sense.report.ts };
  for (const f of SIGNED_FIELDS) if (sense[f] !== undefined) object[f] = sense[f];
  const bytes = Buffer.from(PREFIX + jcs(object), "utf8");
  return verify(null, bytes, publicKey, Buffer.from(sense.report.sig, "base64url"));
}

function records() {
  return readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l))
    .filter((r) => r.at >= since);
}

const results = [];
const check = (name, ok, detail = "") => results.push({ name, ok, detail });

const deadline = Date.now() + waitS * 1000;
let beats = [];
for (;;) {
  const all = records();
  beats = all.filter(
    (r) => r.path === "/api/heartbeat" && r.body?.sense?.role === role && r.body?.sense?.report,
  );
  if (beats.length >= 2 || Date.now() > deadline) {
    const sysinfo = all.filter((r) => r.path === "/api/sysinfo");
    const anyBeat = all.filter((r) => r.path === "/api/heartbeat");
    check("heartbeat geldi", anyBeat.length > 0, `${anyBeat.length} heartbeat, ${sysinfo.length} sysinfo`);
    if (role === "host") {
      check(
        "sysinfo geldi (sense eki ile)",
        sysinfo.some((r) => r.body?.sense),
        sysinfo[0]?.body?.sense ? `sense.role=${sysinfo[0].body.sense.role ?? "-"}` : "",
      );
    }
    break;
  }
  await new Promise((r) => setTimeout(r, 2000));
}

check(`imzalı heartbeat (rol ${role})`, beats.length >= 2, `${beats.length} adet`);
if (beats.length > 0) {
  const b = beats[beats.length - 1].body;
  check("uuid = MachineGuid (kayıtta gidecek kimlik)", b.uuid === identity.uuid);
  check("sense.app_version", Number.isInteger(b.sense.app_version), String(b.sense.app_version));
  check("sense.caps içinde role_all", Array.isArray(b.sense.caps) && b.sense.caps.includes("role_all"), JSON.stringify(b.sense.caps));
  check("sense.applied_seq", Number.isInteger(b.sense.applied_seq), String(b.sense.applied_seq));
  const valid = beats.filter((r) => reportValid(r.body)).length;
  check("rapor imzası servisin açık anahtarıyla doğrulanıyor", valid === beats.length, `${valid}/${beats.length}`);
  const ts = beats.map((r) => r.body.sense.report.ts);
  check("rapor ts kesin artıyor", ts.every((t, i) => i === 0 || t > ts[i - 1]), ts.join(","));
  check("RustDesk kimliği", typeof b.id === "string" && b.id.length > 0, b.id);
}

const lines = results.map((r) => `${r.ok ? "GEÇTİ" : "KALDI"} · ${r.name}${r.detail ? ` — ${r.detail}` : ""}`);
for (const l of lines) process.stdout.write(`${l}\n`);
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `\n#### Panelsiz kip — rol \`${role}\`\n\n${lines.map((l) => `- ${l}`).join("\n")}\n`,
  );
}
process.exit(results.every((r) => r.ok) ? 0 : 1);
