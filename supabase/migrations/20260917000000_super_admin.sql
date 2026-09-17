-- Super admin: đổi role tài khoản khác, xoá Premium, khoá (ban) người dùng.
-- An toàn chạy lại nhiều lần (idempotent ở mức hợp lý).

alter table public.profiles add column if not exists banned boolean not null default false;

-- is_admin() giờ tính cả super_admin (mọi quyền admin hiện có tự động áp dụng cho super_admin)
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('admin','super_admin'));
$$;

create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'super_admin');
$$;

create or replace function public.is_banned()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select banned from public.profiles where id = auth.uid()), false);
$$;

-- Chặn tài khoản bị khoá ghi dữ liệu mới (chặn ở tầng DB, không chỉ ẩn trên giao diện)
drop policy if exists progress_rw_own on public.progress;
create policy progress_rw_own on public.progress for all
  using (user_id = auth.uid()) with check (user_id = auth.uid() and not public.is_banned());

drop policy if exists practices_rw_own on public.practices;
create policy practices_rw_own on public.practices for all
  using (user_id = auth.uid()) with check (user_id = auth.uid() and not public.is_banned());

drop policy if exists assess_rw_own on public.assessments;
create policy assess_rw_own on public.assessments for all
  using (user_id = auth.uid()) with check (user_id = auth.uid() and not public.is_banned());

drop policy if exists pay_insert_own on public.payments;
create policy pay_insert_own on public.payments for insert
  with check (user_id = auth.uid() and not public.is_banned());

-- Đổi role tài khoản khác — chỉ super_admin, không tự đổi role của chính mình
create or replace function public.admin_set_role(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'not authorized'; end if;
  if p_user_id = auth.uid() then raise exception 'cannot modify your own account'; end if;
  if p_role not in ('user','admin','super_admin') then raise exception 'invalid role'; end if;
  update public.profiles set role = p_role where id = p_user_id;
end;
$$;
grant execute on function public.admin_set_role(uuid,text) to authenticated;

-- Xoá Premium của 1 tài khoản — chỉ super_admin
create or replace function public.admin_revoke_premium(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'not authorized'; end if;
  update public.profiles set premium_until = null where id = p_user_id;
end;
$$;
grant execute on function public.admin_revoke_premium(uuid) to authenticated;

-- Khoá/mở khoá tài khoản — chỉ super_admin, không tự khoá chính mình
create or replace function public.admin_set_banned(p_user_id uuid, p_banned boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'not authorized'; end if;
  if p_user_id = auth.uid() then raise exception 'cannot modify your own account'; end if;
  update public.profiles set banned = p_banned where id = p_user_id;
end;
$$;
grant execute on function public.admin_set_banned(uuid,boolean) to authenticated;
