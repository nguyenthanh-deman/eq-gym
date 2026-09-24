// EQ GYM — Webhook SePay (biến động số dư): tiền vào tài khoản → khớp mã EQG… → mở Premium.
//
// Triển khai (BẮT BUỘC --no-verify-jwt vì SePay không gửi JWT Supabase):
//   supabase functions deploy sepay-webhook --no-verify-jwt
//   supabase secrets set SEPAY_WEBHOOK_KEY=<chuỗi bí mật>
// Cấu hình trong SePay → Webhooks:
//   URL: https://<project>.supabase.co/functions/v1/sepay-webhook
//   Sự kiện: Có tiền vào · Xác thực: API Key = SEPAY_WEBHOOK_KEY · Tiền tố mã thanh toán: EQG
//
// SePay yêu cầu phản hồi 200 + {"success": true} trong 30s, không thì gửi lại tối đa 7 lần;
// sepay_confirm chống xử lý trùng theo id giao dịch nên gửi lại không cộng Premium 2 lần.
// VietinBank: nội dung phải bắt đầu bằng "SEVQR" — mã EQG… vẫn được tách ra từ phần sau.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_KEY = Deno.env.get("SEPAY_WEBHOOK_KEY") || "";

const sb = createClient(SUPABASE_URL, SERVICE_KEY);

// Ghi nhật ký mọi lần gọi (không lưu API key) — admin xem trong bảng webhook_logs
async function log(status: number, result: string, d: any, code: string | null) {
  try {
    await sb.from("webhook_logs").insert({
      source: "sepay", status, result, code,
      amount: d?.transferAmount != null ? Number(d.transferAmount) || 0 : null,
      transfer_type: d?.transferType ?? null,
      ref: d?.id != null ? String(d.id) : (d?.referenceCode ?? null),
      content: d?.content != null ? String(d.content).slice(0, 300) : null,
    });
  } catch (e) { console.error("webhook_logs", String(e)); }
}

Deno.serve(async (req) => {
  if (req.method === "GET") return json({ success: true, service: "sepay-webhook", configured: !!WEBHOOK_KEY });
  if (req.method !== "POST") return json({ success: false, error: "method_not_allowed" }, 405);
  if (!WEBHOOK_KEY) { await log(503, "not_configured", null, null); return json({ success: false, error: "not_configured" }, 503); }

  let d: any = null;
  try { d = await req.json(); } catch { /* bỏ qua */ }

  const auth = (req.headers.get("Authorization") || "").trim();
  const given = auth.replace(/^apikey\s+/i, "").replace(/^bearer\s+/i, "");
  if (!safeEqual(given, WEBHOOK_KEY)) {
    await log(401, auth ? "unauthorized:sai_key" : "unauthorized:khong_co_key", d, null);
    return json({ success: false, error: "unauthorized" }, 401);
  }

  if (!d) { await log(200, "ignored:no_body", null, null); return json({ success: true, ignored: "no_body" }); }
  if (d.transferType !== "in") { await log(200, "ignored:not_incoming", d, null); return json({ success: true, ignored: "not_incoming" }); }

  const code = extractCode(d.code, d.content, d.description);
  if (!code) { await log(200, "ignored:no_eqg_code", d, null); return json({ success: true, ignored: "no_eqg_code" }); } // tiền vào không phải của app

  const { data: result, error } = await sb.rpc("sepay_confirm", {
    p_code: code,
    p_amount: Number(d.transferAmount) || 0,
    p_ref: d.id != null ? "SEPAY-" + d.id : (d.referenceCode || null),
    p_raw: d,
  });
  if (error) {
    console.error("sepay_confirm", error.message);
    await log(500, "db_error", d, code);
    return json({ success: false, error: "db_error" }, 500); // để SePay gửi lại sau
  }
  await log(200, String(result), d, code);
  return json({ success: true, result, code });
});

// Ưu tiên trường code SePay đã tách; không có thì tìm EQG + 8 số trong nội dung (bỏ qua tiền tố SEVQR, dấu cách)
function extractCode(...fields: unknown[]) {
  for (const f of fields) {
    const s = String(f ?? "").toUpperCase().replace(/[^A-Z0-9]/g, " ");
    const m = s.match(/EQG\s*(\d{8})/);
    if (m) return "EQG" + m[1];
  }
  return null;
}

function safeEqual(a: string, b: string) {
  if (!a || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });
}
