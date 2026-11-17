import { resolve } from "node:path";
import { defineConfig, devices } from "@playwright/test";

// Sense Remote E4 (istemci deposu, ci/sense-e2e/panel): iş akışı bu klasörü panel deposunun
// `apps/panel-web/e2e-sense-ci/` altına kopyalar ve panel-web'in Playwright'ıyla çalıştırır.
// Yığın (sahte OIDC + gerçek panel-api) testin içinde Dalga 3 E2E'nin `startStack`'iyle kurulur.
// İz (trace) kapalı: ağ kaydında istemci anahtarı olabilirdi. Ekran görüntüsü yalnız hatada.

const ROOT = resolve(import.meta.dirname, "../../..");

export default defineConfig({
  testDir: ".",
  testMatch: "*.e2e.ts",
  outputDir: resolve(ROOT, "artifacts/sense-e2e/test-results"),
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 25 * 60_000,
  expect: { timeout: 15_000 },
  reporter: [["list"], ["github"]],
  use: {
    locale: "tr-TR",
    timezoneId: "Europe/Istanbul",
    trace: "off",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } },
    },
  ],
});
