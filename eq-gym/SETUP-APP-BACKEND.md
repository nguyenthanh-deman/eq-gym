# Backend HỢP NHẤT — mã đăng nhập · Gemini ẩn · điểm/thi đua · tự cấp mã · quản trị

Một Apps Script duy nhất (`app-backend.gs`) lo TẤT CẢ. Cả **app** lẫn **landing** trỏ về CÙNG 1 URL.

Tính năng:
- **Landing:** khách upload bằng chứng CK → hệ thống **tự tạo mã học viên**, hiện ngay cho khách (copy + mở app) + báo Telegram + lưu ảnh Drive.
- **App:** đăng nhập bằng mã · Coach AI (Gemini) **key ẩn dùng chung** · điểm từ 0 · Đảo Thi Đua.
- **Admin:** quản trị toàn bộ tài khoản (khoá/mở/xoá/cấp mã tay) + **nhật ký hoạt động** toàn hệ thống.

---

## Cấu hình (1 lần)

1. **Gemini key:** aistudio.google.com/apikey → Create → copy (`AIza...`).
2. Mở Apps Script **project app backend hiện có** (cái đang chạy URL `...AKfycbyrKnB6...`).
3. **Xoá hết code cũ, dán TOÀN BỘ `app-backend.gs` mới.**
4. Điền `CONFIG` — **nhớ điền lại đủ, đừng để trống** (dán code mới sẽ xoá config cũ):
   ```js
   var CONFIG = {
     GEMINI_API_KEY:     'AIza...(key Gemini)',
     ADMIN_SECRET:       'MA_ADMIN_CUA_BAN',        // mã đăng nhập admin (nên CHỮ IN HOA + số)
     TELEGRAM_BOT_TOKEN: '8745383878:AAF...HelJ4',  // token bot (đã có từ landing)
     TELEGRAM_CHAT_ID:   '-5253595814',             // nhóm Telegram (đã có)
     DRIVE_FOLDER_ID:    '',                         // trống = tự tạo thư mục lưu ảnh CK
     SHEET_ID:           '',                         // trống = tự tạo "EQ GYM - He thong"
     GEMINI_MODEL:       'gemini-2.0-flash'
   };
   ```
5. **Ctrl+S** → **Deploy → Manage deployments → ✏️ Edit → Version: New version → Deploy**.
   → **URL giữ nguyên** (`...AKfycbyrKnB6...`), app + landing không cần đổi gì nữa.

> Nếu lỡ tạo "New deployment" (URL mới), gửi URL cho Claude để cập nhật lại 2 frontend.

---

## Vận hành

**Khách hàng (tự động):** landing → điền form → CK → **upload ảnh biên lai** → nhận **mã học viên ngay trên trang** → copy → mở app → dán mã → học. (Admin cũng nhận mã qua Telegram.)

**Admin:**
- Đăng nhập app bằng `ADMIN_SECRET` → **Tài khoản → 🛡️ Quản trị**.
- Tab **👥 Tài khoản:** xem tất cả học viên + điểm; **Khoá / Mở khoá / Xoá**; **Cấp mã tay** (khách trả tiền mặt).
- Tab **📜 Nhật ký:** lịch sử toàn hệ thống (đăng nhập, đăng ký, cấp mã, khoá/mở/xoá, hoàn thành buổi).

## Dữ liệu
- Sheet **"EQ GYM - He thong"** (tự tạo trong Drive): tab **Members** (Mã/Tên/SĐT/Điểm/Vai trò/Trạng thái/…) + tab **Activity** (nhật ký).
- Ảnh CK: thư mục Drive **"EQ GYM - Bang chung CK"**.

## Ghi chú
- Mã tự cấp theo **SĐT** — khách upload nhiều lần vẫn 1 mã (không trùng).
- Gemini key không bao giờ lộ (mọi call qua server). Chỉ mã hợp lệ + chưa bị khoá mới gọi được AI.
- Tài khoản bị **Khoá** sẽ không đăng nhập được (báo "đã bị tạm khoá").
- Hạn mức Apps Script ~20.000 lệnh/ngày — đủ vài chục–vài trăm học viên. Cần hơn → Supabase.
