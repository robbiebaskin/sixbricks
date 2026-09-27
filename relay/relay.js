// Six Bricks — Interparcel quote relay.
// Gives Google Apps Script a fixed outbound IP for Interparcel's IP whitelist.
// Zero dependencies (Node 18+). Listens on localhost only; Caddy provides HTTPS in front.
// Only forwards POST /quote, only with the correct X-Relay-Secret header.
"use strict";
const http = require("http");
const crypto = require("crypto");

const PORT = 8080;
const KEY = process.env.INTERPARCEL_API_KEY;
const SECRET = process.env.RELAY_SECRET;
if (!KEY || !SECRET || SECRET.length < 32) {
  console.error("Missing INTERPARCEL_API_KEY or RELAY_SECRET (min 32 chars)");
  process.exit(1);
}
const secretBuf = Buffer.from(SECRET);
function authorised(h) {
  const b = Buffer.from(String(h || ""));
  return b.length === secretBuf.length && crypto.timingSafeEqual(b, secretBuf);
}

// Simple global rate limit: 60 requests per minute
let windowStart = Date.now(), count = 0;
function rateOk() {
  const now = Date.now();
  if (now - windowStart > 60000) { windowStart = now; count = 0; }
  return ++count <= 60;
}

function send(res, code, obj) {
  if (res.writableEnded) return;
  res.writeHead(code, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(JSON.stringify(obj));
}

http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") return send(res, 200, { ok: true });
  if (req.method !== "POST" || req.url !== "/quote") return send(res, 404, { error: "not-found" });
  if (!authorised(req.headers["x-relay-secret"])) return send(res, 403, { error: "denied" });
  if (!rateOk()) return send(res, 429, { error: "rate-limited" });

  let size = 0; const chunks = [];
  req.on("data", c => {
    size += c.length;
    if (size > 16384) { send(res, 413, { error: "too-large" }); req.destroy(); }
    else chunks.push(c);
  });
  req.on("end", async () => {
    if (res.writableEnded) return;
    let q;
    try { q = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
    catch (e) { return send(res, 400, { error: "bad-json" }); }
    if (!q || typeof q !== "object" || !q.collection || !q.delivery ||
        !Array.isArray(q.parcels) || q.parcels.length < 1 || q.parcels.length > 10) {
      return send(res, 400, { error: "bad-request" });
    }
    // Forward only the fields a quote needs
    const payload = { collection: q.collection, delivery: q.delivery, parcels: q.parcels };
    try {
      const r = await fetch("https://api.interparcel.com/quote", {
        method: "POST",
        headers: {
          "Content-Type": "application/json", "Accept": "application/json",
          "X-Interparcel-Auth": KEY, "X-Interparcel-API-Version": "3"
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(20000)
      });
      const text = await r.text();
      if (res.writableEnded) return;
      res.writeHead(r.status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      res.end(text);
    } catch (e) {
      console.error("upstream error:", e.name);   // never log request bodies (customer data)
      send(res, 502, { error: "upstream-unreachable" });
    }
  });
}).listen(PORT, "127.0.0.1", () => console.log("relay listening on 127.0.0.1:" + PORT));
