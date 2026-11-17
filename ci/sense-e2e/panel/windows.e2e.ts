import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { type BrowserContext, expect, type Page, test } from "@playwright/test";
import { E3_ORIGIN, type Stack, startStack } from "../e2e/dalga-3/stack.ts";
import { approveInstallInBrowser, auditOf, enrollAndLogin } from "../e2e/dalga-3/support.ts";

// Sense Remote E4 (plan Dalga 3): GERÇEK Windows istemcisi + gerçek panel-api (sahte OIDC).
// İstemci `SENSE_API_SERVER=http://127.0.0.1:3110` ile derlendi (yalnız sense-e2e iş akışı).
// 1. Panel ayağa kalkar, yönetici girer (Google + TOTP, sahte sağlayıcı).
// 2. İstemci sessiz kurulur, HKLM rolü Host; servis sysinfo gönderir → panelde "bekleyen" cihaz.
// 3. Kurulum girişi (purpose=install) AYNI id/uuid ile açılır, tarayıcıda onaylanır (eşleştirme
//    kodu karşılaştırılır), kayıt servisin AÇIK anahtarıyla yapılır → cihaz etkin.
// 4. Gerçek istemcinin heartbeat'i: `sense` (app_version), imzalı rapor doğrulandı (caps yalnız
//    doğrulanmış rapordan yazılır), denetimde device.enroll.install.
// 5. Rol Controller'a çevrilir, servis yeniden başlar → heartbeat sürüyor (last_seen ilerliyor).
// Gizli değer yazılmaz: istemci anahtarı, yoklama kodu, TOTP anahtarı hiçbir satıra girmez.

const CI_DIR = process.env.SENSE_CI_DIR ?? "";
const APP_DIR = process.env.SENSE_APP_DIR ?? "";
const EVIDENCE = process.env.SENSE_EVIDENCE_DIR ?? resolve(import.meta.dirname, "kanit");
const PS = resolve(CI_DIR, "istemci.ps1");
const PROJECT = "Sense CI Windows";

let stack: Stack;
let context: BrowserContext;
let page: Page;
const summary: string[] = [];
const state = { rustdeskId: "", uuid: "", pk: "", deviceId: "", enrolledAt: 0 };

function note(line: string): void {
  summary.push(line);
  process.stdout.write(`KANIT ${line}\n`);
}

function client(args: string[]): Record<string, unknown> {
  const out = execFileSync("pwsh", ["-NoProfile", "-NonInteractive", "-File", PS, ...args], {
    encoding: "utf8",
    timeout: 10 * 60_000,
  });
  const line = out.trim().split(/\r?\n/).at(-1) ?? "{}";
  return JSON.parse(line) as Record<string, unknown>;
}

interface Item {
  id: string;
  rustdeskId: string;
  status: string;
  lastSeenAt: string | null;
  role: string | null;
  appVersion: number | null;
  caps?: string[];
  reportKey?: string;
  enrolledAt?: string | null;
}

async function list(status: "active" | "pending"): Promise<Item[]> {
  const res = await page.request.get(`/panel-api/devices?status=${status}`);
  expect(res.ok()).toBe(true);
  return ((await res.json()) as { items: Item[] }).items;
}

async function detail(id: string): Promise<Item> {
  const res = await page.request.get(`/panel-api/devices/${id}`);
  expect(res.ok()).toBe(true);
  return (await res.json()) as Item;
}

test.describe.configure({ mode: "serial" });
test.use({ baseURL: E3_ORIGIN });

test.beforeAll(async ({ browser }) => {
  expect(CI_DIR, "SENSE_CI_DIR").not.toBe("");
  expect(APP_DIR, "SENSE_APP_DIR").not.toBe("");
  stack = await startStack();
  context = await browser.newContext({ baseURL: E3_ORIGIN, locale: "tr-TR" });
  page = await context.newPage();
});

test.afterAll(async () => {
  if (process.env.GITHUB_STEP_SUMMARY && summary.length > 0) {
    appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      `\n#### Panel kipi (gerçek panel-api)\n\n${summary.map((l) => `- ${l}`).join("\n")}\n`,
    );
  }
  await context?.close();
  await stack?.stop();
});

test("1. panel açık, yönetici girişi (sahte Google + TOTP)", async () => {
  await enrollAndLogin(page);
  note("GEÇTİ · panel-api + sahte OIDC ayakta; yönetici girişi ve iki adım kurulumu");
});

test("2. sessiz kurulum, Host rolü; servis panele bekleyen cihaz olarak ulaşıyor", async () => {
  const kur = client(["-Islem", "kur", "-Uygulama", APP_DIR, "-Rol", "host"]);
  expect(kur.kuruldu).toBe(true);
  expect(kur.rol).toBe("host");
  note(`GEÇTİ · --silent-install; servis ${String(kur.servis)} (${String(kur.baslangic)}), HKLM Role=host`);

  await expect
    .poll(async () => (await list("pending")).length, { timeout: 5 * 60_000, intervals: [3000] })
    .toBeGreaterThan(0);
  const pending = (await list("pending"))[0];
  state.rustdeskId = pending.rustdeskId;
  note(`GEÇTİ · servisin sysinfo'su panelde: bekleyen cihaz (RustDesk kimliği ${pending.rustdeskId})`);

  const kimlik = client(["-Islem", "kimlik"]);
  state.uuid = String(kimlik.uuid);
  state.pk = String(kimlik.pk);
  expect(state.pk).toMatch(/^[A-Za-z0-9_-]{43}$/);
});

