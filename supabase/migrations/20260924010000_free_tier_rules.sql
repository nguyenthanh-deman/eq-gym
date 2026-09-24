-- Quy tắc tài khoản miễn phí (24/09/2026): vẫn học thử & cộng điểm nhưng KHÔNG lên bảng thi đua
-- (và không tiêu EP — chặn ở app). Chỉ Premium + admin mới được xếp hạng.
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
    and (p.role in ('admin', 'super_admin') or (p.premium_until is not null and p.premium_until > now()))
  order by pr.bounty desc
  limit least(greatest(coalesce(limit_n, 50), 1), 100);
$$;

-- Cấp Premium trọn đời theo yêu cầu admin
update public.profiles set premium_until = public.premium_lifetime_until()
 where lower(email) = lower('tathithuytrang.work@gmail.com');
