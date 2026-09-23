// EQ GYM — Webhook PayOS: nhận báo "đã thanh toán" → kích hoạt Premium (qua payos_confirm).
//
// Triển khai (BẮT BUỘC --no-verify-jwt vì PayOS không gửi JWT của Supabase):
//   supabase functions deploy payos-webhook --no-verify-jwt
//   Rồi đăng ký URL ở PayOS: https://<project>.supabase.co/functions/v1/payos-webhook
//
// Kiểm chữ ký HMAC-SHA256 (checksum key) trước khi xử lý. Luôn trả 2xx để PayOS không
// retry vô ích — chữ ký sai thì chỉ bỏ qua, không kích hoạt gì. payos_confirm idempotent
// nên PayOS gửi trùng cũng không cộng Premium 2 lần.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHECKSUM = Deno.env.get("PAYOS_CHECKSUM_KEY") || "";

Deno.serve(async (req) => {
  if (req.method === "GET") return json({ ok: true, service: "payos-webhook" });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: any = null;
  try { body = await req.json(); } catch { return json({ ok: true, ignored: "no_body" }); }
  const data = body?.data;
  if (!data || typeof data !== "object") return json({ ok: true, ignored: "no_data" }); // ping khi đăng ký webhook
  if (!CHECKSUM) return json({ ok: false, error: "not_configured" });

  const valid = await verifySignature(data, String(body.signature || ""));
  if (!valid) { console.warn("payos-webhook: invalid signature", data.orderCode); return json({ ok: false, error: "invalid_signature" }); }
  if (body.success === false || String(data.code) !== "00") return json({ ok: true, ignored: "not_success" });

  const sb = createClient(SUPABASE_URL, SERVICE_KEY);
  const { data: result, error } = await sb.rpc("payos_confirm", {
    p_order_code: Number(data.orderCode), p_amount: Number(data.amount), p_ref: data.reference || null, p_raw: data,
  });
  if (error) console.error("payos_confirm", error.message);
  return json({ ok: true, result, error: error?.message });
});

// PayOS: sort key theo bảng chữ cái (đệ quy), nối k=v bằng &, null → "", object/array → JSON.
// Tài liệu PayOS có 2 mẫu (có/không encodeURIComponent) — chấp nhận cả 2 để không kẹt ở ký tự có dấu.
async function verifySignature(data: Record<string, unknown>, signature: string) {
  if (!signature) return false;
  const sorted = deepSort(data);
  const parts = Object.keys(sorted).filter((k) => sorted[k] !== undefined).map((k) => {
    let v: any = sorted[k];
    if (Array.isArray(v) || (v && typeof v === "object")) v = JSON.stringify(v);
    if (v === null || v === undefined || v === "null" || v === "undefined") v = "";
    return [k, String(v)];
  });
  const plain = parts.map(([k, v]) => `${k}=${v}`).join("&");
  const encoded = parts.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
  const want = signature.toLowerCase();
  return (await hmacHex(CHECKSUM, plain)) === want || (await hmacHex(CHECKSUM, encoded)) === want;
}

function deepSort(obj: any): any {
  if (Array.isArray(obj)) return obj.map((x) => (x && typeof x === "object" ? deepSort(x) : x));
  if (!obj || typeof obj !== "object") return obj;
  return Object.keys(obj).sort().reduce((acc: any, k) => { acc[k] = deepSort(obj[k]); return acc; }, {});
}

async function hmacHex(key: string, msg: string) {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, enc.encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });
}
