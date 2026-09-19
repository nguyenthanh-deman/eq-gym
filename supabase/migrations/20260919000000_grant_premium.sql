-- Cấp/gia hạn Premium thủ công cho 1 tài khoản — chỉ super_admin.
-- Bổ sung cho admin_revoke_premium() đã có (chỉ xoá), giờ có thêm chiều cấp/gia hạn.
-- Cộng dồn nếu đang còn hạn Premium (gia hạn thêm), tính từ hôm nay nếu đã hết hạn/chưa có.
create or replace function public.admin_grant_premium(p_user_id uuid, p_months int)
returns void language plpgsql security definer set search_path = public as $$
declare v_base timestamptz;
begin
  if not public.is_super_admin() then raise exception 'not authorized'; end if;
  if p_months is null or p_months <= 0 then raise exception 'invalid months'; end if;
  select premium_until into v_base from public.profiles where id = p_user_id;
  if v_base is null or v_base < now() then v_base := now(); end if;
  update public.profiles set premium_until = v_base + (p_months || ' months')::interval where id = p_user_id;
end;
$$;
grant execute on function public.admin_grant_premium(uuid,int) to authenticated;
