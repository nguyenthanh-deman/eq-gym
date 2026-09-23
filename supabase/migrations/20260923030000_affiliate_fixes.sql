-- Sửa 2 lỗi affiliate phát hiện khi test 23/09/2026:
-- 1) Người đã mua Premium nhập mã giới thiệu / mở link → bị từ chối giảm giá nhưng VẪN bị gắn
--    vĩnh viễn vào người giới thiệu (đếm sai số "đã giới thiệu"). Kiểm tra "đã mua" trước khi gắn.
-- 2) Đơn miễn phí 100% (voucher VIP) sinh khoản hoa hồng 0đ rác → bỏ qua khi hoa hồng = 0.

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
  if v_cur is not null then
    if v_cur = v_owner.id then return query select true, 'OK', v_owner.id; return; end if;
    return query select false, 'Tài khoản của bạn đã gắn với một người giới thiệu khác', null::uuid; return;
  end if;
  if exists (select 1 from public.payments where user_id = p_user and status = 'approved') then
    return query select false, 'Mã giới thiệu chỉ áp dụng cho lần nâng cấp đầu tiên', null::uuid; return;
  end if;
  update public.profiles set referred_by = v_owner.id, referred_at = now() where id = p_user;
  return query select true, 'OK', v_owner.id;
end $$;

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
    v_rate := public.setting_num('affiliate_rate', 0.2);
    v_hold := public.setting_num('affiliate_hold_days', 7)::int;
    v_comm := round(greatest(0, p.amount) * v_rate)::int;
    if v_comm > 0 then
      insert into public.affiliate_commissions (payment_id, referrer_id, referee_id, amount_paid, rate, commission, status, available_at)
      values (p.id, v_referrer, p.user_id, greatest(0, p.amount), v_rate, v_comm, 'pending', now() + (v_hold || ' days')::interval)
      on conflict (payment_id) do nothing;
    end if;
  end if;
end $$;

-- Dọn dữ liệu đã lỡ sinh ra: khoản hoa hồng 0đ và người đã mua trước khi được "gắn"
delete from public.affiliate_commissions where commission <= 0 and status = 'pending';
update public.profiles pr set referred_by = null, referred_at = null
 where pr.referred_by is not null
   and exists (select 1 from public.payments pa where pa.user_id = pr.id and pa.status = 'approved' and pa.approved_at < pr.referred_at);
