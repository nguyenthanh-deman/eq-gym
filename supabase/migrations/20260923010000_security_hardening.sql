-- Vá bảo mật sau đợt rà soát 23/09/2026.
-- Postgres mặc định cấp EXECUTE mọi hàm mới cho PUBLIC → các hàm nội bộ (tiền tố "_")
-- gọi được thẳng qua API. Thu hồi, chỉ mở lại đúng những hàm app cần.

-- 1) Hàm nội bộ: chỉ được gọi từ bên trong các hàm security definer khác / service_role
do $$ declare f text; begin
  foreach f in array array[
    'public._activate_payment(uuid, text, jsonb, uuid)',
    'public._apply_code_for(uuid, text)',
    'public._claim_referral_for(uuid, text)',
    'public.setting_num(text, numeric)',
    'public.setting_bool(text, boolean)',
    'public.handle_new_user()'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- Sinh mã giới thiệu chạy trong trigger khi học viên tự tạo profile → phải là definer
-- để không cần cấp quyền gọi trực tiếp cho học viên.
alter function public.gen_ref_code() security definer set search_path = public;
alter function public.profiles_set_ref_code() security definer set search_path = public;
revoke execute on function public.gen_ref_code() from public, anon, authenticated;
revoke execute on function public.profiles_set_ref_code() from public, anon, authenticated;

-- 2) Hàm cho người đã đăng nhập: bỏ quyền của khách chưa đăng nhập (anon)
do $$ declare f text; begin
  foreach f in array array[
    'public.admin_affiliate_stats()', 'public.admin_approve_payment(uuid)',
    'public.admin_grant_premium(uuid, integer)', 'public.admin_revoke_premium(uuid)',
    'public.admin_set_banned(uuid, boolean)', 'public.admin_set_commission_status(uuid, text, text)',
    'public.admin_set_payment_status(uuid, text)', 'public.admin_set_role(uuid, text)',
    'public.admin_stats()', 'public.affiliate_me()', 'public.apply_code(text)',
    'public.claim_referral(text)', 'public.redeem_voucher(text)', 'public.leaderboard(integer)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
-- is_admin/is_banned/is_super_admin dùng trong RLS policy → giữ nguyên quyền cho anon/authenticated.

-- Hàm tạo mới về sau không tự mở cho anon nữa
alter default privileges in schema public revoke execute on functions from public, anon;

-- 3) Bảng thi đua: không lộ phần đầu email của người khác (trước đây hiện "tenemail" nếu chưa đặt tên)
create or replace function public.leaderboard(limit_n int default 50)
returns table(rank bigint, user_id uuid, display_name text, points bigint)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by pr.bounty desc)::bigint as rank,
         pr.user_id,
         coalesce(nullif(btrim(p.display_name), ''),
                  left(split_part(p.email, '@', 1), 3) || '***',
                  'Học viên') as display_name,
         pr.bounty as points
  from public.progress pr
  join public.profiles p on p.id = pr.user_id
  where not coalesce(p.banned, false)
  order by pr.bounty desc
  limit least(greatest(coalesce(limit_n, 50), 1), 100);
$$;

-- 4) Đơn chuyển khoản tay: server tự tính lại tiền / giảm giá / số tháng.
-- Trước đây học viên tự gửi được amount, months, voucher_code, discount_amount tuỳ ý
-- (vd months=1200 → admin bấm duyệt là cộng 100 năm Premium).
create or replace function public.payments_manual_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare a record; v_code text;
begin
  if new.provider is distinct from 'manual' then return new; end if;
  -- auth.role() lấy từ JWT của request (current_user trong hàm definer luôn là chủ hàm, không dùng được)
  if coalesce(auth.role(), '') not in ('anon', 'authenticated') then return new; end if;
  v_code := upper(btrim(coalesce(new.voucher_code, new.ref_code, '')));
  new.status := 'pending';
  new.months := public.setting_num('premium_months', 12)::int;
  new.discount_amount := 0; new.voucher_code := null; new.ref_code := null;
  new.order_code := null; new.payment_link_id := null; new.checkout_url := null; new.qr_code := null;
  new.expires_at := null; new.paid_at := null; new.provider_ref := null; new.provider_raw := null;
  new.approved_at := null; new.approved_by := null; new.note := null;
  if v_code <> '' then
    select * into a from public._apply_code_for(new.user_id, v_code);
    if a.ok then
      new.discount_amount := a.discount_amount;
      if a.kind = 'voucher' then new.voucher_code := v_code; else new.ref_code := v_code; end if;
    end if;
  end if;
  new.amount := greatest(0, public.setting_num('premium_price', 499000)::int - new.discount_amount);
  return new;
end $$;
revoke execute on function public.payments_manual_guard() from public, anon, authenticated;
drop trigger if exists payments_manual_guard_trg on public.payments;
create trigger payments_manual_guard_trg before insert on public.payments
  for each row execute function public.payments_manual_guard();

-- 5) Nhận sách tặng: chỉ Premium, mỗi người 1 lần, tối đa 50 suất — kiểm ở DB (trước chỉ kiểm ở app)
create or replace function public.book_claims_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_taken int;
begin
  -- auth.role() lấy từ JWT của request (current_user trong hàm definer luôn là chủ hàm, không dùng được)
  if coalesce(auth.role(), '') not in ('anon', 'authenticated') then return new; end if;
  if not exists (select 1 from public.profiles where id = new.user_id
                 and (role in ('admin', 'super_admin') or (premium_until is not null and premium_until > now()))) then
    raise exception 'Chỉ thành viên Premium mới nhận được sách';
  end if;
  if exists (select 1 from public.book_claims where user_id = new.user_id) then
    raise exception 'Bạn đã đăng ký nhận sách rồi';
  end if;
  perform pg_advisory_xact_lock(hashtext('book_claims_seq'));
  select count(*) into v_taken from public.book_claims;
  if v_taken >= 50 then raise exception 'Đã hết 50 suất sách'; end if;
  new.seq := v_taken + 1;
  new.status := 'pending';
  new.created_at := now();
  return new;
end $$;
revoke execute on function public.book_claims_guard() from public, anon, authenticated;
drop trigger if exists book_claims_guard_trg on public.book_claims;
create trigger book_claims_guard_trg before insert on public.book_claims
  for each row execute function public.book_claims_guard();

-- 6) Bảng cấu hình: cột ghi được thu hẹp; học viên không có quyền ghi bảng tiền/hoa hồng/voucher
revoke insert, update, delete, truncate on public.affiliate_commissions from anon, authenticated;
revoke insert, update, delete, truncate on public.affiliate_commissions_admin, public.payments_history from anon, authenticated;
revoke truncate on all tables in schema public from anon, authenticated;
revoke all on public.settings, public.vouchers, public.payments, public.profiles, public.progress,
  public.practices, public.assessments, public.book_claims, public.affiliate_commissions,
  public.affiliate_commissions_admin, public.payments_history from anon;
