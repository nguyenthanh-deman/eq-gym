/**
 * EQ GYM 03 — Backend cho trang đăng ký (Google Apps Script Web App)
 * Nhận đăng ký + ảnh bằng chứng CK từ dangky/index.html
 *   → lưu Google Sheet + Google Drive (bằng chứng CK)
 *   → gửi thông báo về nhóm Telegram
 *
 * CÁCH DÙNG (chi tiết ở SETUP-BACKEND.md):
 *   1) script.google.com → New project → dán toàn bộ file này.
 *   2) Điền TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID trong CONFIG.
 *      (DRIVE_FOLDER_ID + SHEET_ID để trống -> script TỰ TẠO folder & sheet lần đầu.)
 *   3) Deploy → New deployment → Web app
 *        - Execute as: Me
 *        - Who has access: Anyone
 *      → copy URL, dán vào biến BACKEND trong dangky/index.html.
 */

var CONFIG = {
  TELEGRAM_BOT_TOKEN: '',   // token từ @BotFather, dạng "123456789:AA...."
  TELEGRAM_CHAT_ID:   '',   // id nhóm Telegram, dạng "-1234567890" (xem hướng dẫn)
  DRIVE_FOLDER_ID:    '',   // (tuỳ chọn) id thư mục Drive lưu ảnh CK — trống = tự tạo
  SHEET_ID:           ''    // (tuỳ chọn) id Google Sheet log đăng ký — trống = tự tạo
};

var FOLDER_NAME = 'EQ GYM 03 - Bang chung CK';
var SHEET_NAME  = 'EQ GYM 03 - Dang ky';

function doPost(e) {
  var out = { ok: false };
  try {
    var d = JSON.parse(e.postData.contents);
    out = (d.type === 'proof') ? handleProof(d) : handleLead(d);
  } catch (err) {
    out = { ok: false, error: String(err) };
  }
  return ContentService.createTextOutput(JSON.stringify(out))
    .setMimeType(ContentService.MimeType.JSON);
}

function doGet() {
  return ContentService.createTextOutput('EQ GYM 03 landing backend — OK');
}

/* ===== Đăng ký mới ===== */
function handleLead(d) {
  logRow(['ĐĂNG KÝ', now(), d.name || '', d.phone || '', d.doituong || '', d.addr || '', '']);
  tgText(
    '🟢 <b>ĐĂNG KÝ MỚI — EQ GYM 03</b>\n' +
    '👤 ' + esc(d.name) + '\n' +
    '📞 ' + esc(d.phone) + '\n' +
    '🎯 ' + esc(d.doituong) + '\n' +
    '📦 ' + esc(d.addr) + '\n' +
    '🕒 ' + now()
  );
  return { ok: true };
}

/* ===== Bằng chứng chuyển khoản ===== */
function handleProof(d) {
  var link = '';
  if (d.image) {
    var parts = String(d.image).split(',');
    var meta = parts[0] || '';
    var b64 = parts.length > 1 ? parts[1] : parts[0];
    var mime = (meta.match(/data:(.*?);/) || [])[1] || 'image/jpeg';
    var ext = mime.indexOf('png') >= 0 ? 'png' : 'jpg';
    var bytes = Utilities.base64Decode(b64);
    var fname = 'CK_' + String(d.phone || 'na').replace(/\D/g, '') + '_' + stamp() + '.' + ext;
    var blob = Utilities.newBlob(bytes, mime, fname);
    var file = getFolder().createFile(blob);
    try { file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW); } catch (e) {}
    link = file.getUrl();
    logRow(['BẰNG CHỨNG CK', now(), d.name || '', d.phone || '', '', '', link]);
    tgPhoto(blob,
      '💸 <b>BẰNG CHỨNG CHUYỂN KHOẢN</b>\n' +
      '👤 ' + esc(d.name) + '\n' +
      '📞 ' + esc(d.phone) + '\n' +
      '📝 ' + esc(d.ck) + '\n' +
      '🔗 ' + link
    );
  } else {
    tgText('💸 Khách báo đã CK (không kèm ảnh)\n👤 ' + esc(d.name) + '\n📞 ' + esc(d.phone));
  }
  return { ok: true, link: link };
}

