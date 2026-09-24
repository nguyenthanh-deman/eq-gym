-- Nhật ký mỗi lần cổng thanh toán gọi webhook (để kiểm tra cấu hình / đối soát khi học viên báo
-- đã chuyển mà chưa mở). Không lưu API key. Chỉ admin đọc; Edge Function ghi bằng service_role.
create table if not exists public.webhook_logs (
  id bigint generated always as identity primary key,
  source text not null,              -- sepay | payos
  status int not null,               -- HTTP trả về cho cổng
  result text,                       -- ok | already | underpaid | not_found | ignored:... | unauthorized ...
  code text,
  amount bigint,
  transfer_type text,
  ref text,
  content text,
  created_at timestamptz not null default now()
);
alter table public.webhook_logs enable row level security;
drop policy if exists webhook_logs_admin_read on public.webhook_logs;
create policy webhook_logs_admin_read on public.webhook_logs for select using (public.is_admin());
revoke all on public.webhook_logs from anon, authenticated;
grant select on public.webhook_logs to authenticated;
create index if not exists webhook_logs_created_idx on public.webhook_logs(created_at desc);
