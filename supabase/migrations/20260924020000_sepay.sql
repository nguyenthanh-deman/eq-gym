-- SePay (webhook biến động số dư). App tự sinh VietQR tới tài khoản nhận tiền; SePay báo tiền vào
-- kèm mã thanh toán (tiền tố EQG) → sepay_confirm khớp đơn → _activate_payment (dùng chung với PayOS).

-- Tạo đơn chung cho mọi cổng. Mã đơn EQG + 8 số, không trùng với đơn đang chờ.
create or replace function public.pay_prepare_order(p_user uuid, p_code text, p_provider text)
returns table(payment_id uuid, order_code bigint, pay_code text, amount int, discount int, voucher_code text, ref_code text, months int, message text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_price int; v_months int; a record; v_disc int := 0; v_vc text; v_rc text; v_oc bigint; v_pc text; v_id uuid; i int := 0;
begin
  if p_provider not in ('payos', 'sepay') then raise exception 'invalid provider'; end if;
  if exists (select 1 from public.profiles where id = p_user and banned) then
    return query select null::uuid, null::bigint, null::text, 0, 0, null::text, null::text, 0, 'banned'; return;
  end if;
  v_price := public.setting_num('premium_price', 499000)::int;
  v_months := public.setting_num('premium_months', 0)::int;
  if btrim(coalesce(p_code, '')) <> '' then
    select * into a from public._apply_code_for(p_user, p_code);
    if not a.ok then return query select null::uuid, null::bigint, null::text, 0, 0, null::text, null::text, 0, a.message; return; end if;
    v_disc := a.discount_amount;
    if a.kind = 'voucher' then v_vc := upper(btrim(p_code)); else v_rc := upper(btrim(p_code)); end if;
  end if;
  update public.payments set status = 'expired' where user_id = p_user and status = 'pending' and provider in ('payos', 'sepay');
  loop
    v_oc := (extract(epoch from clock_timestamp()) * 1000)::bigint * 1000 + floor(random() * 1000)::bigint;
    v_pc := 'EQG' || right(v_oc::text, 8);
    exit when not exists (select 1 from public.payments where code = v_pc and status = 'pending');
    i := i + 1; if i > 5 then raise exception 'could not allocate payment code'; end if;
  end loop;
  insert into public.payments (user_id, amount, code, status, provider, order_code, voucher_code, discount_amount, ref_code, months, expires_at)
  values (p_user, greatest(0, v_price - v_disc), v_pc, 'pending', p_provider, v_oc, v_vc, v_disc, v_rc, v_months, now() + interval '30 minutes')
  returning id into v_id;
  return query select v_id, v_oc, v_pc, greatest(0, v_price - v_disc), v_disc, v_vc, v_rc, v_months, 'OK';
end $$;
revoke execute on function public.pay_prepare_order(uuid, text, text) from public, anon, authenticated;
grant execute on function public.pay_prepare_order(uuid, text, text) to service_role;

-- Tiền về qua SePay. p_ref = id giao dịch SePay (SePay gửi lại tối đa 7 lần → chống xử lý trùng).
-- Trả: ok | already | not_found | underpaid. Khớp cả đơn vừa hết hạn 30 phút (học viên chuyển trễ vẫn được mở).
create or replace function public.sepay_confirm(p_code text, p_amount int, p_ref text, p_raw jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare p public.payments%rowtype;
begin
  if p_ref is not null and exists (select 1 from public.payments where provider = 'sepay' and provider_ref = p_ref and status = 'approved') then
    return 'already';
  end if;
  select * into p from public.payments
   where provider = 'sepay' and code = upper(btrim(p_code)) and status in ('pending', 'expired', 'approved')
   order by (status = 'pending') desc, created_at desc limit 1 for update;
  if not found then return 'not_found'; end if;
  if p.status = 'approved' then return 'already'; end if;
  if p_amount is not null and p_amount < p.amount then
    update public.payments set note = 'Thiếu tiền: nhận ' || p_amount || ' / cần ' || p.amount, provider_raw = p_raw, provider_ref = p_ref where id = p.id;
    return 'underpaid';
  end if;
  perform public._activate_payment(p.id, p_ref, p_raw, null);
  return 'ok';
end $$;
revoke execute on function public.sepay_confirm(text, int, text, jsonb) from public, anon, authenticated;
grant execute on function public.sepay_confirm(text, int, text, jsonb) to service_role;

create index if not exists payments_code_idx on public.payments(code) where code is not null;
