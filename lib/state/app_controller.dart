/// 应用状态控制器：连接管理、预览合成、拍摄流程、设置持久化。
library;

import 'dart:async';
import 'dart:io';

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/km_server_backend.dart';
import '../backend/mac_avf_backend.dart';
import '../backend/mock_backend.dart';
import '../backend/scanner_backend.dart';
import '../core/models.dart';

class AppController extends ChangeNotifier {
  ScannerBackend? _backend;
  StreamSubscription<PreviewFrame>? _frameSub;
  StreamSubscription<ScannerEvent>? _eventSub;

  // 连接与设备
  bool connected = false;
  String statusMessage = '未连接';
  bool usingMock = false;
  List<ScannerDevice> devices = const [];
  int deviceIndex = 0;
  List<ScanResolution> resolutions = const [];
  ScanResolution? resolution;
  bool previewOpen = false;

  // 模式与参数
  ScanMode mode = ScanMode.document;
  CutMode cutMode = CutMode.none;
  ColorEffect colorEffect = ColorEffect.native;
  OutputFormat outputFormat = OutputFormat.jpg;
  NameStyle nameStyle = NameStyle.dateTime;
  FlattenMode flattenMode = FlattenMode.none;
  OcrLanguage ocrLanguage = OcrLanguage.chineseEnglish;
  bool smartEdge = false; // 去黑边/智能修边
  bool removeBg = false; // 去底色
  int jpgQuality = 85;
  String prefix = 'Pic_';
  String outputDir = '';
  bool autoScan = false; // 自动连拍
  int sequence = 1; // 自增序号

  // 预览
  ui.Image? previewImage;
  int canvasW = 0;
  int canvasH = 0;
  Uint8List? _canvasRgb;
  bool _converting = false;
  double previewFps = 0;
  int _fpsWindowCount = 0;
  final _fpsStopwatch = Stopwatch()..start();
  double _fpsWindowStart = 0;

  // 拍摄结果
  final List<CapturedPage> pages = [];
  bool capturing = false;
  String lastCapturePath = '';

  // 识别结果
  String lastBarcode = '';
  String lastOcrText = '';
  IdCardEvent? lastIdCard;
  String ocrStatus = '';

  // 事件（一次性通知用）
  String? lastError;

  ScannerBackend get backend => _backend!;

  /// 预览画布坐标系下当前帧的宽高
  (int, int) get canvasSize => (canvasW, canvasH);

  /// 初始化。
  ///
  /// [backendOverride]/[outputDirOverride] 仅用于测试：跳过插件依赖
  /// （SharedPreferences / path_provider）。
  Future<void> init({
    bool forceMock = false,
    ScannerBackend? backendOverride,
    String? outputDirOverride,
  }) async {
    if (backendOverride == null) {
      await _loadPrefs();
    }
    if (outputDirOverride != null) {
      outputDir = outputDirOverride;
    } else if (outputDir.isEmpty) {
      outputDir = await _defaultOutputDir();
    }
    if (backendOverride != null) {
      _backend = backendOverride;
      usingMock = backendOverride is MockBackend;
    } else if (forceMock) {
      _backend = MockBackend();
      usingMock = true;
    } else if (Platform.isMacOS) {
      _backend = MacAvfBackend();
    } else {
      _backend = KmServerBackend();
    }
    _frameSub = _backend!.frames.listen(_onFrame);
    _eventSub = _backend!.events.listen(_onEvent);
    notifyListeners();
  }

  Future<String> _defaultOutputDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir =
        Directory('${base.path}${Platform.pathSeparator}SmartScanner');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// 连接后端并枚举设备
  Future<void> connect({bool allowMockFallback = true}) async {
    statusMessage = '正在连接扫描仪服务...';
    notifyListeners();
    try {
      await _backend!.connect();
      connected = true;
      usingMock = _backend is MockBackend;
      statusMessage =
          usingMock ? '演示模式（无设备）' : '已连接 KHServer 高拍仪服务';
    } catch (e) {
      connected = false;
      if (allowMockFallback && _backend is KmServerBackend) {
        // KHServer 不可用 → 降级 Mock，保证 UI 可用
        await _frameSub?.cancel();
        await _eventSub?.cancel();
        await _backend?.disconnect();
        _backend = MockBackend();
        usingMock = true;
        _frameSub = _backend!.frames.listen(_onFrame);
        _eventSub = _backend!.events.listen(_onEvent);
        await _backend!.connect();
        connected = true;
        statusMessage = 'KHServer 不可用（$e），已切换演示模式';
      } else {
        statusMessage = '连接失败: $e';
        lastError = '$e';
        notifyListeners();
        return;
      }
    }
    notifyListeners();
    await refreshDevices();
  }

