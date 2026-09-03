# -*- coding: utf-8 -*-
"""EQ GYM — dựng asset Workbook cho app: Word (.docx) -> lọc ghi chú sản xuất nội bộ -> PDF -> ảnh từng trang.

Kết quả:  ../workbook/wN/pNN.jpg  +  ../workbook/bai-N.pdf   (N = 0..29)
Cuối cùng in ra  WORKBOOK={...}  (số trang mỗi bài) để dán vào  `const WORKBOOK`  trong index.html.

Cách chạy (Windows, cần Microsoft Word + Python: pywin32, pymupdf):
    python tools/wb_build.py            # tất cả 30 bài
    python tools/wb_build.py 11 24      # chỉ vài bài

Lưu ý đã đúc kết:
- Word treo vô hạn nếu mở file nằm trong Downloads (Protected View) -> script luôn copy docx sang thư mục tạm trước.
- Không dùng wildcard Find của Word để xoá ghi chú (chạy lan qua đoạn khác khi thiếu dấu ")"); dùng regex Python theo từng đoạn,
  kiểm tra Range.Text trùng khớp rồi mới Delete(); có 2 fallback cho đoạn chứa ký tự đặc biệt (mũi tên, symbol).
"""
import os, sys, io, re, shutil, glob, json, time, tempfile, unicodedata
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import win32com.client, fitz

SRC = r"C:\Users\user\Downloads\Huân\EQGYM\word-new"          # thư mục chứa EQ_GYM_Bai_N_Workbook*.docx
TMP = os.path.join(tempfile.gettempdir(), "eqgym_wb_tmp")     # bản copy tạm (tránh Protected View)
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "workbook")
ONLY = [int(x) for x in sys.argv[1:]] if len(sys.argv) > 1 else None
ZOOM = 2.4           # 595pt * 2.4 ~= 1430px bề ngang ảnh trang (đủ nét trên màn hình 3x + zoom)
JPG_Q = 82

os.makedirs(TMP, exist_ok=True); os.makedirs(OUT, exist_ok=True)

files = {}
for f in glob.glob(os.path.join(SRC, "EQ_GYM_Bai_*_Workbook*.docx")):
    m = re.search(r"Bai_(\d+)_Workbook", os.path.basename(f))
    if m: files[int(m.group(1))] = f
todo = sorted(n for n in files if (ONLY is None or n in ONLY))
print("lessons:", todo)

# cả đoạn là ghi chú sản xuất -> xoá nguyên đoạn
NOTE_FULL = re.compile(r"^\s*\.?\s*\((AI|Ai|Lúc tạo video|chèn|Chèn|ghép|Ghép|chuyển bảng)|^[^()]*khi edit\)\s*$", re.U)
# ghi chú nằm trong đoạn nội dung -> chỉ xoá phần đó (giới hạn trong đoạn; chấp nhận thiếu dấu ")")
INLINE = re.compile(r"\s*\((?:slide ch|AI\b|Ai |Lúc tạo video|[Cc]hèn |[Gg]hép |chuyển bảng|[^()\r]*?(?:khi edit|9:16|voice|anh-bai|\bedit\b))[^)\r]*?(?:\)|(?=\r|$))", re.U)
norm = lambda s: re.sub(r"[-→\s]", "", unicodedata.normalize("NFC", s or ""))
FIXUPS = [(": . ", ": "), (": .", ":"), (". .", "."), ("? .", "?"), ("?  .", "?"), (":.", ":")]
RESID = re.compile(r"\((slide|AI |Ai |Lúc tạo video|anh-bai|chèn|Chèn|ghép|Ghép)|khi edit|9:16|anh-bai", re.U)

word = win32com.client.DispatchEx("Word.Application")
word.Visible = False; word.DisplayAlerts = 0
try: word.AutomationSecurity = 3
except Exception: pass

