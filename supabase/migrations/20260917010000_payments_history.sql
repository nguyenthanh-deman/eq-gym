-- Chặn 1 học viên gửi nhiều yêu cầu thanh toán "pending" cùng lúc (tránh trùng khi
-- người dùng bấm gửi 2 lần) — chỉ chặn ở trạng thái pending, bị từ chối thì gửi lại được.
create unique index if not exists payments_one_pending_per_user
  on public.payments(user_id) where status = 'pending';

-- View lịch sử giao dịch — kèm sẵn email học viên, để trang Quản trị tìm/sắp/phân
-- trang được (payments không có cột email, phải join). security_invoker để RLS áp
-- dụng đúng theo người đang gọi (giống hệt quyền hiện có trên bảng payments/profiles).
create or replace view public.payments_history
with (security_invoker = true) as
select p.*, pr.email as user_email
from public.payments p
left join public.profiles pr on pr.id = p.user_id;

grant select on public.payments_history to authenticated;