  Future<void> refreshDevices() async {
    try {
      devices = await _backend!.listDevices();
      if (devices.isEmpty) {
        statusMessage = '未发现扫描仪设备';
      } else {
        deviceIndex = deviceIndex.clamp(0, devices.length - 1);
        statusMessage = '设备: ${devices[deviceIndex].name}';
        await refreshResolutions();
      }
    } catch (e) {
      statusMessage = '枚举设备失败: $e';
    }
    notifyListeners();
  }

  Future<void> refreshResolutions() async {
    try {
      resolutions = await _backend!.listResolutions(deviceIndex);
      if (resolutions.isNotEmpty) {
        // 优先 1920x1080 附近（预览帧率较均衡）
        resolution = resolutions.firstWhere(
            (r) => r.width == 1920 && r.height == 1080,
            orElse: () =>
                resolutions.firstWhere((r) => r.width <= 2592,
                    orElse: () => resolutions.first));
      }
    } catch (e) {
      statusMessage = '获取分辨率失败: $e';
    }
    notifyListeners();
  }

  Future<void> selectDevice(int index) async {
    deviceIndex = index;
    notifyListeners();
    await refreshResolutions();
  }

  Future<void> selectResolution(ScanResolution r) async {
    resolution = r;
    notifyListeners();
    await reopenPreview();
  }

  /// 用当前画布尺寸打开预览
  Future<void> reopenPreview() async {
    if (!connected || resolution == null) return;
    try {
      if (previewOpen) {
        await _backend!.close();
        previewOpen = false;
      }
      await _applyProcessingSettings();
      await _backend!.open(
        deviceIndex: deviceIndex,
        canvasW: canvasW.clamp(320, 1920),
        canvasH: canvasH.clamp(240, 1440),
        captureW: resolution!.width,
        captureH: resolution!.height,
      );
      previewOpen = true;
      statusMessage = '预览中 ${resolution!.label}';
    } catch (e) {
      statusMessage = '打开摄像头失败: $e';
      lastError = '$e';
    }
    notifyListeners();
  }

  /// 预览区域尺寸变化（画布重开，带迟滞避免频繁开关）
  DateTime _lastCanvasChange = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> setCanvasSize(int w, int h) async {
    // 与请求值取整十位
    final nw = ((w ~/ 10) * 10).clamp(320, 1920);
    final nh = ((h ~/ 10) * 10).clamp(240, 1440);
    if (nw == canvasW && nh == canvasH) return;
    final now = DateTime.now();
    if (now.difference(_lastCanvasChange).inMilliseconds < 600) return;
    _lastCanvasChange = now;
    canvasW = nw;
    canvasH = nh;
    _canvasRgb = Uint8List(nw * nh * 3);
    notifyListeners();
    await reopenPreview();
  }

  void _applyProcessingSettingsToBackend() {
    final b = _backend!;
    b.setFileType(outputFormat.serverIndex);
    b.setJpgQuality(jpgQuality);
    b.setColorMode(colorEffect.serverIndex);
    b.setDeleteBlackEdge(smartEdge ? 1 : 0);
    b.setDeleteBgColor(removeBg ? 1 : 0);
    b.setCutMode(cutMode.index);
    b.setZpMode(flattenMode.index);
  }

  Future<void> _applyProcessingSettings() async {
    if (!connected) return;
    try {
      _applyProcessingSettingsToBackend();
    } catch (_) {}
  }

  // ---------------- 帧处理 ----------------

  void _onFrame(PreviewFrame f) {
    final w = canvasW, h = canvasH;
    if (w <= 0 || h <= 0) return;
    var buf = _canvasRgb;
    if (buf == null || buf.length != w * h * 3) {
      buf = Uint8List(w * h * 3);
      _canvasRgb = buf;
    }
    if (f.x + f.width <= w && f.y + f.height <= h && f.rgb.length >= f.width * f.height * 3) {
      for (int row = 0; row < f.height; row++) {
        final src = row * f.width * 3;
        final dst = ((f.y + row) * w + f.x) * 3;
        buf.setRange(dst, dst + f.width * 3, f.rgb, src);
      }
    }
    _convertToImage(buf, w, h);
  }

