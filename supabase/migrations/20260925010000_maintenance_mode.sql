-- Chế độ bảo trì (25/09/2026): tạm đóng app chờ xử lý các vấn đề pháp lý.
-- Trang live thay bằng trang bảo trì; ở DB chặn tạo đơn thanh toán mới (phòng tab cũ còn mở
-- hoặc gọi thẳng API). Đơn đã tạo trước đó (≤ 30 phút) vẫn được webhook SePay xác nhận bình thường
-- để không ai chuyển tiền mà không được mở Premium.
-- Mở lại: update public.settings set value = 'true', updated_at = now() where key = 'payments_open';

insert into public.settings (key, value) values ('payments_open', 'false')
on conflict (key) do update set value = 'false', updated_at = now();

create or replace function public.pay_prepare_order(p_user uuid, p_code text, p_provider text)
returns table(payment_id uuid, order_code bigint, pay_code text, amount int, discount int, voucher_code text, ref_code text, months int, message text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_price int; v_months int; a record; v_disc int := 0; v_vc text; v_rc text; v_oc bigint; v_pc text; v_id uuid; i int := 0;
begin
  if p_provider not in ('payos', 'sepay') then raise exception 'invalid provider'; end if;
  if not public.setting_bool('payments_open', true) then
    return query select null::uuid, null::bigint, null::text, 0, 0, null::text, null::text, 0, 'maintenance'; return;
  end if;
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
