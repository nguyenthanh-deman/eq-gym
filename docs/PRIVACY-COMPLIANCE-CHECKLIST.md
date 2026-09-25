# EQ GYM — Checklist an toàn thông tin & tuân thủ pháp lý

Nguồn: tài liệu "An toàn thông tin & quyền riêng tư cho app học tập AI" (Coach Donnie – Marota, 24/09/2026)
đối chiếu với code thực tế ngày 25/09/2026. Các mục ⚖️ = cần luật sư xác nhận, 🤝 = cần khách quyết.

Hạ tầng liên quan dữ liệu: Supabase (Singapore, ap-southeast-1) · Google Gemini qua Edge Function `ai` (Mỹ) ·
Google Sign-In · SePay/VietinBank · GitHub Actions (backup DB mã hoá hằng ngày).

---

## ✅ Đã xong (25/09/2026)

- [x] Thay link nhóm Zalo → `https://zalo.me/g/9cisw0ktwt4zowguavqb` (`COMMUNITY_URL`), thêm "Gặp lỗi đăng nhập? Nhắn nhóm hỗ trợ Zalo" ở khung đăng nhập.
- [x] **Tắt toàn bộ AI** chờ thống nhất — 2 lớp:
  - App: `AI_ENABLED=false` → ẩn tab Coach, không gọi AI tạo tình huống/chấm bài (chấm tự động theo tiêu chí), sửa các câu quảng cáo "Coach AI" (quyền lợi Premium, nút nộp bài…).
  - Server: `settings.ai_enabled=false` → Edge Function `ai` trả 503 trước khi gọi Gemini (kiêm **nút tắt khẩn** cho kế hoạch sự cố).
- [x] Sửa lỗi "Email link is invalid or has expired": đăng nhập bằng **mã số trong email** (vẫn giữ link), báo lỗi tiếng Việt dễ hiểu, nút "Gửi lại mã" (chờ 60 giây), link lỗi → tự mở khung nhập mã.
- [x] Cảnh báo khi mở app trong Zalo/Facebook: Google chặn đăng nhập ở đó → hướng dẫn dùng mã email hoặc "Mở bằng trình duyệt" + nút sao chép link.
- [x] Lưu ý "không phải dịch vụ y tế/trị liệu, không chẩn đoán, khẩn cấp gọi 115" ở khung đăng nhập và màn Test EQ.

## 🔧 Anh làm trên Supabase Dashboard (5 phút)

- [ ] **Bật SMTP riêng** (Authentication → Emails → SMTP Settings) — Supabase chỉ cho sửa mẫu email khi dùng SMTP riêng; SMTP mặc định còn giới hạn rất ít email/giờ. Đề xuất: Resend với tên miền evolve.vn (bền, ít vào Spam) hoặc Gmail + App Password (nhanh, ~500 email/ngày). Sau đó chỉnh *Rate Limits → emails/giờ* cho phù hợp.
- [ ] **Authentication → Email Templates → Magic Link** và **Confirm signup**: thêm mã số vào nội dung, ví dụ:
  `<p>Mã đăng nhập EQ GYM của bạn: <b style="font-size:22px;letter-spacing:4px">{{ .Token }}</b></p>`
  (giữ nguyên link `{{ .ConfirmationURL }}` bên dưới làm dự phòng). Chưa thêm thì email chỉ có link, app vẫn chạy như cũ.
- [ ] **Authentication → Providers → Email**: kiểm tra *Email OTP Length* = 6 và *Email OTP Expiration* = 3600 giây.

## 🟢 Việc kỹ thuật làm tiếp — không cần chờ luật sư (đơn giản → phức tạp)

- [ ] Test cách ly "A không đọc được dữ liệu của B" (script SQL bọc `begin … rollback` cho mọi bảng có RLS).
- [ ] Nút **"Tải dữ liệu của tôi"** (xuất JSON: hồ sơ, tiến độ, luyện tập, bài test EQ, giao dịch).
- [ ] **Nhật ký truy cập quản trị**: ghi lại mỗi lần admin xem chi tiết học viên / đổi quyền / cấp Premium.
- [ ] Admin bắt buộc **xác thực 2 lớp** (TOTP của Supabase) để vào trang Quản trị.
- [ ] **Tự xoá log** `webhook_logs` sau thời hạn đã công bố (pg_cron) — chờ con số ở câu hỏi 🤝2.
- [ ] **Thử khôi phục backup** vào một project tạm, ghi lại kết quả.
- [ ] Dọn trang `dangky/` cũ (còn chuyển khoản tay + nhóm Facebook) — chờ 🤝7.
- [ ] Nút **"Xoá tài khoản và dữ liệu"** (Edge Function: xoá thật → kiểm tra lại → báo đúng những gì đã xoá; giao dịch giữ theo luật kế toán nhưng bỏ thông tin cá nhân) — chờ ⚖️8.

