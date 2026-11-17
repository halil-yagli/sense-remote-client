// Sense Remote uçtan uca testi (E4), panelsiz kip: yerel KAYIT sunucusu.
// Panel deposuna erişim (SENSE_PANEL_READ_TOKEN) yokken istemcinin panele giden isteklerini
// (sysinfo, heartbeat) 127.0.0.1'de karşılar ve satır satır JSON olarak kaydeder; doğrulamayı
// `dogrula.mjs` yapar. Panelin yerini TUTMAZ (kayıt, onay, zarf yok); yalnız istemcinin ne
// gönderdiğini görünür kılar. Dış ağa çıkmaz, bağımlılığı yok (Node 24).
//
// Kullanım: node kayit-sunucusu.mjs <port> <kayıt.jsonl>

import { appendFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const port = Number(process.argv[2]);
const file = process.argv[3];
if (!Number.isInteger(port) || !file) {
  process.stderr.write("kullanım: node kayit-sunucusu.mjs <port> <kayıt.jsonl>\n");
  process.exit(2);
}
writeFileSync(file, "");

const server = createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const path = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
    let body = null;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "null");
    } catch {
      body = null;
    }
    appendFileSync(file, `${JSON.stringify({ at: Date.now(), method: req.method, path, body })}\n`);
    if (req.method === "POST" && path === "/api/sysinfo") {
      res.writeHead(200, { "content-type": "text/plain" }).end("SYSINFO_UPDATED");
    } else if (req.method === "POST" && path === "/api/heartbeat") {
      // Onaylı cihaza panelin verdiği en küçük yanıt (zarf yok).
      res
        .writeHead(200, { "content-type": "application/json" })
        .end(JSON.stringify({ sense_server_time: Math.floor(Date.now() / 1000) }));
    } else {
      res.writeHead(404, { "content-type": "application/json" }).end('{"error":"not_found"}');
    }
  });
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`[kayit-sunucusu] http://127.0.0.1:${port} dinleniyor\n`);
});