/* ===== Google Drive folder (tự tạo nếu chưa có) ===== */
function getFolder() {
  var props = PropertiesService.getScriptProperties();
  var id = CONFIG.DRIVE_FOLDER_ID || props.getProperty('FOLDER_ID');
  if (id) { try { return DriveApp.getFolderById(id); } catch (e) {} }
  var it = DriveApp.getFoldersByName(FOLDER_NAME);
  var folder = it.hasNext() ? it.next() : DriveApp.createFolder(FOLDER_NAME);
  props.setProperty('FOLDER_ID', folder.getId());
  return folder;
}

/* ===== Google Sheet (tự tạo nếu chưa có) ===== */
function getSheet() {
  var props = PropertiesService.getScriptProperties();
  var id = CONFIG.SHEET_ID || props.getProperty('SHEET_ID');
  if (id) { try { return SpreadsheetApp.openById(id).getSheets()[0]; } catch (e) {} }
  var ss = SpreadsheetApp.create(SHEET_NAME);
  props.setProperty('SHEET_ID', ss.getId());
  return ss.getSheets()[0];
}

function logRow(row) {
  try {
    var sh = getSheet();
    if (sh.getLastRow() === 0) {
      sh.appendRow(['Loại', 'Thời gian', 'Họ tên', 'SĐT', 'Đối tượng', 'Địa chỉ', 'Link bằng chứng']);
    }
    var r = row.slice();
    if (r[3]) r[3] = "'" + String(r[3]); // ép SĐT thành text để giữ số 0 đầu
    sh.appendRow(r);
  } catch (e) {}
}

/* ===== Telegram ===== */
function tgText(text) {
  if (!CONFIG.TELEGRAM_BOT_TOKEN || !CONFIG.TELEGRAM_CHAT_ID) return;
  try {
    UrlFetchApp.fetch('https://api.telegram.org/bot' + CONFIG.TELEGRAM_BOT_TOKEN + '/sendMessage', {
      method: 'post',
      payload: { chat_id: CONFIG.TELEGRAM_CHAT_ID, text: text, parse_mode: 'HTML', disable_web_page_preview: 'true' },
      muteHttpExceptions: true
    });
  } catch (e) {}
}

function tgPhoto(blob, caption) {
  if (!CONFIG.TELEGRAM_BOT_TOKEN || !CONFIG.TELEGRAM_CHAT_ID) return;
  try {
    UrlFetchApp.fetch('https://api.telegram.org/bot' + CONFIG.TELEGRAM_BOT_TOKEN + '/sendPhoto', {
      method: 'post',
      payload: { chat_id: CONFIG.TELEGRAM_CHAT_ID, caption: caption, parse_mode: 'HTML', photo: blob },
      muteHttpExceptions: true
    });
  } catch (e) { tgText(caption); }
}

/* ===== (Tuỳ chọn) chạy tay 1 lần để tạo sẵn folder+sheet và cấp quyền ===== */
function setup() {
  var f = getFolder();
  var sh = getSheet();
  Logger.log('Folder: ' + f.getUrl());
  Logger.log('Sheet : ' + sh.getParent().getUrl());
  tgText('🔧 EQ GYM backend đã sẵn sàng. Folder & Sheet đã tạo.');
}

/* ===== Helpers ===== */
function now()   { return Utilities.formatDate(new Date(), 'GMT+7', 'dd/MM/yyyy HH:mm'); }
function stamp() { return Utilities.formatDate(new Date(), 'GMT+7', 'yyyyMMdd_HHmmss'); }
function esc(s)  { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