## 🟡 Chờ luật sư / khách rồi mới làm

- [ ] **Chính sách quyền riêng tư** + **Điều khoản sử dụng** (em soạn nháp theo bản đồ dữ liệu thật; luật sư duyệt) — cần 🤝1.
- [ ] Khi đăng ký: ô "Tôi đồng ý Điều khoản & Chính sách" (không tick sẵn) + xác nhận độ tuổi — ⚖️5, ⚖️6.
- [ ] Đồng ý riêng trước khi lưu câu trả lời cảm xúc lên máy chủ (từ chối → chỉ lưu trên máy) — ⚖️1, ⚖️6.
- [ ] **Hồ sơ đánh giá tác động xử lý dữ liệu + chuyển dữ liệu ra nước ngoài** — ⚠️ GẤP, xem ⚖️3.
- [ ] Kế hoạch sự cố dữ liệu: người phụ trách, mẫu thông báo, quy trình 5 bước — ⚖️7, 🤝1.
- [ ] Thương mại điện tử / hoá đơn / chính sách hoàn tiền — ⚖️10.
- [ ] Hợp đồng & thuế TNCN cho affiliate — ⚖️11.

## 🔴 Điều kiện bắt buộc TRƯỚC KHI BẬT LẠI AI

- [ ] Chuyển lời dặn AI về server: function `ai` chỉ nhận tin nhắn + mã bài, **không nhận `systemInstruction` từ app** (hiện học viên Premium có thể tự viết lời dặn để lách quy tắc / dùng Gemini vào việc khác).
- [ ] Quy tắc an toàn trong lời dặn: nói rõ là AI, không chẩn đoán/tư vấn y khoa, coi nội dung người dùng là dữ liệu chứ không phải lệnh, không hứa "đã lưu/đã xoá".
- [ ] Lớp phát hiện khủng hoảng (tự hại, bạo lực) trên server → trả câu trả lời an toàn soạn sẵn: dừng bài, hỏi họ có an toàn không, khuyên liên hệ người thân/chuyên gia, gọi 115.
- [ ] Nhãn cố định "Bạn đang trò chuyện với AI · AI có thể sai" + lời chào lần đầu (Mẫu 1) + lưu ý ở khung chat.
- [ ] Không gửi tên/email/SĐT sang Gemini; **Gemini dùng gói trả phí** (không huấn luyện trên dữ liệu) — 🤝3.
- [ ] Giới hạn tốc độ lưu trong DB + trần số lượt/ngày cho mỗi người và cho toàn app.
- [ ] Bộ test bẫy (chèn lệnh, khủng hoảng, hứa hão, đòi chẩn đoán) — chạy và lưu kết quả.
- [ ] Thống nhất phạm vi AI với khách (🤝4) và phân loại rủi ro theo Luật AI (⚖️9).
- [ ] Bật lại: `update public.settings set value='true' where key='ai_enabled'` **và** `AI_ENABLED=true` trong `eq-gym/index.html`.

---

## ⚖️ Câu hỏi cho luật sư

