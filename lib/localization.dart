import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum AppLanguage {
  chinese('zh', '简体中文'),
  english('en', 'English'),
  japanese('ja', '日本語');

  const AppLanguage(this.code, this.label);
  final String code;
  final String label;
  static const LocalizationsDelegate<AppLanguage> delegate =
      _AppLanguageDelegate();

  Locale get locale => Locale(code);

  static AppLanguage fromCode(String? code) =>
      values.where((value) => value.code == code).firstOrNull ?? chinese;

  static AppLanguage of(BuildContext context) =>
      Localizations.of<AppLanguage>(context, AppLanguage) ?? chinese;

  String translate(String text, [List<Object?> values = const []]) =>
      AppMessage(text, values).resolve(this);
}

class _AppLanguageDelegate extends LocalizationsDelegate<AppLanguage> {
  const _AppLanguageDelegate();

  @override
  bool isSupported(Locale locale) => AppLanguage.values.any(
    (language) => language.code == locale.languageCode,
  );

  @override
  Future<AppLanguage> load(Locale locale) =>
      SynchronousFuture(AppLanguage.fromCode(locale.languageCode));

  @override
  bool shouldReload(_AppLanguageDelegate old) => false;
}

extension LocalizedContext on BuildContext {
  String tr(String text, [List<Object?> values = const []]) =>
      AppLanguage.of(this).translate(text, values);
}

class AppMessage implements Exception {
  const AppMessage(this.text, [this.values = const []]);

  final String text;
  final List<Object?> values;
  static final _placeholder = RegExp(r'\{(\d+)\}');

  String resolve(AppLanguage language) {
    final translation = _translations[text];
    final template = switch (language) {
      AppLanguage.english => translation?.$1 ?? text,
      AppLanguage.japanese => translation?.$2 ?? text,
      AppLanguage.chinese => text,
    };
    if (values.isEmpty) return template;
    return template.replaceAllMapped(_placeholder, (match) {
      final index = int.parse(match[1]!);
      return index < values.length
          ? _resolveValue(values[index], language)
          : match[0]!;
    });
  }

  static String _resolveValue(Object? value, AppLanguage language) {
    if (value is AppMessage) return value.resolve(language);
    if (language == AppLanguage.chinese) return '$value';
    final detail = switch (value) {
      PlatformException(:final message) => message,
      StateError(:final message) => message,
      UnsupportedError(:final message) => message,
      FormatException(:final message) => message,
      _ => null,
    };
    if (detail is String && _translations.containsKey(detail)) {
      return language.translate(detail);
    }
    return '$value';
  }

  @override
  String toString() => resolve(AppLanguage.chinese);
}

