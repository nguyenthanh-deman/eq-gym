-- Thanh toán tự động (PayOS) + Affiliate (mã giới thiệu kiêm voucher, hoa hồng %).
-- An toàn chạy lại nhiều lần (idempotent ở mức hợp lý).
--
-- Luồng chung: MỌI đường kích hoạt Premium (webhook PayOS, admin duyệt tay, đối soát)
-- đều đi qua _activate_payment() — nên trừ lượt voucher, cộng hạn Premium, tạo hoa hồng
-- affiliate chỉ viết đúng 1 chỗ, không lệch nhau giữa các đường.

-- ============================================================
-- 1) SETTINGS — cấu hình admin đổi được không cần deploy
-- ============================================================
create table if not exists public.settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.settings enable row level security;
drop policy if exists settings_read on public.settings;
create policy settings_read on public.settings for select to authenticated using (true);
drop policy if exists settings_admin_write on public.settings;
create policy settings_admin_write on public.settings for all
  using (public.is_admin()) with check (public.is_admin());

insert into public.settings (key, value) values
  ('premium_price', '499000'),
  ('premium_months', '12'),
  ('affiliate_enabled', 'true'),
  ('affiliate_rate', '0.2'),
  ('affiliate_referee_discount', '50000'),
  ('affiliate_hold_days', '7')
on conflict (key) do nothing;

create or replace function public.setting_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::numeric from public.settings where key = p_key), p_default);
$$;
create or replace function public.setting_bool(p_key text, p_default boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::boolean from public.settings where key = p_key), p_default);
$$;

-- ============================================================
-- 2) PAYMENTS — cột cho cổng thanh toán
-- ============================================================
alter table public.payments add column if not exists provider text not null default 'manual';
alter table public.payments add column if not exists order_code bigint;
alter table public.payments add column if not exists payment_link_id text;
alter table public.payments add column if not exists checkout_url text;
alter table public.payments add column if not exists qr_code text;
alter table public.payments add column if not exists expires_at timestamptz;
alter table public.payments add column if not exists paid_at timestamptz;
alter table public.payments add column if not exists provider_ref text;
alter table public.payments add column if not exists provider_raw jsonb;
alter table public.payments add column if not exists ref_code text;
alter table public.payments add column if not exists months int not null default 12;
create unique index if not exists payments_order_code_uq on public.payments(order_code) where order_code is not null;

-- Chỉ chặn trùng cho đường chuyển khoản tay; đơn PayOS bỏ dở được tự hết hạn khi tạo đơn mới
drop index if exists payments_one_pending_per_user;
create unique index if not exists payments_one_pending_per_user
  on public.payments(user_id) where status = 'pending' and provider = 'manual';

-- View lịch sử phải tạo lại để có cột mới (p.* chốt danh sách cột lúc tạo view)
drop view if exists public.payments_history;
create view public.payments_history with (security_invoker = true) as
select p.*, pr.email as user_email
from public.payments p
left join public.profiles pr on pr.id = p.user_id;
grant select on public.payments_history to authenticated;

-- Realtime để app biết ngay khi đơn được kích hoạt (RLS pay_select vẫn áp dụng)
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'payments') then
    alter publication supabase_realtime add table public.payments;
  end if;
end $$;

-- ============================================================
-- 3) PROFILES — mã giới thiệu
-- ============================================================
alter table public.profiles add column if not exists ref_code text;
alter table public.profiles add column if not exists referred_by uuid references public.profiles(id) on delete set null;
alter table public.profiles add column if not exists referred_at timestamptz;
alter table public.profiles add column if not exists payout_info jsonb;
alter table public.profiles add column if not exists affiliate_blocked boolean not null default false;
create unique index if not exists profiles_ref_code_uq on public.profiles(ref_code) where ref_code is not null;

-- Mã 6 ký tự, bỏ các ký tự dễ nhầm (0/O, 1/I/L); không trùng voucher để 1 ô nhập dùng chung
create or replace function public.gen_ref_code()
returns text language plpgsql as $$
declare chars text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; v_code text; i int;
begin
  loop
    v_code := '';
    for i in 1..6 loop v_code := v_code || substr(chars, 1 + floor(random() * length(chars))::int, 1); end loop;
    exit when not exists (select 1 from public.profiles pr where pr.ref_code = v_code)
         and not exists (select 1 from public.vouchers vo where upper(vo.code) = v_code);
  end loop;
  return v_code;
end $$;