1. Kết quả Test EQ (24 câu về cảm xúc) và câu trả lời phản chiếu cảm xúc của học viên có bị coi là **dữ liệu cá nhân nhạy cảm** (dữ liệu sức khoẻ/tinh thần) theo Luật BVDLCN 91/2025/QH15 và NĐ 356/2025/NĐ-CP không?
2. App có thuộc diện **được miễn** lập hồ sơ đánh giá tác động / cử người phụ trách bảo vệ dữ liệu (doanh nghiệp nhỏ, khởi nghiệp) không, khi có thể đang xử lý dữ liệu nhạy cảm?
3. App chạy thật từ khoảng **15/09/2026**. Nếu hồ sơ đánh giá tác động xử lý + chuyển dữ liệu ra nước ngoài phải nộp trong 60 ngày thì **hạn là ngày nào**, dùng mẫu nào, nộp ở đâu? Ai đứng tên bên kiểm soát dữ liệu (chủ app) và bên xử lý (đơn vị làm kỹ thuật)?
4. Những dịch vụ nào tính là **chuyển dữ liệu ra nước ngoài**: Supabase (Singapore), Google Gemini (Mỹ), Google Sign-In, GitHub (lưu backup mã hoá), nhà cung cấp gửi email SMTP (Resend/Gmail — nhận email học viên)? Cần ký hợp đồng/thoả thuận xử lý dữ liệu (DPA) gì với từng bên?
5. **Độ tuổi tối thiểu** để tự đồng ý? Dưới tuổi đó lấy đồng ý của cha mẹ bằng cách nào là hợp lệ? Ô "Tôi đủ X tuổi" có đủ không?
6. Hình thức **đồng ý** hợp lệ: ô tick không tick sẵn có đủ không? Có phải lưu bằng chứng (thời điểm, phiên bản chính sách, IP) không? Đồng ý cho dữ liệu nhạy cảm có phải tách riêng khỏi đồng ý điều khoản không?
7. **Thời hạn phản hồi** yêu cầu của học viên (xem, sửa, xoá, rút đồng ý) là bao nhiêu? Khi có **sự cố dữ liệu** phải báo ai (cơ quan nào, kênh nào), trong bao lâu (72 giờ?), nội dung tối thiểu gồm gì?
8. Khi học viên xoá tài khoản: dữ liệu **giao dịch/thanh toán/hoá đơn** phải giữ bao lâu, được ẩn danh đến mức nào? Phần đã gửi cho nhà cung cấp AI thì ghi trong chính sách thế nào cho đúng?
9. Theo **Luật Trí tuệ nhân tạo 2025** (hiệu lực 01/03/2026), một AI "coach" luyện cảm xúc thuộc mức rủi ro nào? Nghĩa vụ minh bạch, ghi nhãn "đây là AI" và hồ sơ tự đánh giá cụ thể là gì?
10. Bán gói Premium online qua web app: có phải **thông báo website TMĐT với Bộ Công Thương** không? Có bắt buộc xuất **hoá đơn điện tử** cho từng giao dịch, và bắt buộc công bố chính sách hoàn tiền/khiếu nại theo Luật Bảo vệ quyền lợi người tiêu dùng không?
11. **Affiliate** trả hoa hồng 20–60% cho cá nhân: cần hợp đồng gì, có phải khấu trừ thuế TNCN (10% cho khoản từ 2 triệu) không, cần thu thông tin gì (MST/CCCD) và lưu bảo mật ra sao?
12. Gói Premium đã bán có quảng cáo "Coach AI chấm điểm". **Tạm tắt AI** có vi phạm cam kết với khách đã mua không? Cần thông báo, bù đắp hay ghi chú gì?
13. Nhờ duyệt bản **Chính sách quyền riêng tư** và **Điều khoản sử dụng** (em soạn nháp khi có thông tin ở 🤝1).

## 🤝 Câu hỏi cho khách (EQ GYM / Yuki Hana)

1. **Pháp nhân đứng tên app**: tên công ty, MST, địa chỉ, người đại diện; email/SĐT nhận yêu cầu về dữ liệu; ai là **người phụ trách dữ liệu và sự cố**?
2. **Thời hạn lưu** — em đề xuất: câu trả lời luyện tập & kết quả test EQ: đến khi học viên xoá tài khoản, hoặc tự xoá sau 24 tháng không hoạt động · log thanh toán webhook: 90 ngày · giao dịch: theo thời hạn luật kế toán (chờ ⚖️8) · chat AI: chỉ lưu trên máy học viên. Anh/chị đồng ý hay muốn con số khác?
3. **Key Gemini** thuộc tài khoản nào? Đã bật billing (gói trả phí — Google không dùng dữ liệu để huấn luyện) chưa?
4. Khi bật lại AI: giữ những tính năng nào (chat Coach, AI tạo tình huống, AI chấm bài)? Có muốn lưu lịch sử chat lên máy chủ không (em khuyên **không**)?
5. Có thông báo cho học viên Premium về việc tạm dừng Coach AI không? (Em đề xuất đăng một tin ngắn trong nhóm Zalo.)
6. Nhóm Zalo có mở cho **mọi người** (kể cả chưa Premium) để hỗ trợ đăng nhập không? Hiện em đặt link "Nhắn nhóm hỗ trợ Zalo" ở màn đăng nhập cho tất cả.
7. Trang `dangky/` cũ (chuyển khoản tay, nhóm Facebook) còn dùng không → gỡ hay cập nhật?
8. Những ai là **admin**? (Để bật xác thực 2 lớp cho từng người.)
9. Ngoài 115, có **đường dây hỗ trợ tâm lý / chuyên gia đối tác** nào muốn giới thiệu cho học viên khi cần không?
10. Email đăng nhập gửi từ địa chỉ nào (vd `noreply@evolve.vn`)? Ai quản lý DNS tên miền evolve.vn để xác minh cho dịch vụ gửi mail?