// Simplified Chinese is the source text for labels and message templates.
const _translations = <String, (String, String)>{
  '智能高拍仪': ('Smart Scanner', 'スマートスキャナー'),
  '演示模式 · 当前显示测试图案，拍摄内容为演示图片': (
    'Demo mode · The preview and captured images use a test pattern',
    'デモモード · プレビューと撮影画像にはテストパターンを使用します',
  ),
  '图片': ('Images', '画像'),
  '导入图片': ('Import images', '画像を読み込む'),
  '连接中': ('Connecting', '接続中'),
  '刷新设备': ('Refresh devices', '機器を再検出'),
  '切换设备来源': ('Switch device source', '機器の接続先を切り替え'),
  '真实扫描仪': ('Physical scanner', '実機スキャナー'),
  '演示模式': ('Demo mode', 'デモモード'),
  '输出设置': ('Output settings', '出力設定'),
  '界面语言': ('App language', '表示言語'),
  '设备接入': ('Device source', '機器の接続方式'),
  '系统摄像头（内置 / USB）': ('System camera (built-in / USB)', 'システムカメラ（内蔵 / USB）'),
  '厂商扫描仪服务': ('Vendor scanner service', 'メーカーのスキャナーサービス'),
  '保存目录': ('Save folder', '保存先フォルダー'),
  '选择目录': ('Choose folder', 'フォルダーを選択'),
  '命名方式': ('File naming', 'ファイル名の付け方'),
  '默认格式': ('Default format', '既定の形式'),
  'JPG画质': ('JPG quality', 'JPG 画質'),
  '拍摄与导出保存在所选目录。勾选、调整页面顺序后可导出 PDF；原图会保留。': (
    'Scans and exports go to the selected folder. Select and reorder pages before exporting a PDF. Original images are kept.',
    '撮影画像と書き出したファイルは指定フォルダーに保存されます。ページを選択・並べ替えて PDF に書き出せます。元画像は保持されます。',
  ),
  '关闭': ('Close', '閉じる'),
  '裁切方式': ('Cropping', '切り抜き方法'),
  '展平方式': ('Page correction', 'ページ補正'),
  '扫描书页': ('Book page', 'スキャンするページ'),
  '阅读顺序': ('Reading order', '読む順序'),
  '重新识别中线': ('Redetect spine', '背の位置を再検出'),
  '自动识别中线': ('Detect spine', '背の位置を自動検出'),
  '扫描模式': ('Scan mode', 'スキャンモード'),
  '自动': ('Automatic', '自動'),
  '手动': ('Manual', '手動'),
  '静止倒计时': ('Capture delay', '静止後の待ち時間'),
  '{0} 秒': ('{0} s', '{0} 秒'),
  '输出效果': ('Color mode', '色補正'),
  '扫描页面': ('Page output', 'ページ出力'),
  '多页 PDF': ('Multipage PDF', '複数ページ PDF'),
  '单页': ('Single page', '単一ページ'),
  '输出格式': ('Output format', '出力形式'),
  '录制来源': ('Record source', '録画ソース'),
  '录制格式': ('Record format', '録画形式'),
  '识别语言': ('OCR language', '認識言語'),
  '文字方向': ('Text layout', '文字の向き'),
  '前缀': ('Prefix', '接頭辞'),
  '智能修边': ('Clean up edges', '端の自動補正'),
  '正反面合并': ('Combine front and back', '表裏を結合'),
  '读取身份证': ('Read ID card', '身分証を読み取る'),
  '识别类型': ('Code type', 'コードの種類'),
  '二维码': ('QR code', 'QR コード'),
  '条码': ('Barcode', 'バーコード'),
  '开始识别': ('Recognize code', '認識を開始'),
  '识别所选图片': ('Recognize selected image', '選択した画像を認識'),
  '导出文字': ('Export text', 'テキストを書き出す'),
  '签章位置': ('Mark position', '署名・印影の位置'),
  '左上': ('Top left', '左上'),
  '右上': ('Top right', '右上'),
  '左下': ('Bottom left', '左下'),
  '右下': ('Bottom right', '右下'),
  '签章尺寸': ('Mark size', '署名・印影のサイズ'),
  '签名 / 印章图片': ('Signature or seal images', '署名・印影の画像'),
  '更换印章': ('Replace seal', '印影を変更'),
  '添加印章': ('Add seal', '印影を追加'),
  '更换签名': ('Replace signature', '署名を変更'),
  '添加签名': ('Add signature', '署名を追加'),
  '已扫描 {0} 页': ('Pages scanned: {0}', 'スキャン済み：{0} ページ'),
  '导出PDF': ('Export PDF', 'PDF に書き出す'),
  '导出所选 {0} 页': ('Export selected ({0})', '選択した {0} ページを書き出す'),
  '拍摄或导入图片': ('Capture or import images', '画像を撮影または読み込む'),
  '在这里选择、排序\n并合成多页 PDF': (
    'Select and reorder pages\nto create a multipage PDF',
    'ページを選択・並べ替えて\n複数ページの PDF を作成',
  ),
  '打开保存目录': ('Open save folder', '保存先を開く'),
  '查看刚导出的文件': ('Open exported file', '書き出したファイルを開く'),
  '向前移动': ('Move earlier', '前に移動'),
  '向后移动': ('Move later', '後ろに移動'),
  '查看图片': ('View image', '画像を表示'),
  '移出列表（保留文件）': ('Remove from list (keep file)', '一覧から除外（ファイルは保持）'),
  '原始图片不存在': ('Original image is missing', '元画像が見つかりません'),
  '在文件夹中显示': ('Show in folder', 'フォルダーに表示'),
  '导入图片，或选择右侧已扫描页面': (
    'Import an image or select a scanned page on the right',
    '画像を読み込むか、右側のスキャン済みページを選択してください',
  ),
  '识别结果': ('Recognized text', '認識結果'),
  '选择识别语言后点击“识别文字”': (
    'Choose an OCR language, then click “Recognize text”.',
    '認識言語を選び、「文字を認識」をクリックしてください',
  ),
  '拖动四个角点贴合文件边缘；拖出新区域可重新框选': (
    'Drag the corners to the document edges, or drag a new selection',
    '四隅を原稿の端に合わせるか、ドラッグして範囲を選び直してください',
  ),
  '手动中线 · 拖动虚线对齐书脊，或点击“重新识别中线”': (
    'Manual spine · Drag the guide to the spine or click “Redetect spine”',
    '手動調整 · ガイドを本の背に合わせるか、「背の位置を再検出」をクリック',
  ),
  '自动识别书脊与书页边界 · 可拖动虚线手动调整': (
    'Spine and page edges detected · Drag the guide to adjust',
    '背とページの端を検出しました。ガイドをドラッグして調整できます',
  ),
  '正在寻找文件边界 · 请留出四周边缘': (
    'Looking for document edges · Leave space around the document',
    '原稿の端を検出中です。周囲に余白を残してください',
  ),
  '识别到 {0} 个文档 · 将分别保存': (
    'Documents detected: {0} · Each will be saved separately',
    '原稿を {0} 件検出しました。個別に保存されます',
  ),
  '已检测到文件边界': ('Document edges detected', '原稿の端を検出しました'),
  '正在扫描…': ('Scanning…', 'スキャン中…'),
  '画面已稳定，即将拍摄': ('Image is stable. Capturing shortly.', '画面が安定しました。まもなく撮影します'),
  '本页已扫描，请更换文档': (
    'Page scanned. Replace the document.',
    'スキャンが完了しました。次の原稿に替えてください',
  ),
  '等待画面停止变化…': ('Waiting for the image to settle…', '画面が安定するまで待機中…'),
  '等待文件和稳定画面…': (
    'Waiting for a document and a stable image…',
    '原稿の配置と画面の安定を待っています…',
  ),
  '等待画面...': ('Waiting for preview…', 'プレビュー待機中…'),
  '正在打开摄像头...': ('Opening camera…', 'カメラを起動中…'),
  '未连接扫描仪': ('Scanner not connected', 'スキャナーが接続されていません'),
  '设备': ('Device', '機器'),
  '未发现设备': ('No devices found', '機器が見つかりません'),
  '视频格式': ('Video format', '映像形式'),
  '分辨率': ('Resolution', '解像度'),
  '该功能开发中': ('This feature is in development.', 'この機能は開発中です'),
  '停止录制': ('Stop recording', '録画を停止'),
  '开始录制': ('Start recording', '録画を開始'),
  '识别文字': ('Recognize text', '文字を認識'),
  '停止自动扫描': ('Stop auto scan', '自動スキャンを停止'),
  '开始自动扫描': ('Start auto scan', '自動スキャンを開始'),
  '拍摄': ('Capture', '撮影'),
  '处理中…': ('Processing…', '処理中…'),
  '左旋90°': ('Rotate left 90°', '左に 90° 回転'),
  '右旋90°': ('Rotate right 90°', '右に 90° 回転'),
  '放大': ('Zoom in', '拡大'),
  '缩小': ('Zoom out', '縮小'),
  '1:1 实际大小': ('Actual size (1:1)', '原寸表示（1:1）'),
  '自动扫描（连拍）': ('Automatic scanning', '自動連続スキャン'),
  '缩小化视频区域': ('Shrink preview', 'プレビューを縮小'),
  '正在重新对焦…': ('Refocusing…', 'ピントを調整中…'),
  '手动对焦': ('Refocus', 'ピントを合わせる'),
  '最大化视频区域': ('Maximize preview', 'プレビューを最大化'),
  '未连接': ('Disconnected', '未接続'),
  '正在连接扫描仪…': ('Connecting to scanner…', 'スキャナーに接続中…'),
  '连接失败：{0}': ('Connection failed: {0}', '接続できませんでした：{0}'),
  '释放旧设备：{0}': (
    'Could not release the previous device: {0}',
    '前の機器を解放できませんでした：{0}',
  ),
  '刷新设备失败：{0}': ('Could not refresh devices: {0}', '機器を再検出できませんでした：{0}'),
  '未发现摄像头或扫描仪，请检查连接后刷新设备': (
    'No camera or scanner found. Check the connection and refresh devices.',
    'カメラやスキャナーが見つかりません。接続を確認して機器を再検出してください',
  ),
  '切换设备失败：{0}': ('Could not switch devices: {0}', '機器を切り替えられませんでした：{0}'),
  '当前设备不支持 {0}': ('This device does not support {0}', 'この機器は {0} に対応していません'),
  '演示画面 · 不代表真实扫描仪': (
    'Demo preview · No physical scanner',
    'デモプレビュー · 実機は使用していません',
  ),
  '预览中 {0}': ('Previewing at {0}', 'プレビュー中 {0}'),
  '打开摄像头失败：{0}': ('Could not open the camera: {0}', 'カメラを起動できませんでした：{0}'),
  '自动扫描已停止': ('Auto scan stopped', '自動スキャンを停止しました'),
  '自动拍摄：{0}': ('Automatically captured: {0}', '自動撮影：{0}'),
  '识别结果：{0}': ('Recognized: {0}', '認識結果：{0}'),
  '未识别到条码，请调整位置或光线': (
    'No barcode detected. Adjust the position or lighting.',
    'バーコードが見つかりません。位置や照明を調整してください',
  ),
  'OCR 识别中 {0}%': ('Recognizing text · {0}%', '文字を認識中 · {0}%'),
  '正面已拍摄，请翻面后拍摄背面': (
    'Front captured. Turn the card over and capture the back.',
    '表面を撮影しました。裏返して裏面を撮影してください',
  ),
  '没有识别到文字；原图已保存在 {0}': (
    'No text found. The original was saved to {0}',
    '文字が見つかりません。元画像の保存先：{0}',
  ),
  '已加入多页文档 · {0} 页': (
    'Added to multipage document · Pages: {0}',
    '複数ページの文書に追加しました · {0} ページ',
  ),
  '已保存：{0}': ('Saved: {0}', '保存しました：{0}'),
  '书籍拍摄完成 · {0} 页': (
    'Book scan complete · Pages: {0}',
    '書籍のスキャンが完了しました · {0} ページ',
  ),
  '书籍拍摄完成 · {0} 页 · {1}': (
    'Book scan complete · Pages: {0} · {1}',
    '書籍のスキャンが完了しました · {0} ページ · {1}',
  ),
  '已分别保存 {0} 个文档': ('Documents saved separately: {0}', '原稿を {0} 件個別に保存しました'),
  '书籍拍摄失败：{0}': ('Book scan failed: {0}', '書籍をスキャンできませんでした：{0}'),
  '拍照失败：{0}': ('Capture failed: {0}', '撮影できませんでした：{0}'),
  '正在识别…': ('Recognizing…', '認識中…'),
  '条码识别失败：{0}': ('Barcode recognition failed: {0}', 'バーコードを認識できませんでした：{0}'),
  '未读取到证件，请确认已连接身份证读卡器': (
    'Could not read the ID card. Check the card reader connection.',
    '身分証を読み取れません。カードリーダーの接続を確認してください',
  ),
  '身份证读取成功': ('ID card read successfully', '身分証を読み取りました'),
  '读证失败：{0}': ('Could not read the ID card: {0}', '身分証を読み取れませんでした：{0}'),
  '请先拍摄或导入图片': ('Capture or import an image first.', '先に画像を撮影または読み込んでください'),
  '正在识别文字…': ('Recognizing text…', '文字を認識中…'),
  '没有识别到文字，请检查清晰度和识别语言': (
    'No text found. Check image clarity and the OCR language.',
    '文字が見つかりません。画像の鮮明さと認識言語を確認してください',
  ),
  'OCR 完成 · {0} 字': ('OCR complete · Characters: {0}', '文字認識が完了しました · {0} 文字'),
  'OCR 失败：{0}': ('OCR failed: {0}', '文字を認識できませんでした：{0}'),
  '识别结果已导出：{0}': ('Recognized text exported: {0}', '認識結果を書き出しました：{0}'),
  '识别结果导出失败：{0}': (
    'Could not export recognized text: {0}',
    '認識結果を書き出せませんでした：{0}',
  ),
  '没有可导出的页面': ('No pages to export.', '書き出せるページがありません'),
  '正在生成 {0} 页 PDF…': ('Creating PDF · Pages: {0}…', 'PDF を作成中 · {0} ページ…'),
  'PDF 已生成 · {0} 页 · {1}': (
    'PDF created · Pages: {0} · {1}',
    'PDF を作成しました · {0} ページ · {1}',
  ),
  'PDF 导出失败：{0}': ('Could not export PDF: {0}', 'PDF を書き出せませんでした：{0}'),
  '已导入 {0} 张图片': ('Images imported: {0}', '画像を {0} 枚読み込みました'),
  '已导入 {0} 张图片，跳过 {1} 张已导入图片': (
    'Images imported: {0}. Already imported: {1}.',
    '画像を {0} 枚読み込み、読み込み済みの {1} 枚をスキップしました',
  ),
  '{0}；无法导入 {1} 张：{2}': (
    '{0} · Images that could not be imported ({1}): {2}',
    '{0} · 読み込めなかった画像（{1} 枚）：{2}',
  ),
  '自动扫描中 · 画面静止后倒计时 {0} 秒': (
    'Auto scan · Capture {0} s after the image settles',
    '自動スキャン中 · 画面が安定してから {0} 秒後に撮影',
  ),
  '此模式请使用手动拍摄': ('Use manual capture in this mode.', 'このモードでは手動で撮影してください'),
  '自动扫描无法启动：{0}': ('Could not start auto scan: {0}', '自動スキャンを開始できませんでした：{0}'),
  '文件不存在：{0}': ('File not found: {0}', 'ファイルが見つかりません：{0}'),
  '打开文件失败：{0}': ('Could not open the file: {0}', 'ファイルを開けませんでした：{0}'),
  '无法保存目录授权': (
    'Could not save access to the folder.',
    'フォルダーへのアクセス許可を保存できませんでした',
  ),
  '保存目录不可用：{0}': ('Save folder unavailable: {0}', '保存先を使用できません：{0}'),
  '正在录制{0}画面…': ('Recording · {0}…', '録画中 · {0}…'),
  '正在录制{0} · {1}': ('Recording · {0} · {1}', '録画中 · {0} · {1}'),
  '录制失败：{0}': ('Recording failed: {0}', '録画できませんでした：{0}'),
  '视频已保存：{0}': ('Video saved: {0}', '動画を保存しました：{0}'),
  '保存视频失败：{0}': ('Could not save the video: {0}', '動画を保存できませんでした：{0}'),
  '已触发重新对焦，请等待画面稳定': (
    'Refocus requested. Wait for the image to settle.',
    'ピントを調整しています。画面が安定するまでお待ちください',
  ),
  '对焦失败：{0}': ('Could not refocus: {0}', 'ピントを合わせられませんでした：{0}'),
  '保存目录授权失效，请重新选择目录': (
    'Access to the save folder expired. Choose the folder again.',
    '保存先へのアクセス許可が無効です。フォルダーを選び直してください',
  ),
  '文档': ('Document', '文書'),
  '书籍': ('Book', '書籍'),
  '证件': ('ID card', '身分証'),
  '条码识别': ('Barcode', 'バーコード'),
  '视频录制': ('Video', '録画'),
  '合同管理': ('Contracts', '契約書'),
  '不裁切': ('No crop', '切り抜きなし'),
  '自动裁切': ('Auto crop', '自動切り抜き'),
  '手动裁切': ('Manual crop', '手動切り抜き'),
  '多图剪裁': ('Crop multiple', '複数原稿の切り抜き'),
  '原生色彩': ('Original color', '元の色'),
  '灰度': ('Grayscale', 'グレースケール'),
  '黑白': ('Black and white', '白黒'),
  '文档优化': ('Enhance document', '文書を補正'),
  '白纸印章': ('White paper + seals', '白地・印影を強調'),
  '图像PDF': ('Image PDF', '画像 PDF'),
  '文字PDF': ('Text PDF', 'テキスト PDF'),
  '编号': ('Sequence', '連番'),
  '日期时间': ('Date and time', '日時'),
  '自定义': ('Custom', 'カスタム'),
  '以文件夹命名': ('Folder name', 'フォルダー名'),
  '证件号码': ('ID number', '身分証番号'),
  '条码号': ('Barcode value', 'バーコードの値'),
  '不展平': ('No correction', '補正なし'),
  '单页展平': ('Flatten one page', '片ページを補正'),
  '双页展平': ('Flatten both pages', '見開きを補正'),
  '双页分割': ('Split spread', '見開きを分割'),
  '左页': ('Left page', '左ページ'),
  '右页': ('Right page', '右ページ'),
  '左页优先': ('Left page first', '左ページから'),
  '右页优先': ('Right page first', '右ページから'),
  '横排': ('Horizontal', '横書き'),
  '竖排（右起）': ('Vertical (right first)', '縦書き（右から）'),
  '中文简体,English': ('Chinese (Simplified) + English', '中国語（簡体字）＋英語'),
  '中文简体': ('Chinese (Simplified)', '中国語（簡体字）'),
  '日本語': ('Japanese', '日本語'),
  '屏幕': ('Screen', '画面'),
  '摄像头': ('Camera', 'カメラ'),
  '无法解码扫描图像': ('Could not decode the scanned image.', 'スキャン画像を読み込めませんでした'),
  '请调整四个裁切角点，使它们贴合文档边缘': (
    'Drag the four crop corners to the edges of the document.',
    '切り抜き範囲の四隅を原稿の端に合わせてください',
  ),
  '没有检测到完整文档边界，请将文件放入画面、留出边缘，或使用手动裁切': (
    'Full document edges could not be detected. Leave space around the document or crop manually.',
    '原稿全体の端を検出できません。周囲に余白を残すか、手動で切り抜いてください',
  ),
  '扫描图像编码失败': ('Could not encode the scanned image.', 'スキャン画像をエンコードできませんでした'),
  '无法读取书籍图像': ('Could not read the book image.', '書籍の画像を読み込めませんでした'),
  '未检测到完整书页边界，请留出四周边缘': (
    'Full page edges could not be detected. Leave space around the book.',
    'ページ全体の端を検出できません。書籍の周囲に余白を残してください',
  ),
  '未检测到两张完整书页，请留出四周边缘或选择单页展平': (
    'Could not detect both pages. Leave space around the book or flatten one page.',
    '見開きの両ページを検出できません。周囲に余白を残すか、片ページを補正してください',
  ),
  '竖排书页已矫正透视': ('Perspective corrected for vertical text', '縦書きページの傾きを補正しました'),
  '文字行不足，本次仅矫正书页透视': (
    'Too few text lines. Applied perspective correction only.',
    '文字の行が少ないため、ページの傾きのみ補正しました',
  ),
  '当前系统不支持 OCR': ('OCR is unavailable on this system.', 'このシステムは文字認識に対応していません'),
  '竖排 OCR 需要支持实况文本的 macOS 13 或更新版本': (
    'Vertical OCR requires macOS 13 or later with Live Text support.',
    '縦書きの文字認識には、テキスト認識表示に対応した macOS 13 以降が必要です',
  ),
  '系统摄像头已就绪': ('System camera ready', 'システムカメラの準備ができました'),
  '演示相机 (Mock)': ('Demo camera', 'デモカメラ'),
  'Mock 后端（无设备演示模式）': ('Demo mode (no device connected)', 'デモモード（機器未接続）'),
  'FaceTime高清相机': ('FaceTime HD Camera', 'FaceTime HD カメラ'),
  'USB相机': ('USB camera', 'USB カメラ'),
  '无法识别原生摄像头信息': (
    'Could not read system camera information.',
    'システムカメラの情報を取得できませんでした',
  ),
  '未收到摄像头图像': ('No image received from the camera.', 'カメラから画像を取得できませんでした'),
  '系统摄像头暂不支持条码识别，请在设置中切换至厂商扫描仪服务': (
    'Barcode recognition requires the vendor scanner service. Select it in Settings.',
    'バーコード認識にはメーカーのスキャナーサービスが必要です。設定で切り替えてください',
  ),
  '系统摄像头不支持专用身份证读卡器；可使用正反面拍照合并': (
    'The system camera cannot use an ID card reader. Capture and combine the two sides instead.',
    'システムカメラでは身分証リーダーを使用できません。表裏を撮影して結合できます',
  ),
  '请通过主界面的自动扫描启动翻页检测': (
    'Use Auto Scan in the main window to detect page turns.',
    'メイン画面の自動スキャンからページめくりの検出を開始してください',
  ),
  '请在系统设置中允许智能高拍仪使用摄像头': (
    'Allow Smart Scanner to use the camera in System Settings.',
    'システム設定でスマートスキャナーのカメラ使用を許可してください',
  ),
  '摄像头权限未授权，请在系统设置中允许摄像头访问': (
    'Camera access was denied. Allow it in System Settings.',
    'カメラへのアクセスが拒否されました。システム設定で許可してください',
  ),
  '没有摄像头画面': ('No camera preview.', 'カメラの映像がありません'),
  'English': ('English', '英語'),
  '缺少目录路径': ('Missing folder path.', 'フォルダーのパスが指定されていません'),
  '缺少目录授权': ('Missing folder permission.', 'フォルダーへのアクセス許可がありません'),
  '请重新选择保存目录': ('Choose the save folder again.', '保存先フォルダーを選び直してください'),
  '设备不存在': ('Device not found.', '機器が見つかりません'),
  '无法打开摄像头': ('Could not open the camera.', 'カメラを起動できませんでした'),
  '无法开启视频输出': ('Could not start the video stream.', '映像の出力を開始できませんでした'),
  '设备不支持所选分辨率': (
    'The device does not support the selected resolution.',
    '選択した解像度に機器が対応していません',
  ),
  '请等待摄像头画面': ('Wait for the camera preview.', 'カメラの映像が表示されるまでお待ちください'),
  '图像编码失败': ('Could not encode the image.', '画像をエンコードできませんでした'),
  '缺少图片路径': ('Missing image path.', '画像のパスが指定されていません'),
  '当前 macOS 不支持所选识别语言，请更新系统或选择 English': (
    'This macOS version does not support the selected OCR language. Update macOS or choose English.',
    'この macOS は選択した認識言語に対応していません。macOS を更新するか、英語を選択してください',
  ),
  '请先打开相机预览': ('Open the camera preview first.', '先にカメラのプレビューを開いてください'),
  '当前相机不支持自动对焦，请调整镜头或拍摄距离': (
    'This camera does not support autofocus. Adjust the lens or shooting distance.',
    'このカメラはオートフォーカスに対応していません。レンズや撮影距離を調整してください',
  ),
  '当前相机不支持通过系统接口重新对焦，请调整镜头或拍摄距离': (
    'This camera cannot refocus through the system. Adjust the lens or shooting distance.',
    'このカメラはシステムからピントを調整できません。レンズや撮影距離を調整してください',
  ),
  '相机图像编码格式不可用': (
    'The camera image encoding format is unavailable.',
    'カメラ画像のエンコード形式を使用できません',
  ),
  '摄像头不存在，请刷新设备列表': (
    'Camera not found. Refresh the device list.',
    'カメラが見つかりません。機器の一覧を更新してください',
  ),
  '设备不支持所选分辨率，请刷新设备后重新选择': (
    'The device does not support the selected resolution. Refresh devices and select again.',
    '選択した解像度に対応していません。機器を再検出して選び直してください',
  ),
  '摄像头返回了不同的采集尺寸，请重新选择分辨率': (
    'The camera returned a different image size. Select the resolution again.',
    'カメラが異なるサイズの画像を返しました。解像度を選び直してください',
  ),
  '摄像头没有返回画面，请关闭占用设备的软件后重试': (
    'The camera returned no image. Close other apps using it and try again.',
    'カメラから映像を取得できません。使用中のほかのアプリを閉じて再試行してください',
  ),
  '没有实时摄像头画面，请重新连接设备': (
    'No live camera image. Reconnect the device.',
    'カメラの映像がありません。機器を再接続してください',
  ),
  '不支持的相机操作': ('Unsupported camera operation.', 'カメラがこの操作に対応していません'),
  '当前系统没有所选 OCR 语言包，请在 Windows 语言设置中安装中文、日语或英语的基本输入功能': (
    'The selected OCR language pack is missing. Install Basic typing for Chinese, Japanese, or English in Windows language settings.',
    '選択した認識言語のパックがありません。Windows の言語設定で中国語、日本語、または英語の基本の入力をインストールしてください',
  ),
  '无法读取图像': ('Could not read the image.', '画像を読み込めませんでした'),
  '没有可导出的图像': ('No images to export.', '書き出せる画像がありません'),
  'PDF 中包含无法读取的图像': (
    'The PDF contains an unreadable image.',
    'PDF に読み込めない画像が含まれています',
  ),
  '无法读取证件图像': ('Could not read the ID card image.', '身分証の画像を読み込めませんでした'),
  '无法读取签名或印章': (
    'Could not read the signature or seal image.',
    '署名または印影を読み込めませんでした',
  ),
  '文件保存失败': ('Could not save the file.', 'ファイルを保存できませんでした'),
  '拍摄没有返回有效图像': ('Capture returned no valid image.', '撮影した画像を取得できませんでした'),
  '当前系统不支持屏幕录制': (
    'Screen recording is unavailable on this system.',
    'このシステムは画面収録に対応していません',
  ),
  '视频录制需要 FFmpeg，请安装后重试，或将 ffmpeg 加入系统 PATH': (
    'Video recording requires FFmpeg. Install it or add ffmpeg to PATH and try again.',
    '録画には FFmpeg が必要です。インストールするか PATH に追加して再試行してください',
  ),
  '摄像头未返回画面，录像未启动': (
    'Recording did not start because the camera returned no image.',
    'カメラから映像を取得できず、録画を開始できませんでした',
  ),

  '拍摄正面': ('Capture front', '表面を撮影'),
  '拍摄背面并合并': ('Capture back & combine', '裏面を撮影して結合'),
  '重拍正面': ('Retake front', '表面を撮り直す'),
  '请放置正面并拍摄': ('Place the front side up and capture.', '表面を上にして撮影してください'),
  '第 2 步 · 翻到背面，绿框贴合卡片后拍摄，自动合并': (
    'Step 2 · Turn the card over. Check the green edges, then capture to combine.',
    '手順 2 · 裏返し、緑の枠を確認して撮影すると結合されます',
  ),
  '第 1 步 · 放置正面，四周留边，绿框贴合卡片后拍摄': (
    'Step 1 · Place the front side up with space around it. Check the green edges before capture.',
    '手順 1 · 表面を上にして周囲に余白を残し、緑の枠を確認して撮影してください',
  ),
  '放入一张卡片，绿框贴合边缘后拍摄；可选择双面模式': (
    'Place one card in view. Check the green edges, then capture. Choose both sides to combine the front and back.',
    'カードを 1 枚置き、緑の枠を確認して撮影してください。両面の撮影も選べます',
  ),
  '正面已暂存 · 等待背面': ('Front captured · Back pending', '表面を一時保存 · 裏面の撮影待ち'),
  '证件模式': ('Card mode', 'カードの撮影方式'),
  '双面（各拍一次）': ('Both sides (one at a time)', '両面（1 面ずつ撮影）'),
  '单面': ('One side', '片面'),

  '图片缩放': ('Image scale', '画像の倍率'),
  '原始像素（100%）': ('Original pixels (100%)', '元の画素数（100%）'),
  'A4 证件 PDF': ('A4 card PDF', 'A4 カード PDF'),
  '打印缩放': ('Print scale', '印刷倍率'),
  '原尺寸（100%）': ('Actual size (100%)', '原寸（100%）'),
  '卡片宽度（mm）': ('Card width (mm)', 'カードの幅（mm）'),
  'A4 单张排版 · 上正面、下背面 · 打印请选择“实际大小”': (
    'One A4 sheet · Front above back · Print at actual size',
    'A4 1 枚に配置 · 上が表面、下が裏面 · 印刷は「実際のサイズ」を選択',
  ),
  '证件排版超出 A4 范围，请减小打印缩放或检查裁切': (
    'The card layout exceeds A4. Reduce the print scale or check the crop.',
    'A4 の範囲を超えています。印刷倍率を下げるか、切り抜きを確認してください',
  ),
};