create or replace function public.profiles_set_ref_code()
returns trigger language plpgsql as $$
begin
  if new.ref_code is null then new.ref_code := public.gen_ref_code(); end if;
  return new;
end $$;
drop trigger if exists profiles_ref_code_trg on public.profiles;
create trigger profiles_ref_code_trg before insert on public.profiles
  for each row execute function public.profiles_set_ref_code();

-- Cấp mã cho tài khoản đã có (từng dòng để không đụng unique khi random trùng trong 1 lệnh)
do $$ declare r record; begin
  for r in select id from public.profiles where ref_code is null loop
    update public.profiles set ref_code = public.gen_ref_code() where id = r.id;
  end loop;
end $$;

-- ============================================================
-- 4) AFFILIATE COMMISSIONS
-- ============================================================
create table if not exists public.affiliate_commissions (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid unique references public.payments(id) on delete cascade,
  referrer_id uuid references public.profiles(id) on delete cascade,
  referee_id uuid references public.profiles(id) on delete set null,
  amount_paid int not null,
  rate numeric not null,
  commission int not null,
  status text not null default 'pending',   -- pending | approved | paid | void
  available_at timestamptz,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  note text
);
alter table public.affiliate_commissions enable row level security;
drop policy if exists aff_select on public.affiliate_commissions;
create policy aff_select on public.affiliate_commissions for select
  using (referrer_id = auth.uid() or public.is_admin());
create index if not exists aff_referrer_idx on public.affiliate_commissions(referrer_id, status);

drop view if exists public.affiliate_commissions_admin;
create view public.affiliate_commissions_admin with (security_invoker = true) as
select c.*, r.email as referrer_email, r.payout_info as referrer_payout, e.email as referee_email
from public.affiliate_commissions c
left join public.profiles r on r.id = c.referrer_id
left join public.profiles e on e.id = c.referee_id;
grant select on public.affiliate_commissions_admin to authenticated;

