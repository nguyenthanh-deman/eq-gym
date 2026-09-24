-- Tạm tắt affiliate trên site (24/09/2026). Bật lại: tab Affiliate trong trang Quản trị → tick "Đang bật".
-- Khi tắt, mở link ?ref= cũng không gắn người giới thiệu (trước chỉ chặn ở ô nhập mã).
create or replace function public.claim_referral(p_code text)
returns table(ok boolean, message text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if auth.uid() is null then return query select false, 'Cần đăng nhập'; return; end if;
  if not public.setting_bool('affiliate_enabled', true) then
    return query select false, 'Chương trình giới thiệu đang tạm tắt'; return;
  end if;
  return query select c.ok, c.message from public._claim_referral_for(auth.uid(), p_code) c;
end $$;

update public.settings set value = 'false', updated_at = now() where key = 'affiliate_enabled';
