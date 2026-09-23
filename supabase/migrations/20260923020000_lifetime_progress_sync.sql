-- 1) PREMIUM TRỌN ĐỜI (chính sách của EQ GYM: mua 1 lần, dùng mãi).
-- Lưu premium_until = 2999-12-31 thay vì 'infinity' vì JS new Date('infinity') là Invalid Date
-- → mọi phép so sánh "còn hạn" ở app sẽ sai. months = 0 nghĩa là trọn đời.
update public.settings set value = '0', updated_at = now() where key = 'premium_months';
alter table public.payments alter column months set default 0;

create or replace function public.premium_lifetime_until()
returns timestamptz language sql immutable as $$ select '2999-12-31 00:00:00+00'::timestamptz $$;

create or replace function public._activate_payment(p_id uuid, p_ref text, p_raw jsonb, p_by uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p public.payments%rowtype; v_base timestamptz; v_referrer uuid; v_rate numeric; v_hold int;
begin
  select * into p from public.payments where id = p_id for update;
  if not found then raise exception 'payment not found'; end if;
  if p.status = 'approved' then return; end if;

  update public.payments
     set status = 'approved', paid_at = coalesce(paid_at, now()), approved_at = now(), approved_by = p_by,
         provider_ref = coalesce(p_ref, provider_ref), provider_raw = coalesce(p_raw, provider_raw)
   where id = p.id;

  if coalesce(p.months, 0) <= 0 then
    update public.profiles set premium_until = public.premium_lifetime_until() where id = p.user_id;
  else
    select premium_until into v_base from public.profiles where id = p.user_id;
    if v_base is null or v_base < now() then v_base := now(); end if;
    update public.profiles set premium_until = least(public.premium_lifetime_until(), v_base + (p.months || ' months')::interval)
     where id = p.user_id;
  end if;

  update public.payments set status = 'expired' where user_id = p.user_id and status = 'pending' and id <> p.id;

  if p.voucher_code is not null then
    update public.vouchers set used_count = used_count + 1 where upper(code) = upper(p.voucher_code);
  end if;

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

-- Admin cấp tay: p_months = 0 → trọn đời
create or replace function public.admin_grant_premium(p_user_id uuid, p_months int)
returns void language plpgsql security definer set search_path = public as $$
declare v_base timestamptz;
begin
  if not public.is_super_admin() then raise exception 'not authorized'; end if;
  if p_months is null or p_months < 0 then raise exception 'invalid months'; end if;
  if p_months = 0 then
    update public.profiles set premium_until = public.premium_lifetime_until() where id = p_user_id; return;
  end if;
  select premium_until into v_base from public.profiles where id = p_user_id;
  if v_base is null or v_base < now() then v_base := now(); end if;
  update public.profiles set premium_until = least(public.premium_lifetime_until(), v_base + (p_months || ' months')::interval) where id = p_user_id;
end $$;

-- Chuyển toàn bộ học viên đang Premium (và người từng thanh toán) sang trọn đời
update public.profiles set premium_until = public.premium_lifetime_until()
 where (premium_until is not null and premium_until > now())
    or id in (select user_id from public.payments where status = 'approved');
update public.payments set months = 0 where status = 'pending';

-- 2) ĐỒNG BỘ ĐỦ TRẠNG THÁI HỌC — trước chỉ lưu done/bounty/streak/graded/scen/certs; ngày nghỉ phép,
-- kỷ lục chuỗi, chuỗi vừa đứt, câu trả lời workbook… chỉ nằm trong máy → đổi máy là mất.
alter table public.progress add column if not exists state jsonb not null default '{}'::jsonb;

-- 3) CHẶN SỐ LIỆU VÔ LÝ Ở SERVER — điểm/chuỗi được tính ở app nên sửa tay được qua API.
-- Chuỗi ngày không thể dài hơn số ngày từ khi app mở (01/09/2026) hoặc từ khi tài khoản được tạo
-- (lấy ngày sớm hơn, để học viên thời dùng thử Apps Script không bị cắt oan); +1 bù lệch múi giờ.
-- Chứng nhận mốc N ngày chỉ giữ lại khi đủ điều kiện đó → không tự tạo chứng nhận 365 ngày được.
create or replace function public.progress_sanity_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_start date; v_max int; k text; v_certs jsonb := '{}'::jsonb;
begin
  if coalesce(auth.role(), '') not in ('anon', 'authenticated') then return new; end if;
  select least(coalesce(created_at::date, current_date), date '2026-09-01') into v_start from public.profiles where id = new.user_id;
  v_max := (current_date - coalesce(v_start, date '2026-09-01')) + 2;
  new.streak := greatest(0, least(coalesce(new.streak, 0), v_max));
  if new.state ? 'bestStreak' and (new.state->>'bestStreak') ~ '^\d+$' then
    new.state := jsonb_set(new.state, '{bestStreak}', to_jsonb(least((new.state->>'bestStreak')::int, v_max)));
  end if;
  if new.certs is not null and jsonb_typeof(new.certs) = 'object' then
    for k in select jsonb_object_keys(new.certs) loop
      if k ~ '^\d+$' and k::int <= v_max then v_certs := v_certs || jsonb_build_object(k, new.certs->k); end if;
    end loop;
    new.certs := v_certs;
  end if;
  if coalesce(new.bounty, 0) < 0 then new.bounty := 0; end if;
  new.updated_at := least(coalesce(new.updated_at, now()), now() + interval '5 minutes');
  return new;
end $$;
revoke execute on function public.progress_sanity_guard() from public, anon, authenticated;
drop trigger if exists progress_sanity_trg on public.progress;
create trigger progress_sanity_trg before insert or update on public.progress
  for each row execute function public.progress_sanity_guard();

grant insert (state), update (state) on public.progress to authenticated;
