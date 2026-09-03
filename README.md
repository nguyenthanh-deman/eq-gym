# 🏴‍☠️ EQ GYM — Hải Trình Cảm Xúc

App học tập 30 ngày luyện EQ theo phong cách hải trình One Piece: chinh phục đảo, tăng tiền truy nã Berry, thăng cấp từ Tân Binh đến Vua Hải Tặc EQ. Có video bài học, thực hành mỗi ngày và AI (Gemini) chấm điểm.

## 🚀 Deploy lên GitHub Pages (5 phút, không cần code)

1. Vào **github.com** → đăng nhập → bấm **New repository**
   - Repository name: `eq-gym` (tên gì cũng được)
   - Chọn **Public** → **Create repository**
2. Trong repo mới, bấm **uploading an existing file** (hoặc **Add file → Upload files**)
   - Kéo thả file **`index.html`** (và thư mục `videos/` nếu dùng MP4) vào
   - Bấm **Commit changes**
3. Vào **Settings → Pages** (menu bên trái)
   - Source: **Deploy from a branch**
   - Branch: **main** / thư mục **/ (root)** → **Save**
4. Đợi ~1 phút → app chạy tại: `https://<tên-github-của-bạn>.github.io/eq-gym/`

Mở link đó trên điện thoại → **Chia sẻ → Thêm vào màn hình chính** là dùng như app thật.

## 🎬 Gắn video cho từng bài

Mở `index.html`, tìm dòng `const VIDEO_MAP` (ngay đầu phần script). Mỗi bài 1 dòng:

```js
0:{yt:"https://youtu.be/xxxx", mp4:""},   // dán link YouTube
2:{yt:"", mp4:"videos/bai2.mp4"},          // hoặc file MP4 tự host
```

- **YouTube**: dán link dạng nào cũng được (youtu.be, watch?v=, shorts...)
- **MP4**: upload file vào thư mục `videos/` trong repo rồi ghi đường dẫn
  (lưu ý GitHub giới hạn file 100MB — video dài nên dùng YouTube)
- Để trống → app hiện placeholder "Video đang cập nhật"

## 🤖 Bật AI chấm điểm (Gemini — miễn phí)

1. Vào **aistudio.google.com/apikey** → **Create API key** (tài khoản Google thường là được)
2. Trong app, bấm nút **⚙️** → dán key → **Lưu**
3. Làm bài thực hành → bấm **"⚔️ Nộp bài cho Thuyền Trưởng AI"** → nhận điểm + nhận xét + Berry

Không có key vẫn dùng được — app tự chấm offline (thuật toán độ sâu cảm xúc).
Key chỉ lưu trong trình duyệt của người học, không gửi đi đâu ngoài Google.

## 💰 Hệ thống game

| Hành động | Thưởng |
|---|---|
| Chinh phục 1 đảo (hoàn thành bài) | +10.000.000 Berry |
| Nộp bài thực hành lần đầu | +5.000.000 Berry |
| Điểm AI | +100.000 Berry × điểm |
| Hoàn thành module | Huy hiệu 🧭 ⚔️ 👑 |
| Đủ 30 đảo | Danh hiệu **Vua Hải Tặc EQ** ☠️ |

Cấp bậc: Tân Binh Boong Tàu → Thuyền Viên → Hoa Tiêu → Thuyền Phó → Thuyền Trưởng → Tứ Hoàng Cảm Xúc → Vua Hải Tặc EQ

Tiến độ + nhật ký lưu tự động trên máy người học (localStorage), không cần server.

## 📘 Workbook trong app

Mỗi bài có bước **📘 Workbook** (sau phần Bài đọc, trước Phòng tập): học viên đọc trực tiếp từng trang trong app
hoặc bấm **⬇ Tải / In workbook PDF** để in ra viết tay.

- Ảnh trang: `workbook/wN/pNN.jpg` · PDF: `workbook/bai-N.pdf` · số trang khai báo ở `const WORKBOOK` trong `index.html`.
- Nguồn là 30 file Word trong `EQGYM/word-new/`. Script tạo lại toàn bộ (cần Word + Python `pywin32`, `pymupdf`):
  `python tools/wb_build.py` (đường dẫn nguồn `SRC` khai báo đầu script) — script tự **lọc ghi chú sản xuất nội bộ**
  như "(slide chữ)", "(AI chia ảnh...)", "(Lúc tạo video...)", "(chèn/ghép ảnh ... khi edit)" trước khi xuất.
- Muốn cập nhật 1 bài: sửa file Word → chạy lại script với số bài → cập nhật số trang trong `WORKBOOK` nếu đổi.

## 🎓 Giấy chứng nhận hoàn thành

Khi học viên hoàn thành **Bài 29** (đủ 30/30 buổi), app tự tạo **Giấy chứng nhận** (ảnh PNG vẽ bằng canvas,
1600×1131) với: họ tên, mã chứng nhận `EQG-<năm>-<mã>-<hash>`, ngày hoàn thành, điểm EP, điểm TB Coach AI,
số bài thực hành, danh hiệu *Bậc Thầy EQ*, chữ ký chuyên gia (`CERT_SIGNER` trong `index.html`).

- Hiện ngay sau rương thưởng cuối cùng; xem lại ở thẻ vàng trên trang chủ, huy hiệu *Bậc Thầy EQ*, hoặc mục Tài khoản.
- Học viên sửa được **tên in trên chứng nhận**, tải PNG hoặc chia sẻ (Web Share API).
- Chứng nhận lưu trong tiến độ (`S.cert`) → đồng bộ theo tài khoản; backend ghi nhật ký sự kiện `certificate`
  (kèm mã) để admin đối chiếu ở tab 📜 Nhật ký.
