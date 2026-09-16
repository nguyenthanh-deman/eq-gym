-- Voucher giảm giá + thống kê cho dashboard admin.
-- An toàn chạy lại nhiều lần (idempotent ở mức hợp lý).

-- 1) VOUCHERS -------------------------------------------------
create table if not exists public.vouchers (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  discount_amount int not null default 0,
  max_uses int,             -- null = không giới hạn lượt dùng
  used_count int not null default 0,
  active boolean not null default true,
  expires_at timestamptz,   -- null = không hết hạn
  created_at timestamptz not null default now()
);
alter table public.vouchers enable row level security;

drop policy if exists vouchers_admin_all on public.vouchers;
create policy vouchers_admin_all on public.vouchers for all
  using (public.is_admin()) with check (public.is_admin());

-- 2) PAYMENTS: lưu voucher đã dùng cho từng đơn ----------------
alter table public.payments add column if not exists voucher_code text;
alter table public.payments add column if not exists discount_amount int not null default 0;

-- 3) Kiểm tra + trừ lượt voucher an toàn (khoá dòng tránh đua lượt dùng
--    khi nhiều người áp cùng lúc — bài học từ vụ GAS/Sheets lỗi khi đồng thời) ---
create or replace function public.redeem_voucher(p_code text)
returns table(ok boolean, discount_amount int, message text)
language plpgsql security definer set search_path = public as $$
declare v public.vouchers%rowtype;
begin
  if p_code is null or btrim(p_code) = '' then
    return query select false, 0, 'Vui lòng nhập mã'; return;
  end if;
  select * into v from public.vouchers where upper(code) = upper(btrim(p_code)) for update;
  if not found or not v.active then
    return query select false, 0, 'Mã không tồn tại hoặc đã bị tắt'; return;
  end if;
  if v.expires_at is not null and v.expires_at < now() then
    return query select false, 0, 'Mã đã hết hạn'; return;
  end if;
  if v.max_uses is not null and v.used_count >= v.max_uses then
    return query select false, 0, 'Mã đã hết lượt sử dụng'; return;
  end if;
  update public.vouchers set used_count = used_count + 1 where id = v.id;
  return query select true, v.discount_amount, 'OK';
end;
$$;
grant execute on function public.redeem_voucher(text) to authenticated;

-- 4) Thống kê nhanh cho dashboard admin — chỉ admin gọi được -----
create or replace function public.admin_stats()
returns table(total_users bigint, premium_users bigint, pending_payments bigint, revenue bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  return query select
    (select count(*) from public.profiles)::bigint,
    (select count(*) from public.profiles where premium_until is not null and premium_until > now())::bigint,
    (select count(*) from public.payments where status = 'pending')::bigint,
    (select coalesce(sum(amount - discount_amount), 0) from public.payments where status = 'approved')::bigint;
end;
$$;
grant execute on function public.admin_stats() to authenticated;

-- 5) Voucher mặc định theo yêu cầu: giảm 199.000đ, không giới hạn lượt/hạn dùng
--    (chỉnh/tắt sau trong trang Quản trị của app)
insert into public.vouchers (code, discount_amount, active)
values ('EQGYM199K', 199000, true)
on conflict (code) do nothing;
