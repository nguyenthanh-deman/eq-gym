# Cấu hình backend đăng ký EQ GYM 03 (Drive + Telegram)

Trang `dangky/` là trang tĩnh trên GitHub Pages nên không tự chạy server được.
Ta dùng **Google Apps Script** làm backend miễn phí: nhận đăng ký + ảnh biên lai
→ lưu **Google Sheet + Google Drive** → bắn thông báo về **nhóm Telegram**.

Token bot nằm trong Apps Script (server-side) nên **không lộ ra trang web**.

Làm 1 lần, khoảng 15 phút. Làm theo đúng thứ tự dưới.

---

## 1) Tạo bot Telegram + lấy chat id của nhóm

1. Mở Telegram, chat với **@BotFather** → gõ `/newbot` → đặt tên → nhận **BOT TOKEN**
   (dạng `123456789:AAH....`). Lưu lại.
2. Tạo **nhóm Telegram** để nhận thông báo (VD "EQ GYM Đăng ký"), **thêm bot vừa tạo vào nhóm**.
3. Lấy **chat id của nhóm**:
   - Thêm **@RawDataBot** (hoặc @getidsbot) vào nhóm → nó in ra `chat id` (dạng số **âm**,
     VD `-1001234567890`) → copy → rồi có thể xoá bot đó khỏi nhóm.
   - (Cách khác: gửi 1 tin trong nhóm rồi mở
     `https://api.telegram.org/bot<BOT_TOKEN>/getUpdates` trên trình duyệt, tìm `"chat":{"id":-100...}`.)

## 2) Nơi lưu trên Google Drive — KHÔNG cần tạo tay

Script **tự tạo** thư mục `EQ GYM 03 - Bang chung CK` và sheet `EQ GYM 03 - Dang ky`
trong Drive của bạn ở lần chạy đầu. (Nếu muốn tự chỉ định, điền `DRIVE_FOLDER_ID`/`SHEET_ID`.)

## 3) Tạo Apps Script

1. Vào **https://script.google.com** → **New project**.
2. Xoá code mẫu, dán **toàn bộ** nội dung file `dangky/apps-script.gs`.
3. Chỉ cần điền **2 giá trị** vào khối `CONFIG` ở đầu:
   ```js
   var CONFIG = {
     TELEGRAM_BOT_TOKEN: '123456789:AAH....',
     TELEGRAM_CHAT_ID:   '-1234567890',
     DRIVE_FOLDER_ID:    '',   // để trống -> tự tạo
     SHEET_ID:           ''    // để trống -> tự tạo
   };
   ```
4. **Save** (Ctrl+S). (Tuỳ chọn: chạy hàm `setup` một lần để tạo sẵn folder/sheet + cấp quyền.)

## 4) Deploy thành Web App

1. Bấm **Deploy → New deployment**.
2. Bánh răng ⚙ → chọn **Web app**.
3. Cấu hình:
   - **Execute as:** `Me` (tài khoản của bạn)
   - **Who has access:** `Anyone`
4. **Deploy** → lần đầu sẽ hỏi cấp quyền → **Authorize** (chọn tài khoản → Advanced →
   "Go to project (unsafe)" → Allow — đây là script của chính bạn nên an toàn).
5. Copy **Web app URL** (dạng `https://script.google.com/macros/s/AKfyc..../exec`).

## 5) Gắn URL vào trang

1. Mở `dangky/index.html`, tìm dòng:
   ```js
   var BACKEND="";
   ```
2. Dán URL vào giữa hai dấu nháy:
   ```js
   var BACKEND="https://script.google.com/macros/s/AKfyc..../exec";
   ```
3. Commit + push. Xong — phần **upload ảnh biên lai** sẽ tự hiện, và mỗi đăng ký/biên lai
   sẽ tự đẩy về Sheet + Drive + báo Telegram.

> Gửi mình URL đó, mình dán vào và deploy lại cho bạn cũng được.

---

## Kiểm tra nhanh

- Mở Web app URL bằng trình duyệt → thấy chữ `EQ GYM 03 landing backend — OK` là chạy.
- Đăng ký thử trên trang `dangky/` → nhóm Telegram nhận tin "ĐĂNG KÝ MỚI", Sheet có thêm 1 dòng.
- Bấm chọn 1 ảnh + "Gửi xác nhận CK" → Telegram nhận ảnh, Drive có file `CK_<sđt>_<thời gian>.jpg`.

## Ghi chú
- Ảnh biên lai được nén ~1280px trước khi gửi để nhẹ và nhanh.
- Đăng ký vẫn đồng thời gửi về Google Form/Sheet cũ (không mất dữ liệu quy trình hiện tại).
- Muốn đổi cấu hình sau này: sửa `CONFIG` → **Deploy → Manage deployments → Edit → Version: New version → Deploy**
  (giữ nguyên URL).
