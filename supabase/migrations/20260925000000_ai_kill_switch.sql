-- Công tắc tắt AI khẩn cấp (kiêm "nút tắt khẩn" trong kế hoạch sự cố dữ liệu).
-- Edge Function `ai` đọc settings.ai_enabled trước mọi thứ; false → trả 503, không gọi Gemini.
-- Tạm tắt từ 25/09/2026 chờ rà soát an toàn thông tin & pháp lý (docs/PRIVACY-COMPLIANCE-CHECKLIST.md).
-- Bật lại: update public.settings set value = 'true', updated_at = now() where key = 'ai_enabled';
--          VÀ đổi AI_ENABLED=true trong eq-gym/index.html.
insert into public.settings (key, value) values ('ai_enabled', 'false')
on conflict (key) do update set value = 'false', updated_at = now();
