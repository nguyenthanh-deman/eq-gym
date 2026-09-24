-- Affiliate 3 hạng (24/09/2026): standard 20% (học viên / cá nhân) · partner 40% (tổ chức, đối tác)
-- · trusted 60% (đối tác tin cậy). Hạng là trường RIÊNG (không gộp vào role) để đối tác nhận % cao
-- không kèm quyền quản trị. Chỉ super admin đổi hạng từng người & sửa % mỗi hạng.

alter table public.profiles add column if not exists affiliate_tier text not null default 'standard';
alter table public.profiles drop constraint if exists profiles_affiliate_tier_chk;
alter table public.profiles add constraint profiles_affiliate_tier_chk check (affiliate_tier in ('standard', 'partner', 'trusted'));

insert into public.settings (key, value) values
  ('affiliate_tiers', jsonb_build_object('standard', coalesce((select (value #>> '{}')::numeric from public.settings where key = 'affiliate_rate'), 0.2), 'partner', 0.4, 'trusted', 0.6))
on conflict (key) do nothing;

create or replace function public.affiliate_rate_for(p_user uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (s.value ->> coalesce(p.affiliate_tier, 'standard'))::numeric
       from public.settings s, public.profiles p where s.key = 'affiliate_tiers' and p.id = p_user),
    case (select affiliate_tier from public.profiles where id = p_user) when 'trusted' then 0.6 when 'partner' then 0.4 else 0.2 end);
$$;
revoke execute on function public.affiliate_rate_for(uuid) from public, anon, authenticated;

-- Cấu hình (giá, % hoa hồng, bật/tắt…) chỉ super admin sửa; admin thường vẫn xem được
drop policy if exists settings_admin_write on public.settings;
create policy settings_admin_write on public.settings for all
  using (public.is_super_admin()) with check (public.is_super_admin());

create or replace function public.admin_set_affiliate_tier(p_user_id uuid, p_tier text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'not authorized'; end if;
  if p_tier not in ('standard', 'partner', 'trusted') then raise exception 'invalid tier'; end if;
  update public.profiles set affiliate_tier = p_tier where id = p_user_id;
end $$;
revoke execute on function public.admin_set_affiliate_tier(uuid, text) from public, anon;
grant execute on function public.admin_set_affiliate_tier(uuid, text) to authenticated;

-- Hoa hồng tính theo hạng của người giới thiệu tại thời điểm đơn được thanh toán
create or replace function public._activate_payment(p_id uuid, p_ref text, p_raw jsonb, p_by uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p public.payments%rowtype; v_base timestamptz; v_referrer uuid; v_rate numeric; v_hold int; v_comm int;
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
    v_rate := public.affiliate_rate_for(v_referrer);
    v_hold := public.setting_num('affiliate_hold_days', 7)::int;
    v_comm := round(greatest(0, p.amount) * v_rate)::int;
    if v_comm > 0 then
      insert into public.affiliate_commissions (payment_id, referrer_id, referee_id, amount_paid, rate, commission, status, available_at)
      values (p.id, v_referrer, p.user_id, greatest(0, p.amount), v_rate, v_comm, 'pending', now() + (v_hold || ' days')::interval)
      on conflict (payment_id) do nothing;
    end if;
  end if;
end $$;

-- Học viên thấy đúng % theo hạng của mình
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
    'tier', me.affiliate_tier,
    'rate', public.affiliate_rate_for(me.id),
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