test("3. kurulum girişi aynı id/uuid ile; tarayıcıda onay; kayıt (Host) → etkin", async () => {
  const json = { "content-type": "application/json" };
  const start = await fetch(`${E3_ORIGIN}/api/oidc/auth`, {
    method: "POST",
    headers: json,
    body: JSON.stringify({
      op: "Google",
      id: state.rustdeskId,
      uuid: state.uuid,
      deviceInfo: { os: "windows", type: "client", name: "Sense CI" },
      sense: { v: 1, purpose: "install" },
    }),
  });
  expect(start.status).toBe(200);
  const flow = (await start.json()) as { url: string; code: string; pairing_code: string };

  await approveInstallInBrowser(page, flow.url, async (shown) => {
    expect(shown).toBe(flow.pairing_code);
  });
  note("GEÇTİ · onay ekranındaki eşleştirme kodu = istemci akışının kodu; onay verildi");

  // İstemci gibi yokla (yoklama kodu ve anahtar hiçbir yere yazılmaz).
  const query = new URLSearchParams({ code: flow.code, id: state.rustdeskId, uuid: state.uuid });
  let token = "";
  await expect
    .poll(
      async () => {
        const res = await fetch(`${E3_ORIGIN}/api/oidc/auth-query?${query}`);
        const body = (await res.json()) as { access_token?: string };
        if (res.status === 200 && body.access_token) token = body.access_token;
        return token !== "";
      },
      { timeout: 60_000, intervals: [1000] },
    )
    .toBe(true);

  state.enrolledAt = Date.now();
  const enroll = await fetch(`${E3_ORIGIN}/api/sense/enroll`, {
    method: "POST",
    headers: { ...json, authorization: `Bearer ${token}` },
    body: JSON.stringify({
      v: 1,
      id: state.rustdeskId,
      uuid: state.uuid,
      role: "host",
      platform: "windows-x64",
      app_version: 1,
      name: "Sense CI Host",
      location: "GitHub Actions",
      note: "",
      project_ids: [],
      new_projects: [PROJECT],
      device_pk: state.pk,
    }),
  });
  const body = (await enroll.json()) as { device_id?: string; token_revoked?: boolean; error?: string };
  expect(enroll.status, `enroll: ${body.error ?? ""}`).toBe(200);
  expect(body.token_revoked).toBe(true);
  const check = await fetch(`${E3_ORIGIN}/api/device-group/accessible?current=1&pageSize=1`, {
    headers: { authorization: `Bearer ${token}` },
  });
  expect(check.status).toBe(401);
  token = "";
  note("GEÇTİ · kayıt 200 (aynı id/uuid, servisin açık anahtarı); Host'ta istemci anahtarı iptal (sonraki istek 401)");

  const active = (await list("active")).find((d) => d.rustdeskId === state.rustdeskId);
  expect(active?.status).toBe("active");
  state.deviceId = active?.id ?? "";
});

test("4. gerçek istemcinin heartbeat'i: sense + imzalı rapor (caps) + denetim", async () => {
  await expect
    .poll(
      async () => {
        const d = await detail(state.deviceId);
        const seen = d.lastSeenAt ? Date.parse(d.lastSeenAt) : 0;
        return seen > state.enrolledAt && d.appVersion !== null && (d.caps ?? []).includes("role_all");
      },
      { timeout: 5 * 60_000, intervals: [5000] },
    )
    .toBe(true);
  const d = await detail(state.deviceId);
  expect(d.status).toBe("active");
  expect(d.role).toBe("host");
  expect(d.reportKey).toBe("enrolled");
  note(
    `GEÇTİ · kayıttan sonra heartbeat: etkin, rol ${d.role}, sense.app_version=${d.appVersion}, caps=${JSON.stringify(d.caps)} (yalnız imzası doğrulanan rapordan yazılır), cihaz anahtarı kayıtlı`,
  );

  const audit = await auditOf(page, state.deviceId);
  const actions = audit.map((a) => a.action);
  expect(actions).toContain("device.enroll.install");
  expect(actions).not.toContain("alarm.device_report_signature");
  note("GEÇTİ · denetimde device.enroll.install; imza alarmı yok");

  mkdirSync(EVIDENCE, { recursive: true });
  await page.goto(`/panel/bilgisayar/${state.deviceId}`);
  await expect(page.getByText(/^Kurulumla eklendi · /)).toBeVisible();
  await page.screenshot({
    path: resolve(EVIDENCE, "panel-bilgisayar-ayrinti.png"),
    fullPage: true,
    mask: [
      page.getByText(/@[a-z0-9.-]+\.[a-z]{2,}/i),
      page.locator("td.font-mono"),
      page.locator("dd.font-mono"),
      page.locator("code"),
    ],
    maskColor: "#8a8a8a",
  });
});

test("5. Controller rolü: servis yeniden başlar, heartbeat sürüyor", async () => {
  client(["-Islem", "durdur"]);
  client(["-Islem", "rol", "-Rol", "controller"]);
  const restartedAt = Date.now();
  client(["-Islem", "baslat"]);
  await expect
    .poll(
      async () => {
        const d = await detail(state.deviceId);
        return d.lastSeenAt ? Date.parse(d.lastSeenAt) > restartedAt : false;
      },
      { timeout: 5 * 60_000, intervals: [5000] },
    )
    .toBe(true);
  const d = await detail(state.deviceId);
  expect(d.status).toBe("active");
  expect(d.caps ?? []).toContain("role_all");
  // Rol panelin kararıdır (G-3): istemcinin beyanı onaylı cihazda yazılmaz; panel "host" gösterir.
  note(
    `GEÇTİ · HKLM Role=controller + servis yeniden başlatıldı → yeni heartbeat (last_seen ilerledi); panel rolü ${d.role} (rol yalnız imzalı panel zarfıyla değişir)`,
  );
});
