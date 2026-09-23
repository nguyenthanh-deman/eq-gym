// EQ GYM — Edge Function PayOS: tạo đơn (QR động) + đối soát lại theo orderCode.
//
// Triển khai:
//   supabase functions deploy payos
//   supabase secrets set PAYOS_CLIENT_ID=... PAYOS_API_KEY=... PAYOS_CHECKSUM_KEY=...
//   (tuỳ chọn) PAYOS_RETURN_URL=https://app.evolve.vn/eq-gym/
//
// Chưa có key → trả 503 payos_not_configured, app tự rơi về chuyển khoản tay.
// Tiền tính ở DB (payos_prepare_order) — client không gửi số tiền lên.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CLIENT_ID = Deno.env.get("PAYOS_CLIENT_ID") || "";
const API_KEY = Deno.env.get("PAYOS_API_KEY") || "";
const CHECKSUM = Deno.env.get("PAYOS_CHECKSUM_KEY") || "";
const RETURN_URL = (Deno.env.get("PAYOS_RETURN_URL") || "https://app.evolve.vn/eq-gym/").replace(/\?.*$/, "");
const API = "https://api-merchant.payos.vn";
const CONFIGURED = !!(CLIENT_ID && API_KEY && CHECKSUM);
const EXPIRE_MIN = 30;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!token) return json({ error: "unauthorized" }, 401);
    const sb = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: userData } = await sb.auth.getUser(token);
    const user = userData?.user;
    if (!user) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const action = body?.action;

    if (action === "create") {
      if (!CONFIGURED) return json({ error: "payos_not_configured" }, 503);
      const { data, error } = await sb.rpc("payos_prepare_order", { p_user: user.id, p_code: String(body.code || "") });
      const o = data?.[0];
      if (error || !o) return json({ error: "prepare_failed", message: error?.message }, 500);
      if (o.message !== "OK") return json({ error: "code_rejected", message: o.message }, 400);

      // Giảm giá phủ hết tiền → kích hoạt luôn, không qua cổng
      if (o.amount <= 0) {
        const r = await sb.rpc("payos_confirm", { p_order_code: o.order_code, p_amount: 0, p_ref: "FREE", p_raw: null });
        return json({ free: true, payment_id: o.payment_id, result: r.data, error: r.error?.message });
      }

      const description = "EQG" + String(o.order_code).slice(-6); // ≤ 9 ký tự (giới hạn PayOS với ngân hàng chưa liên kết)
      const expiredAt = Math.floor(Date.now() / 1000) + EXPIRE_MIN * 60;
      const returnUrl = RETURN_URL + "?pay=done", cancelUrl = RETURN_URL + "?pay=cancel";
      const signature = await hmacHex(CHECKSUM, `amount=${o.amount}&cancelUrl=${cancelUrl}&description=${description}&orderCode=${o.order_code}&returnUrl=${returnUrl}`);
      const r = await fetch(API + "/v2/payment-requests", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-client-id": CLIENT_ID, "x-api-key": API_KEY },
        body: JSON.stringify({
          orderCode: o.order_code, amount: o.amount, description, returnUrl, cancelUrl, expiredAt,
          buyerEmail: user.email || undefined,
          items: [{ name: `EQ GYM Premium ${o.months} thang`, quantity: 1, price: o.amount }],
          signature,
        }),
      });
      const pr = await r.json().catch(() => ({}));
      if (!r.ok || pr.code !== "00" || !pr.data) {
        await sb.from("payments").update({ status: "cancelled", note: "PayOS: " + (pr.desc || ("HTTP " + r.status)) }).eq("id", o.payment_id);
        return json({ error: "payos_error", message: pr.desc || ("HTTP " + r.status) }, 502);
      }
      const d = pr.data;
      await sb.from("payments").update({ checkout_url: d.checkoutUrl, qr_code: d.qrCode, payment_link_id: d.paymentLinkId }).eq("id", o.payment_id);
      return json({
        payment_id: o.payment_id, order_code: o.order_code, amount: o.amount, discount: o.discount, months: o.months,
        checkout_url: d.checkoutUrl, qr_code: d.qrCode, bin: d.bin, account_number: d.accountNumber, account_name: d.accountName,
        description: d.description, expires_at: new Date(expiredAt * 1000).toISOString(),
      });
    }

    if (action === "recheck") {
      if (!CONFIGURED) return json({ error: "payos_not_configured" }, 503);
      const { data: p } = await sb.from("payments").select("id,user_id,order_code,status,amount").eq("id", body.payment_id).maybeSingle();
      if (!p || !p.order_code) return json({ error: "not_found" }, 404);
      if (p.user_id !== user.id) {
        const { data: prof } = await sb.from("profiles").select("role").eq("id", user.id).maybeSingle();
        if (prof?.role !== "admin" && prof?.role !== "super_admin") return json({ error: "forbidden" }, 403);
      }
      if (p.status === "approved") return json({ status: "PAID", result: "already" });
      const r = await fetch(API + "/v2/payment-requests/" + p.order_code, { headers: { "x-client-id": CLIENT_ID, "x-api-key": API_KEY } });
      const pr = await r.json().catch(() => ({}));
      const d = pr?.data;
      if (!r.ok || !d) return json({ error: "payos_error", message: pr?.desc || ("HTTP " + r.status) }, 502);
      if (d.status === "PAID") {
        const tx = Array.isArray(d.transactions) && d.transactions[0];
        const res = await sb.rpc("payos_confirm", { p_order_code: p.order_code, p_amount: d.amountPaid ?? d.amount, p_ref: tx?.reference || null, p_raw: d });
        return json({ status: "PAID", result: res.data, error: res.error?.message });
      }
      if (d.status === "CANCELLED" || d.status === "EXPIRED") {
        await sb.rpc("payos_close_order", { p_order_code: p.order_code, p_status: d.status.toLowerCase() });
        return json({ status: d.status });
      }
      return json({ status: d.status || "PENDING" });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

async function hmacHex(key: string, msg: string) {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, enc.encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