counts = {}; report = {}
t0 = time.time()
try:
    for n in todo:
        src = files[n]
        tmp_docx = os.path.join(TMP, f"bai{n}.docx"); pdf = os.path.join(TMP, f"bai{n}.pdf")
        shutil.copyfile(src, tmp_docx)
        if os.path.exists(pdf): os.remove(pdf)
        doc = word.Documents.Open(tmp_docx, ConfirmConversions=False, ReadOnly=False, AddToRecentFiles=False, Visible=False, NoEncodingDialog=True)
        before = doc.Paragraphs.Count
        # 1) xoá các đoạn là ghi chú (duyệt ngược)
        deleted = 0
        for i in range(doc.Paragraphs.Count, 0, -1):
            p = doc.Paragraphs.Item(i); t = p.Range.Text or ""
            if NOTE_FULL.match(t):
                try: p.Range.Delete(); deleted += 1
                except Exception as e: print("  del fail", n, i, e)
        # 2) ghi chú inline: regex theo đoạn, xoá từ cuối lên, kiểm tra Range.Text trước khi xoá
        inl = 0; warn = []
        for i in range(doc.Paragraphs.Count, 0, -1):
            p = doc.Paragraphs.Item(i); t = p.Range.Text or ""
            if "(" not in t: continue
            spans = [(m.start(), m.end()) for m in INLINE.finditer(t)]
            if not spans: continue
            st = p.Range.Start
            for a, b in reversed(spans):
                r = doc.Range(st + a, st + b)
                if (r.Text or "") == t[a:b]:
                    r.Delete(); inl += 1
                else:
                    ok = False; seg = t[a:b].strip()
                    # fallback 1: map chỉ số chuỗi -> vị trí thật qua Characters
                    try:
                        chars = p.Range.Characters; pos = []; txt = ""
                        for k in range(1, chars.Count + 1):
                            c = chars.Item(k); pos.append((c.Start, c.End)); txt += (c.Text or "")
                        if len(txt) == len(t) and b <= len(pos):
                            r2 = doc.Range(pos[a][0], pos[b-1][1])
                            if norm(r2.Text) == norm(t[a:b]): r2.Delete(); inl += 1; ok = True
                    except Exception:
                        pass
                    # fallback 2: Word Find theo tiền tố ASCII trong đoạn, nới tới ")" hoặc cuối đoạn, kiểm tra rồi xoá
                    if not ok:
                        try:
                            mpre = re.match(r"[ -~]{4,}", seg); pre = mpre.group(0) if mpre else seg[:6]
                            rng = p.Range; fd = rng.Find; fd.ClearFormatting()
                            if fd.Execute(pre, True, False, False, False, False, True, 0, False, "", 0):
                                if seg.endswith(")"): rng.MoveEndUntil(")", 100000); rng.MoveEnd(1, 1)
                                else: rng.End = p.Range.End - 1
                                if norm(rng.Text) == norm(seg): rng.Delete(); inl += 1; ok = True
                                else: warn.append((i, seg[:60], "find-text " + (rng.Text or "")[:60]))
                            else: warn.append((i, seg[:60], "find-miss " + pre))
                        except Exception as e:
                            warn.append((i, seg[:60], "err2 " + str(e)[:50]))
        for w in warn: print("  WARN offset mismatch para", w)
        # 3) dọn dấu câu thừa (thay thế chuỗi chính xác, không wildcard)
        for a, b in FIXUPS:
            f = doc.Content.Find; f.ClearFormatting(); f.Replacement.ClearFormatting()
            f.Execute(a, False, False, False, False, False, True, 1, False, b, 2)
        # 4) kiểm tra tồn dư
        resid = []
        for i in range(1, doc.Paragraphs.Count + 1):
            t = (doc.Paragraphs.Item(i).Range.Text or "").strip()
            if RESID.search(t) or (re.search(r"[:.]\s*\.\s*$", t) and not re.search(r"\.{3,}", t)):
                resid.append(t[:110])
        after = doc.Paragraphs.Count
        # 5) xuất PDF (17 = wdExportFormatPDF, OptimizeFor 0 = chất lượng in, giữ ảnh nét)
        doc.ExportAsFixedFormat(pdf, 17, False, 0, 0, 0, 0, 0, False, False, 0, False, True, False)
        doc.Close(False)
        # 6) render ảnh từng trang
        d = fitz.open(pdf); outdir = os.path.join(OUT, f"w{n}")
        if os.path.isdir(outdir): shutil.rmtree(outdir)
        os.makedirs(outdir)
        for i, page in enumerate(d):
            pix = page.get_pixmap(matrix=fitz.Matrix(ZOOM, ZOOM), alpha=False)
            pix.save(os.path.join(outdir, f"p{i+1:02d}.jpg"), jpg_quality=JPG_Q)
        counts[n] = d.page_count; d.close()
        shutil.copyfile(pdf, os.path.join(OUT, f"bai-{n}.pdf"))
        report[n] = {"paras_before": before, "paras_after": after, "deleted": deleted, "inline": inl, "pages": counts[n], "pdf_kb": os.path.getsize(pdf)//1024, "resid": resid, "warn": warn}
        print(f"Bai {n:2d}: pages={counts[n]:2d} pdf={os.path.getsize(pdf)//1024:5d}KB paras {before}->{after} deleted={deleted} inline={inl} resid={len(resid)} t={time.time()-t0:.0f}s")
        for r in resid: print("     RESID:", r)
finally:
    try: word.Quit()
    except Exception: pass

print("WORKBOOK=" + json.dumps(counts, separators=(',', ':')))
with open(os.path.join(TMP, "report.json"), "w", encoding="utf-8") as fh: json.dump(report, fh, ensure_ascii=False, indent=1)
tot = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(OUT) for f in fs)
print("total workbook dir MB:", round(tot/1e6, 1))
