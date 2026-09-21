-- Chứng nhận nhiều mốc (30/60/90/180/365 ngày chuỗi luyện tập) thay cho 1 chứng nhận
-- duy nhất trước đây — cần chỗ lưu trên server để đồng bộ đa thiết bị (trước đây cert
-- chỉ nằm trong localStorage, đổi máy là mất).
alter table public.progress add column if not exists certs jsonb not null default '{}'::jsonb;
