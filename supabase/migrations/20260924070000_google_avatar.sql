-- Ảnh đại diện + họ tên từ tài khoản Google (Supabase lưu trong auth.users.raw_user_meta_data).
-- Lưu vào profiles để trang Quản trị hiển thị. Họ tên để ở full_name (chỉ admin thấy), KHÔNG ghi vào
-- display_name — display_name hiện trên bảng thi đua, ghi tên thật vào đó là lộ danh tính học viên.
-- Học viên không tự sửa được 2 cột này (không có trong quyền ghi theo cột) → chỉ lấy từ Google.
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists full_name text;

create or replace function public.sync_profile_from_auth()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_avatar text; v_name text;
begin
  v_avatar := coalesce(new.raw_user_meta_data->>'avatar_url', new.raw_user_meta_data->>'picture');
  if v_avatar is not null and v_avatar !~ '^https://' then v_avatar := null; end if;
  v_name := nullif(btrim(coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', '')), '');
  update public.profiles
     set avatar_url = coalesce(v_avatar, avatar_url),
         full_name = coalesce(left(v_name, 120), full_name)
   where id = new.id;
  return new;
end $$;
revoke execute on function public.sync_profile_from_auth() from public, anon, authenticated;

-- Tên trigger xếp sau on_auth_user_created (trigger chạy theo thứ tự tên) → profile đã được tạo
drop trigger if exists on_auth_user_sync_profile on auth.users;
create trigger on_auth_user_sync_profile after insert or update of raw_user_meta_data on auth.users
  for each row execute function public.sync_profile_from_auth();

-- Lấy cho các tài khoản đã có
update public.profiles p
   set avatar_url = case when coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture') ~ '^https://'
                         then coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture') end,
       full_name = left(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name', '')), ''), 120)
  from auth.users u where u.id = p.id;

-- Trang chi tiết học viên trả thêm ảnh + họ tên
create or replace function public.admin_user_detail(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; pr public.profiles%rowtype;
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  select * into pr from public.profiles where id = p_user;
  if not found then return null; end if;
  select jsonb_build_object(
    'profile', jsonb_build_object(
      'id', pr.id, 'email', pr.email, 'display_name', pr.display_name, 'full_name', pr.full_name, 'avatar_url', pr.avatar_url,
      'role', pr.role, 'premium_until', pr.premium_until, 'banned', pr.banned, 'created_at', pr.created_at,
      'last_sign_in_at', (select last_sign_in_at from auth.users where id = pr.id),
      'provider', (select raw_app_meta_data->>'provider' from auth.users where id = pr.id),
      'pay_code', pr.pay_code, 'ref_code', pr.ref_code, 'affiliate_tier', pr.affiliate_tier,
      'affiliate_blocked', pr.affiliate_blocked, 'payout_info', pr.payout_info,
      'referred_by_email', (select email from public.profiles where id = pr.referred_by), 'referred_at', pr.referred_at),
    'progress', (select jsonb_build_object('done', done, 'bounty', bounty, 'streak', streak, 'last_date', last_date,
        'certs', certs, 'state', state - 'ans', 'updated_at', updated_at) from public.progress where user_id = p_user),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'status', status, 'provider', provider, 'amount', amount,
        'discount', discount_amount, 'voucher_code', voucher_code, 'ref_code', ref_code, 'created_at', created_at,
        'paid_at', paid_at, 'provider_ref', provider_ref, 'note', note, 'manual', approved_by is not null) order by created_at desc), '[]'::jsonb)
        from public.payments where user_id = p_user),
    'practices', (select coalesce(jsonb_agg(jsonb_build_object('lesson_n', lesson_n, 'score', score, 'by', by, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
        from (select * from public.practices where user_id = p_user order by created_at desc limit 100) x),
    'practices_total', (select count(*) from public.practices where user_id = p_user),
    'assessments', (select coalesce(jsonb_agg(jsonb_build_object('total', scores->'total', 'band', band, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
        from public.assessments where user_id = p_user),
    'referred', (select coalesce(jsonb_agg(jsonb_build_object('email', email, 'at', referred_at, 'premium', premium_until > now()) order by referred_at desc), '[]'::jsonb)
        from public.profiles where referred_by = p_user),
    'commissions', (select coalesce(jsonb_agg(jsonb_build_object('commission', commission, 'rate', rate, 'status', status, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
        from public.affiliate_commissions where referrer_id = p_user)
  ) into v;
  return v;
end $$;
