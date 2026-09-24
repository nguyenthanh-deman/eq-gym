-- Trang Quản trị: số liệu Tổng quan + xem chi tiết từng tài khoản.
-- Dữ liệu học (progress/practices/assessments) bị RLS khoá theo từng người → admin đọc qua
-- 2 hàm security definer dưới đây (kiểm is_admin bên trong). Ngày tính theo giờ Việt Nam.

create or replace function public.admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  tz constant text := 'Asia/Ho_Chi_Minh';
  today date := (now() at time zone tz)::date;
  paid_filter text;
  v jsonb;
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;

  with pay as (
    select p.*, (coalesce(p.paid_at, p.approved_at, p.created_at) at time zone tz)::date as d
    from public.payments p where p.status = 'approved'
  ),
  prof as (select *, (created_at at time zone tz)::date as d from public.profiles),
  days as (select generate_series(today - 29, today, interval '1 day')::date as d)
  select jsonb_build_object(
    'users', jsonb_build_object(
      'total', (select count(*) from prof),
      'premium', (select count(*) from prof where premium_until > now() or role in ('admin','super_admin')),
      'paid_premium', (select count(*) from prof where premium_until > now() and role = 'user'),
      'free', (select count(*) from prof where (premium_until is null or premium_until <= now()) and role = 'user'),
      'banned', (select count(*) from prof where banned),
      'staff', (select count(*) from prof where role in ('admin','super_admin')),
      'new_today', (select count(*) from prof where d = today),
      'new_7d', (select count(*) from prof where d > today - 7),
      'new_30d', (select count(*) from prof where d > today - 30)
    ),
    'revenue', jsonb_build_object(
      'total', (select coalesce(sum(amount),0) from pay),
      'today', (select coalesce(sum(amount),0) from pay where d = today),
      'd7', (select coalesce(sum(amount),0) from pay where d > today - 7),
      'd30', (select coalesce(sum(amount),0) from pay where d > today - 30),
      'orders_paid', (select count(*) from pay where amount > 0),
      'orders_free', (select count(*) from pay where amount = 0),
      'orders_30d', (select count(*) from pay where amount > 0 and d > today - 30),
      'avg_order', (select coalesce(round(avg(amount)),0) from pay where amount > 0)
    ),
    'orders_other', jsonb_build_object(
      'pending', (select count(*) from public.payments where status = 'pending'),
      'expired_30d', (select count(*) from public.payments where status in ('expired','cancelled') and created_at > now() - interval '30 days'),
      'created_30d', (select count(*) from public.payments where created_at > now() - interval '30 days')
    ),
    'by_method', (select coalesce(jsonb_agg(x order by x.sum desc), '[]'::jsonb) from (
        select case when amount = 0 then 'free' else provider end as method, count(*) as n, coalesce(sum(amount),0) as sum
        from pay group by 1) x),
    'daily', (select jsonb_agg(jsonb_build_object(
        'd', to_char(days.d, 'DD/MM'),
        'rev', (select coalesce(sum(amount),0) from pay where pay.d = days.d),
        'orders', (select count(*) from pay where pay.d = days.d and amount > 0),
        'signups', (select count(*) from prof where prof.d = days.d)) order by days.d) from days),
    'learning', jsonb_build_object(
      'active_7d', (select count(*) from public.progress where updated_at > now() - interval '7 days'),
      'active_today', (select count(*) from public.progress where (updated_at at time zone tz)::date = today),
      'learners', (select count(*) from public.progress where coalesce(array_length(done,1),0) > 0),
      'finished_30', (select count(*) from public.progress where coalesce(array_length(done,1),0) >= 30),
      'avg_done', (select coalesce(round(avg(coalesce(array_length(done,1),0))::numeric, 1), 0) from public.progress),
      'practices_7d', (select count(*) from public.practices where created_at > now() - interval '7 days'),
      'avg_score_7d', (select coalesce(round(avg(score)),0) from public.practices where created_at > now() - interval '7 days'),
      'assessments', (select count(*) from public.assessments),
      'certs', (select coalesce(sum((select count(*) from jsonb_object_keys(coalesce(certs,'{}'::jsonb)))),0) from public.progress),
      'max_streak', (select coalesce(max(streak),0) from public.progress)
    ),
    'funnel', (select jsonb_agg(jsonb_build_object('n', n, 'users', (select count(*) from public.progress where n = any(done))) order by n)
               from generate_series(0, 29) n),
    'top_vouchers', (select coalesce(jsonb_agg(x order by x.n desc), '[]'::jsonb) from (
        select upper(voucher_code) as code, count(*) as n, coalesce(sum(amount),0) as sum
        from pay where voucher_code is not null group by 1 order by 2 desc limit 5) x),
    'affiliate', jsonb_build_object(
      'enabled', public.setting_bool('affiliate_enabled', true),
      'referred_users', (select count(*) from public.profiles where referred_by is not null),
      'pending', (select coalesce(sum(commission),0) from public.affiliate_commissions where status = 'pending'),
      'approved', (select coalesce(sum(commission),0) from public.affiliate_commissions where status = 'approved'),
      'paid', (select coalesce(sum(commission),0) from public.affiliate_commissions where status = 'paid')
    ),
    'recent', (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
        select p.id, pr.email, p.amount, p.provider, p.voucher_code, coalesce(p.paid_at, p.approved_at) as at
        from public.payments p left join public.profiles pr on pr.id = p.user_id
        where p.status = 'approved' order by coalesce(p.paid_at, p.approved_at) desc nulls last limit 6) x),
    'generated_at', now()
  ) into v;
  return v;
end $$;
revoke execute on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;

-- Chi tiết 1 tài khoản: hồ sơ, tiến độ học, giao dịch, luyện tập, bài test EQ, affiliate.
-- Không trả nội dung câu trả lời luyện tập (nhật ký cá nhân của học viên) — chỉ điểm & thời gian.
create or replace function public.admin_user_detail(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; pr public.profiles%rowtype;
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  select * into pr from public.profiles where id = p_user;
  if not found then return null; end if;
  select jsonb_build_object(
    'profile', jsonb_build_object(
      'id', pr.id, 'email', pr.email, 'display_name', pr.display_name, 'role', pr.role,
      'premium_until', pr.premium_until, 'banned', pr.banned, 'created_at', pr.created_at,
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
revoke execute on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;
