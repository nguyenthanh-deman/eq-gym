-- Bỏ chuyển khoản tay (24/09/2026): mọi đơn do server tạo (Edge Function payos → pay_prepare_order),
-- tiền về qua SePay là tự mở Premium. Học viên không còn tự chèn đơn vào bảng payments được.
drop policy if exists pay_insert_own on public.payments;

-- Đơn QR PayOS cũ quá hạn chưa thanh toán (đã hỏi PayOS: EXPIRED, 0đ) → đóng cho khỏi treo "Chờ duyệt"
update public.payments set status = 'expired'
 where status = 'pending' and provider in ('payos', 'sepay') and expires_at < now() - interval '1 hour';