  Future<void> _convertToImage(Uint8List rgb, int w, int h) async {
    if (_converting) return;
    _converting = true;
    try {
      final rgba = Uint8List(w * h * 4);
      int di = 0;
      final pxCount = w * h;
      for (int si = 0; si < pxCount * 3; si += 3) {
        rgba[di++] = rgb[si];
        rgba[di++] = rgb[si + 1];
        rgba[di++] = rgb[si + 2];
        rgba[di++] = 255;
      }
      final descriptor = ui.ImageDescriptor.raw(
        await ui.ImmutableBuffer.fromUint8List(rgba),
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final frame =
          await descriptor.instantiateCodec().then((c) => c.getNextFrame());
      final old = previewImage;
      previewImage = frame.image;
      old?.dispose();

      // fps 统计
      _fpsWindowCount++;
      final t = _fpsStopwatch.elapsedMicroseconds / 1e6;
      if (t - _fpsWindowStart >= 2.0) {
        previewFps = _fpsWindowCount / (t - _fpsWindowStart);
        _fpsWindowCount = 0;
        _fpsWindowStart = t;
        notifyListeners();
        return;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('frame convert error: $e');
    } finally {
      _converting = false;
    }
  }

  // ---------------- 事件 ----------------

  void _onEvent(ScannerEvent ev) {
    switch (ev) {
      case ConnectionEvent(:final connected, :final detail):
        this.connected = connected;
        statusMessage = detail;
        if (!connected) previewOpen = false;
      case CaptureEvent(:final ok, :final path, :final imageBytes):
        capturing = false;
        if (ok) {
          lastCapturePath = path;
          _addPage(path, imageBytes);
          statusMessage = '已保存: ${_basename(path)}';
        } else {
          statusMessage = '拍照失败';
          lastError = '拍照失败';
        }
      case WiseCaptureEvent(:final done, :final steady, :final path, :final imageBytes):
        if (done) {
          autoScan = false;
          statusMessage = '自动扫描已停止';
        } else if (steady && path.isNotEmpty) {
          _addPage(path, imageBytes);
          statusMessage = '自动拍摄: ${_basename(path)}';
        }
      case BarcodeEvent(:final ok, :final content):
        lastBarcode = ok ? content : '未识别到内容';
        statusMessage = ok ? '条码: $content' : '未识别到条码';
      case OcrEvent(:final ok, :final progress, :final text):
        if (ok) {
          lastOcrText = text;
          ocrStatus = '';
          if (pages.isNotEmpty && text.isNotEmpty) {
            final last = pages.last;
            pages[pages.length - 1] = CapturedPage(
                filePath: last.filePath,
                thumbnailJpg: last.thumbnailJpg,
                time: last.time,
                ocrText: text);
          }
          statusMessage = 'OCR 完成';
        } else {
          ocrStatus = 'OCR 识别中 $progress%';
        }
      case IdCardEvent(:final ok):
        lastIdCard = ok ? ev : null;
        statusMessage = ok ? '身份证读取成功' : '身份证读取失败';
      case PdfEvent(:final ok, :final detail):
        capturing = false;
        statusMessage = detail;
        if (!ok) lastError = detail;
      case RawEvent(:final cmd, :final detail):
        debugPrint('raw event cmd=0x${cmd.toRadixString(16)} $detail');
      default:
        break;
    }
    notifyListeners();
  }

  static String _basename(String p) =>
      p.replaceAll('\\', '/').split('/').last;

  void _addPage(String path, Uint8List? imageBytes) {
    Uint8List thumb = imageBytes ?? Uint8List(0);
    pages.add(CapturedPage(
        filePath: path,
        thumbnailJpg: thumb,
        time: DateTime.now(),
        ocrText: ''));
    unawaited(_makeThumbnail(pages.length - 1, imageBytes));
    notifyListeners();
  }

  Future<void> _makeThumbnail(int index, Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) {
      // 尝试读文件
      final f = File(pages[index].filePath);
      if (await f.exists()) {
        bytes = await f.readAsBytes();
      } else {
        return;
      }
    }
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 220,
      );
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (data == null) return;
      final old = pages[index];
      pages[index] = CapturedPage(
          filePath: old.filePath,
          thumbnailJpg: data.buffer.asUint8List(),
          time: old.time,
          ocrText: old.ocrText);
      notifyListeners();
    } catch (e) {
      debugPrint('thumbnail error: $e');
    }
  }

  // ---------------- 拍摄 ----------------

  Future<void> capture() async {
    if (!connected || capturing) return;
    capturing = true;
    notifyListeners();
    try {
      _applyProcessingSettingsToBackend();
      final name = _nextFileName();
      final path =
          '$outputDir${Platform.pathSeparator}$name${outputFormat.ext}';
      final r = await _backend!.capture(savePath: path);
      capturing = false;
      lastCapturePath = r.savedPath.isEmpty ? path : r.savedPath;
      _addPage(lastCapturePath, r.imageBytes);
      statusMessage = '已保存: ${_basename(lastCapturePath)}';
      notifyListeners();
    } catch (e) {
      capturing = false;
      statusMessage = '拍照失败: $e';
      lastError = '$e';
      notifyListeners();
    }
  }

  /// 书籍模式拍摄（展平分左右页）
  Future<void> captureBook() async {
    if (!connected || capturing) return;
    capturing = true;
    notifyListeners();
    try {
      final base = _nextFileName();
      final left = '$outputDir${Platform.pathSeparator}${base}_L${outputFormat.ext}';
      final right = '$outputDir${Platform.pathSeparator}${base}_R${outputFormat.ext}';
      await _backend!.captureBook(left, right);
    } catch (e) {
      capturing = false;
      statusMessage = '书籍拍摄失败: $e';
      lastError = '$e';
      notifyListeners();
    }
  }

  String _nextFileName() {
    final now = DateTime.now();
    String ts() =>
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    switch (nameStyle) {
      case NameStyle.dateTime:
        return '$prefix${ts()}';
      case NameStyle.sequence:
        final s = '${sequence++}'.padLeft(4, '0');
        return '$prefix$s';
    }
  }

  // ---------------- 识别 / PDF ----------------

  Future<void> recognizeBarcode({required bool qrcode}) async {
    try {
      _backend!.recognizeBarcodeFromCamera(qrcode ? 1 : 0);
      statusMessage = '正在识别条码...';
    } catch (e) {
      lastError = '$e';
    }
    notifyListeners();
  }

  Future<void> readIdCard() async {
    if (!connected) return;
    try {
      statusMessage = '正在读取身份证...';
      notifyListeners();
      final name = _nextFileName();
      final path = '$outputDir${Platform.pathSeparator}${name}_id.jpg';
      final ev = await _backend!.readIdCard(path);
      if (ev.ok && ev.mergedJpg != null) {
        _addPage(path, ev.mergedJpg);
      }
      lastIdCard = ev.ok ? ev : null;
      statusMessage = ev.ok ? '身份证读取成功' : '身份证读取失败';
    } catch (e) {
      statusMessage = '读证失败: $e';
      lastError = '$e';
    }
    notifyListeners();
  }

  Future<void> ocrLastCapture() async {
    if (lastCapturePath.isEmpty) {
      statusMessage = '请先拍摄一张图片';
      notifyListeners();
      return;
    }
    try {
      statusMessage = 'OCR 识别中...';
      notifyListeners();
      final ev = await _backend!.ocrImage(lastCapturePath, ocrLanguage);
      statusMessage =
          ev.ok ? 'OCR 完成（${ev.text.length} 字）' : ev.errorLabel;
      lastError = ev.ok ? '' : ev.errorLabel;
      notifyListeners();
    } catch (e) {
      statusMessage = 'OCR 失败: $e';
      lastError = '$e';
      notifyListeners();
    }
  }

  Future<void> exportPdf() async {
    if (pages.isEmpty) {
      statusMessage = '没有可导出的页面';
      notifyListeners();
      return;
    }
    try {
      statusMessage = '正在生成 PDF...';
      notifyListeners();
      final paths = pages.map((p) => p.filePath).toList();
      await _backend!.addImagesToPdf(paths);
      final base = _nextFileName();
      final pdfPath = '$outputDir${Platform.pathSeparator}$base.pdf';
      await _backend!.combineToPdf(pdfPath);
      statusMessage = 'PDF 已生成: $pdfPath';
    } catch (e) {
      statusMessage = 'PDF 导出失败: $e';
      lastError = '$e';
    }
    notifyListeners();
  }

  Future<void> toggleAutoScan() async {
    try {
      if (autoScan) {
        await _backend!.stopWiseCapture();
        autoScan = false;
        statusMessage = '自动扫描已停止';
      } else {
        await _backend!.startWiseCapture(outputDir);
        autoScan = true;
        statusMessage = '自动扫描中（放纸后自动拍摄）';
      }
    } catch (e) {
      statusMessage = '自动扫描不可用: $e';
    }
    notifyListeners();
  }

  // ---------------- 参数变更入口 ----------------

  void setMode(ScanMode m) {
    mode = m;
    // 模式联动默认参数
    switch (m) {
      case ScanMode.book:
        flattenMode = FlattenMode.flatten;
      case ScanMode.document:
        flattenMode = FlattenMode.none;
      default:
        break;
    }
    _applyProcessingSettings();
    notifyListeners();
  }

  void setCutMode(CutMode m) {
    cutMode = m;
    _applyProcessingSettings();
    notifyListeners();
  }

  void setColorEffect(ColorEffect e) {
    colorEffect = e;
    _applyProcessingSettings();
    notifyListeners();
  }

  void setOutputFormat(OutputFormat f) {
    outputFormat = f;
    _applyProcessingSettings();
    notifyListeners();
  }

  void setNameStyle(NameStyle s) {
    nameStyle = s;
    _savePrefs();
    notifyListeners();
  }

  void setFlattenMode(FlattenMode m) {
    flattenMode = m;
    _applyProcessingSettings();
    notifyListeners();
  }

  void setOcrLanguage(OcrLanguage l) {
    ocrLanguage = l;
    _savePrefs();
    notifyListeners();
  }

  void setSmartEdge(bool v) {
    smartEdge = v;
    _applyProcessingSettings();
    notifyListeners();
  }

  void setRemoveBg(bool v) {
    removeBg = v;
    _applyProcessingSettings();
    notifyListeners();
  }

  void setJpgQuality(int v) {
    jpgQuality = v;
    _applyProcessingSettings();
    _savePrefs();
    notifyListeners();
  }

  void setPrefix(String v) {
    prefix = v;
    _savePrefs();
    notifyListeners();
  }

  Future<void> setOutputDir(String v) async {
    outputDir = v;
    final dir = Directory(v);
    if (!await dir.exists()) await dir.create(recursive: true);
    _savePrefs();
    notifyListeners();
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  void removePage(int index) {
    pages.removeAt(index);
    notifyListeners();
  }

  // ---------------- 视图操作转发 ----------------

  void zoomIn() => _backend?.zoomIn();
  void zoomOut() => _backend?.zoomOut();
  void fitToWindow() => _backend?.bestSize();
  void trueSize() => _backend?.trueSize();
  void rotateLeft() => _backend?.rotateLeft();
  void rotateRight() => _backend?.rotateRight();
  void manualFocus() => _backend?.manualFocus();

  void panDrag(int dx, int dy) {
    // 照厂商 demo：方向0=左/上, 1=右/下
    _backend?.moveOffset(
        dx.abs(), dy.abs(), dx < 0 ? 0 : 1, dy < 0 ? 0 : 1);
  }

  // ---------------- 持久化 ----------------

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      outputDir = p.getString('outputDir') ?? '';
      prefix = p.getString('prefix') ?? 'Pic_';
      jpgQuality = p.getInt('jpgQuality') ?? 85;
      nameStyle = NameStyle.values[p.getInt('nameStyle') ?? 0];
      colorEffect = ColorEffect.values[p.getInt('colorEffect') ?? 0];
      outputFormat = OutputFormat.values[p.getInt('outputFormat') ?? 0];
      smartEdge = p.getBool('smartEdge') ?? false;
      removeBg = p.getBool('removeBg') ?? false;
      sequence = p.getInt('sequence') ?? 1;
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('outputDir', outputDir);
      await p.setString('prefix', prefix);
      await p.setInt('jpgQuality', jpgQuality);
      await p.setInt('nameStyle', nameStyle.index);
      await p.setInt('colorEffect', colorEffect.index);
      await p.setInt('outputFormat', outputFormat.index);
      await p.setBool('smartEdge', smartEdge);
      await p.setBool('removeBg', removeBg);
      await p.setInt('sequence', sequence);
    } catch (_) {}
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _eventSub?.cancel();
    _backend?.disconnect();
    previewImage?.dispose();
    super.dispose();
  }
}