-- ============================================================
-- 5) MÃ GIẢM GIÁ / MÃ GIỚI THIỆU — 1 ô nhập dùng chung
-- ============================================================
-- redeem_voucher giờ CHỈ kiểm tra, không trừ lượt — lượt trừ khi thanh toán thành công
-- (trước đây trừ lúc áp mã nên bỏ dở thanh toán cũng mất lượt).
create or replace function public.redeem_voucher(p_code text)
returns table(ok boolean, discount_amount int, message text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v public.vouchers%rowtype;
begin
  if p_code is null or btrim(p_code) = '' then return query select false, 0, 'Vui lòng nhập mã'; return; end if;
  select * into v from public.vouchers where upper(code) = upper(btrim(p_code));
  if not found or not v.active then return query select false, 0, 'Mã không tồn tại hoặc đã bị tắt'; return; end if;
  if v.expires_at is not null and v.expires_at < now() then return query select false, 0, 'Mã đã hết hạn'; return; end if;
  if v.max_uses is not null and v.used_count >= v.max_uses then return query select false, 0, 'Mã đã hết lượt sử dụng'; return; end if;
  return query select true, v.discount_amount, 'OK';
end $$;

-- Gắn người giới thiệu cho 1 user (1 lần, vĩnh viễn). Trả (ok, message, referrer_id)
create or replace function public._claim_referral_for(p_user uuid, p_code text)
returns table(ok boolean, message text, referrer_id uuid)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_owner public.profiles%rowtype; v_cur uuid;
begin
  select * into v_owner from public.profiles where ref_code = upper(btrim(coalesce(p_code, '')));
  if not found then return query select false, 'Mã không tồn tại', null::uuid; return; end if;
  if v_owner.id = p_user then return query select false, 'Không thể dùng mã giới thiệu của chính bạn', null::uuid; return; end if;
  if v_owner.banned or v_owner.affiliate_blocked then return query select false, 'Mã giới thiệu này không còn khả dụng', null::uuid; return; end if;
  select referred_by into v_cur from public.profiles where id = p_user;
  if v_cur is null then
    update public.profiles set referred_by = v_owner.id, referred_at = now() where id = p_user;
    return query select true, 'OK', v_owner.id; return;
  end if;
  if v_cur = v_owner.id then return query select true, 'OK', v_owner.id; return; end if;
  return query select false, 'Tài khoản của bạn đã gắn với một người giới thiệu khác', null::uuid;
end $$;

create or replace function public.claim_referral(p_code text)
returns table(ok boolean, message text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if auth.uid() is null then return query select false, 'Cần đăng nhập'; return; end if;
  return query select c.ok, c.message from public._claim_referral_for(auth.uid(), p_code) c;
end $$;
grant execute on function public.claim_referral(text) to authenticated;

-- Áp mã cho 1 user: voucher trước, không có thì thử mã giới thiệu. kind = voucher | ref
create or replace function public._apply_code_for(p_user uuid, p_code text)
returns table(ok boolean, kind text, discount_amount int, message text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_code text := upper(btrim(coalesce(p_code, ''))); r record; v_disc int;
begin
  if v_code = '' then return query select false, ''::text, 0, 'Vui lòng nhập mã'; return; end if;
  if exists (select 1 from public.vouchers where upper(code) = v_code) then
    select * into r from public.redeem_voucher(v_code);
    return query select r.ok, 'voucher'::text, r.discount_amount, r.message; return;
  end if;
  if not exists (select 1 from public.profiles where ref_code = v_code) then
    return query select false, ''::text, 0, 'Mã không tồn tại hoặc đã bị tắt'; return;
  end if;
  if not public.setting_bool('affiliate_enabled', true) then
    return query select false, 'ref'::text, 0, 'Chương trình giới thiệu đang tạm tắt'; return;
  end if;
  select * into r from public._claim_referral_for(p_user, v_code);
  if not r.ok then return query select false, 'ref'::text, 0, r.message; return; end if;
  if exists (select 1 from public.payments where user_id = p_user and status = 'approved') then
    return query select false, 'ref'::text, 0, 'Mã giới thiệu chỉ áp dụng cho lần nâng cấp đầu tiên'; return;
  end if;
  v_disc := public.setting_num('affiliate_referee_discount', 0)::int;
  return query select true, 'ref'::text, v_disc, 'OK';
end $$;

create or replace function public.apply_code(p_code text)
returns table(ok boolean, kind text, discount_amount int, message text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if auth.uid() is null then return query select false, ''::text, 0, 'Cần đăng nhập'; return; end if;
  return query select a.ok, a.kind, a.discount_amount, a.message from public._apply_code_for(auth.uid(), p_code) a;
end $$;
grant execute on function public.apply_code(text) to authenticated;

-- ============================================================
-- 6) KÍCH HOẠT PREMIUM — 1 hàm lõi cho mọi đường
-- ============================================================
create or replace function public._activate_payment(p_id uuid, p_ref text, p_raw jsonb, p_by uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p public.payments%rowtype; v_base timestamptz; v_referrer uuid; v_rate numeric; v_hold int;
begin
  select * into p from public.payments where id = p_id for update;
  if not found then raise exception 'payment not found'; end if;
  if p.status = 'approved' then return; end if;   -- webhook gọi trùng / đối soát lại: không cộng 2 lần

  update public.payments
     set status = 'approved', paid_at = coalesce(paid_at, now()), approved_at = now(), approved_by = p_by,
         provider_ref = coalesce(p_ref, provider_ref), provider_raw = coalesce(p_raw, provider_raw)
   where id = p.id;

  select premium_until into v_base from public.profiles where id = p.user_id;
  if v_base is null or v_base < now() then v_base := now(); end if;
  update public.profiles set premium_until = v_base + (coalesce(p.months, 12) || ' months')::interval where id = p.user_id;

  -- Đơn pending khác của cùng người (bỏ dở / gửi tay song song) → hết hạn, khỏi treo ở "Chờ duyệt"
  update public.payments set status = 'expired' where user_id = p.user_id and status = 'pending' and id <> p.id;

  if p.voucher_code is not null then
    update public.vouchers set used_count = used_count + 1 where upper(code) = upper(p.voucher_code);
  end if;

  -- Hoa hồng affiliate — chỉ trên tiền thật đã trả (amount đã trừ giảm giá)
  select referred_by into v_referrer from public.profiles where id = p.user_id;
  if v_referrer is not null and v_referrer <> p.user_id and public.setting_bool('affiliate_enabled', true)
     and not exists (select 1 from public.profiles where id = v_referrer and (banned or affiliate_blocked)) then
    v_rate := public.setting_num('affiliate_rate', 0.2);
    v_hold := public.setting_num('affiliate_hold_days', 7)::int;
    insert into public.affiliate_commissions (payment_id, referrer_id, referee_id, amount_paid, rate, commission, status, available_at)
    values (p.id, v_referrer, p.user_id, greatest(0, p.amount), v_rate, round(greatest(0, p.amount) * v_rate)::int, 'pending', now() + (v_hold || ' days')::interval)
    on conflict (payment_id) do nothing;
  end if;
end $$;

-- Admin duyệt tay (thay cho update trực tiếp 2 bảng ở trang Quản trị trước đây)
create or replace function public.admin_approve_payment(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  perform public._activate_payment(p_id, null, null, auth.uid());
end $$;
grant execute on function public.admin_approve_payment(uuid) to authenticated;

create or replace function public.admin_set_payment_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  if p_status not in ('rejected', 'expired', 'cancelled') then raise exception 'invalid status'; end if;
  update public.payments set status = p_status where id = p_id and status = 'pending';
end $$;
grant execute on function public.admin_set_payment_status(uuid, text) to authenticated;

-- ============================================================
-- 7) PAYOS — chỉ Edge Function (service_role) gọi được
-- ============================================================
-- Chuẩn bị đơn: tính tiền ở server (giá từ settings, giảm giá kiểm lại), hết hạn đơn PayOS cũ.
create or replace function public.payos_prepare_order(p_user uuid, p_code text)
returns table(payment_id uuid, order_code bigint, amount int, discount int, voucher_code text, ref_code text, months int, message text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_price int; v_months int; a record; v_disc int := 0; v_vc text; v_rc text; v_oc bigint; v_id uuid;
begin
  if exists (select 1 from public.profiles where id = p_user and banned) then
    return query select null::uuid, null::bigint, 0, 0, null::text, null::text, 0, 'banned'; return;
  end if;
  v_price := public.setting_num('premium_price', 499000)::int;
  v_months := public.setting_num('premium_months', 12)::int;
  if btrim(coalesce(p_code, '')) <> '' then
    select * into a from public._apply_code_for(p_user, p_code);
    if not a.ok then return query select null::uuid, null::bigint, 0, 0, null::text, null::text, 0, a.message; return; end if;
    v_disc := a.discount_amount;
    if a.kind = 'voucher' then v_vc := upper(btrim(p_code)); else v_rc := upper(btrim(p_code)); end if;
  end if;
  update public.payments set status = 'expired' where user_id = p_user and status = 'pending' and provider = 'payos';
  -- orderCode: ms epoch × 1000 + random 3 số → duy nhất, < 2^53 (giới hạn PayOS)
  v_oc := (extract(epoch from clock_timestamp()) * 1000)::bigint * 1000 + floor(random() * 1000)::bigint;
  insert into public.payments (user_id, amount, code, status, provider, order_code, voucher_code, discount_amount, ref_code, months, expires_at)
  values (p_user, greatest(0, v_price - v_disc), 'EQG' || right(v_oc::text, 6), 'pending', 'payos', v_oc, v_vc, v_disc, v_rc, v_months, now() + interval '30 minutes')
  returning id into v_id;
  return query select v_id, v_oc, greatest(0, v_price - v_disc), v_disc, v_vc, v_rc, v_months, 'OK';
end $$;
revoke execute on function public.payos_prepare_order(uuid, text) from public, anon, authenticated;
grant execute on function public.payos_prepare_order(uuid, text) to service_role;

-- Xác nhận đã nhận tiền (webhook / đối soát). Trả: ok | not_found | underpaid | already
create or replace function public.payos_confirm(p_order_code bigint, p_amount int, p_ref text, p_raw jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare p public.payments%rowtype;
begin
  select * into p from public.payments where order_code = p_order_code;
  if not found then return 'not_found'; end if;
  if p.status = 'approved' then return 'already'; end if;
  if p_amount is not null and p_amount < p.amount then
    update public.payments set note = 'Thiếu tiền: nhận ' || p_amount || ' / cần ' || p.amount, provider_raw = p_raw where id = p.id;
    return 'underpaid';
  end if;
  perform public._activate_payment(p.id, p_ref, p_raw, null);
  return 'ok';
end $$;
revoke execute on function public.payos_confirm(bigint, int, text, jsonb) from public, anon, authenticated;
grant execute on function public.payos_confirm(bigint, int, text, jsonb) to service_role;

-- Đơn PayOS bị huỷ/hết hạn phía cổng
create or replace function public.payos_close_order(p_order_code bigint, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('cancelled', 'expired') then raise exception 'invalid status'; end if;
  update public.payments set status = p_status where order_code = p_order_code and status = 'pending';
end $$;
revoke execute on function public.payos_close_order(bigint, text) from public, anon, authenticated;
grant execute on function public.payos_close_order(bigint, text) to service_role;

-- ============================================================
-- 8) AFFILIATE — cho học viên & admin
-- ============================================================
create or replace function public.affiliate_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles%rowtype; v jsonb;
begin
  if auth.uid() is null then return null; end if;
  select * into me from public.profiles where id = auth.uid();
  if me.ref_code is null then
    update public.profiles set ref_code = public.gen_ref_code() where id = me.id returning * into me;
  end if;
  select jsonb_build_object(
    'ref_code', me.ref_code,
    'blocked', me.affiliate_blocked,
    'enabled', public.setting_bool('affiliate_enabled', true),
    'rate', public.setting_num('affiliate_rate', 0.2),
    'referee_discount', public.setting_num('affiliate_referee_discount', 0),
    'hold_days', public.setting_num('affiliate_hold_days', 7),
    'payout_info', me.payout_info,
    'referred_count', (select count(*) from public.profiles where referred_by = me.id),
    'paid_count', (select count(*) from public.affiliate_commissions where referrer_id = me.id and status <> 'void'),
    'pending_sum', (select coalesce(sum(commission), 0) from public.affiliate_commissions where referrer_id = me.id and status in ('pending', 'approved')),
    'paid_sum', (select coalesce(sum(commission), 0) from public.affiliate_commissions where referrer_id = me.id and status = 'paid')
  ) into v;
  return v;
end $$;
grant execute on function public.affiliate_me() to authenticated;

create or replace function public.admin_set_commission_status(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  if p_status not in ('pending', 'approved', 'paid', 'void') then raise exception 'invalid status'; end if;
  update public.affiliate_commissions
     set status = p_status, paid_at = case when p_status = 'paid' then now() else paid_at end,
         note = coalesce(p_note, note)
   where id = p_id;
end $$;
grant execute on function public.admin_set_commission_status(uuid, text, text) to authenticated;

create or replace function public.admin_affiliate_stats()
returns table(pending_sum bigint, approved_sum bigint, paid_sum bigint, referrers bigint, referred_users bigint)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  return query select
    (select coalesce(sum(commission), 0) from public.affiliate_commissions where status = 'pending')::bigint,
    (select coalesce(sum(commission), 0) from public.affiliate_commissions where status = 'approved')::bigint,
    (select coalesce(sum(commission), 0) from public.affiliate_commissions where status = 'paid')::bigint,
    (select count(distinct referrer_id) from public.affiliate_commissions where status <> 'void')::bigint,
    (select count(*) from public.profiles where referred_by is not null)::bigint;
end $$;
grant execute on function public.admin_affiliate_stats() to authenticated;

-- ============================================================
-- 9) Sửa admin_stats: cột amount đã là tiền sau giảm giá — trước đây trừ giảm giá lần 2
-- ============================================================
create or replace function public.admin_stats()
returns table(total_users bigint, premium_users bigint, pending_payments bigint, revenue bigint)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  return query select
    (select count(*) from public.profiles)::bigint,
    (select count(*) from public.profiles where premium_until is not null and premium_until > now())::bigint,
    (select count(*) from public.payments where status = 'pending')::bigint,
    (select coalesce(sum(amount), 0) from public.payments where status = 'approved')::bigint;
end $$;

-- ============================================================
-- 10) BẢO MẬT — vá lỗ hổng có từ trước
-- ============================================================
-- Policy profiles_update_own cho học viên sửa CẢ DÒNG của mình → tự đặt role='super_admin'
-- hay premium_until='2099' được chỉ bằng 1 lệnh trên console trình duyệt. Giới hạn theo cột:
-- học viên chỉ ghi được email/tên/thông tin nhận hoa hồng; role, premium_until, banned,
-- referred_by, ref_code... chỉ đổi qua hàm security definer (admin_*, _activate_payment...).
revoke insert, update on public.profiles from anon, authenticated;
grant insert (id, email, display_name) on public.profiles to authenticated;
grant update (id, email, display_name, payout_info) on public.profiles to authenticated;

-- Học viên chỉ được tạo đơn chuyển khoản tay ở trạng thái chờ duyệt (trước đây tự chèn
-- được dòng status='approved' → sai số liệu doanh thu). Đơn PayOS do server tạo.
drop policy if exists pay_insert_own on public.payments;
create policy pay_insert_own on public.payments for insert
  with check (user_id = auth.uid() and not public.is_banned() and status = 'pending' and provider = 'manual');
