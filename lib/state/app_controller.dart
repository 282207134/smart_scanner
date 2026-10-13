import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/km_server_backend.dart';
import '../backend/mac_avf_backend.dart';
import '../backend/mock_backend.dart';
import '../backend/scanner_backend.dart';
import '../core/document_exporter.dart';
import '../core/document_geometry.dart';
import '../core/document_vision.dart';
import '../core/auto_scan_detector.dart';
import '../core/models.dart';
import '../core/native_ocr.dart';
import '../core/scan_file_store.dart';

Uint8List _encodeRaster((Uint8List, OutputFormat, int) args) =>
    DocumentExporter.encodeImage(args.$1, args.$2, args.$3);

class AppController extends ChangeNotifier {
  ScannerBackend? _backend;
  StreamSubscription<PreviewFrame>? _frameSub;
  StreamSubscription<ScannerEvent>? _eventSub;
  bool _disposed = false, _testMode = false;
  bool connected = false, connecting = false, usingMock = false;
  String statusMessage = '未连接';
  List<ScannerDevice> devices = const [];
  int deviceIndex = 0;
  List<ScanResolution> resolutions = const [];
  ScanResolution? resolution;
  bool previewOpen = false;
  ScanMode mode = ScanMode.document;
  CutMode cutMode = CutMode.none;
  ColorEffect colorEffect = ColorEffect.native;
  OutputFormat outputFormat = OutputFormat.jpg;
  final Map<ScanMode, OutputFormat> _modeFormats = {};
  NameStyle nameStyle = NameStyle.dateTime;
  FlattenMode flattenMode = FlattenMode.none;
  OcrLanguage ocrLanguage = OcrLanguage.chineseEnglish;
  bool smartEdge = false, removeBg = false, autoScan = false, multiPage = false;
  bool mergeIdSides = false, qrcode = false;
  int jpgQuality = 85, sequence = 1;
  String prefix = 'Pic_', outputDir = '';
  ui.Image? previewImage;
  int canvasW = 640, canvasH = 480;
  Uint8List? _canvasRgb;
  bool _converting = false;
  double previewFps = 0;
  int _fpsCount = 0;
  final _fpsClock = Stopwatch()..start();
  final List<CapturedPage> pages = [];
  int selectedPage = -1;
  final Set<String> selectedPaths = {};
  bool capturing = false,
      exporting = false,
      recognizing = false,
      focusing = false;
  String lastCapturePath = '',
      lastExportPath = '',
      lastBarcode = '',
      lastOcrText = '',
      ocrStatus = '';
  IdCardEvent? lastIdCard;
  bool recording = false;
  RecordFormat recordFormat = RecordFormat.mp4;
  RecordSource recordSource = RecordSource.camera;
  String lastRecordPath = '';
  DateTime? recordStarted;
  Uint8List? signatureBytes, stampBytes, _idFront;
  double markSize = .2;
  int markCorner = 3;
  String? lastError;
  Timer? _canvasTimer;
  (int, int)? _pendingCanvasSize;
  Timer? _recordTimer;
  Timer? _autoTimer;
  AutoScanDetector? _autoDetector;
  final Stopwatch _autoClock = Stopwatch();
  AutoScanProgress autoProgress = const AutoScanProgress(AutoScanPhase.waiting);
  int autoDelaySeconds = 3;
  bool autoMode = false;
  List<DocumentRegion> detectedDocuments = [];
  DocumentRegion? manualRegion = DocumentRegion.inset;
  double bookSeam = .5;
  double previewImageX = 0,
      previewImageY = 0,
      previewImageWidth = 1,
      previewImageHeight = 1;
  bool _detecting = false;
  DateTime _lastDetection = DateTime.fromMillisecondsSinceEpoch(0);
  int _visionGeneration = 0;
  Future<void>? _opening;
  bool _openAgain = false;

  ScannerBackend get backend => _backend!;
  ScanFileStore get _files => ScanFileStore(outputDir);
  bool get busy => capturing || exporting || recognizing || focusing;
  bool get canCapture =>
      connected &&
      previewOpen &&
      !connecting &&
      _opening == null &&
      !busy &&
      !recording &&
      !autoScan;
  CapturedPage? get currentPage =>
      selectedPage >= 0 && selectedPage < pages.length
      ? pages[selectedPage]
      : null;
  (int, int) get canvasSize => (canvasW, canvasH);
  bool get supportsHighDensityPreview => _backend is MacAvfBackend;
  bool supportsResolution(ScanResolution size) =>
      resolutions.any((r) => r.width == size.width && r.height == size.height);
  List<OutputFormat> get availableFormats => switch (mode) {
    ScanMode.ocr => [OutputFormat.txt, OutputFormat.word, OutputFormat.excel],
    ScanMode.idCard => [OutputFormat.jpg, OutputFormat.png],
    ScanMode.contract => OutputFormat.values.take(5).toList(),
    ScanMode.barcode => [
      OutputFormat.jpg,
      OutputFormat.png,
      OutputFormat.imagePdf,
      OutputFormat.txtJpg,
    ],
    _ => OutputFormat.values.take(8).toList(),
  };
  List<NameStyle> get availableNameStyles => switch (mode) {
    ScanMode.book => [NameStyle.sequence, NameStyle.dateTime],
    ScanMode.idCard => [
      NameStyle.sequence,
      NameStyle.dateTime,
      NameStyle.idCardNum,
      NameStyle.custom,
    ],
    ScanMode.barcode => [
      NameStyle.barcode,
      NameStyle.sequence,
      NameStyle.dateTime,
    ],
    _ => [
      NameStyle.sequence,
      NameStyle.dateTime,
      NameStyle.custom,
      NameStyle.folderName,
    ],
  };
  List<ColorEffect> get availableColorEffects =>
      mode == ScanMode.idCard || mode == ScanMode.barcode
      ? ColorEffect.values.take(3).toList()
      : ColorEffect.values;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> init({
    bool forceMock = false,
    ScannerBackend? backendOverride,
    String? outputDirOverride,
  }) async {
    _testMode = backendOverride != null;
    if (!_testMode) await _loadPrefs();
    outputDir =
        outputDirOverride ??
        (outputDir.isEmpty ? await _defaultOutputDir() : outputDir);
    _attach(
      backendOverride ??
          (forceMock
              ? MockBackend()
              : Platform.isMacOS
              ? MacAvfBackend()
              : KmServerBackend()),
    );
  }

  void _attach(ScannerBackend b) {
    _backend = b;
    usingMock = b is MockBackend;
    _frameSub = b.frames.listen(_onFrame);
    _eventSub = b.events.listen(_onEvent);
  }

  Future<String> _defaultOutputDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}SmartScanner');
    await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> connect() async {
    if (connecting || busy || recording) return;
    connecting = true;
    statusMessage = '正在连接扫描仪…';
    notifyListeners();
    try {
      await backend.connect();
      connected = true;
      await refreshDevices();
    } catch (e) {
      connected = false;
      _error('连接失败：$e');
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> useDemo(bool enabled) async {
    if (busy || recording || autoScan) return;
    await _frameSub?.cancel();
    await _eventSub?.cancel();
    await _backend?.disconnect();
    connected = previewOpen = false;
    devices = [];
    resolutions = [];
    resolution = null;
    _attach(
      enabled
          ? MockBackend()
          : Platform.isMacOS
          ? MacAvfBackend()
          : KmServerBackend(),
    );
    connecting = false;
    await connect();
  }

  Future<void> refreshDevices() async {
    if (!connected || busy || recording || autoScan) return;
    devices = await backend.listDevices();
    if (devices.isEmpty) {
      previewOpen = false;
      resolution = null;
      resolutions = [];
      statusMessage = '未发现扫描仪，请检查 USB 连接后刷新设备';
    } else {
      if (!devices.any((d) => d.index == deviceIndex)) {
        deviceIndex = devices.first.index;
      }
      await refreshResolutions();
      await reopenPreview();
    }
    notifyListeners();
  }

  Future<void> refreshResolutions() async {
    final previous = resolution;
    resolutions =
        {for (final r in await backend.listResolutions(deviceIndex)) r.label: r}
            .values
            .toList()
          ..sort((a, b) {
            final pixels = (b.width * b.height).compareTo(a.width * a.height);
            return pixels != 0 ? pixels : b.width.compareTo(a.width);
          });
    if (resolutions.isEmpty) {
      resolution = null;
      return;
    }
    resolution = resolutions.firstWhere(
      (r) => r.label == previous?.label,
      orElse: () => resolutions.firstWhere(
        (r) => r.width == 2592 && r.height == 1944,
        orElse: () => resolutions.first,
      ),
    );
  }

  Future<void> selectDevice(int index) async {
    if (busy ||
        connecting ||
        recording ||
        autoScan ||
        !devices.any((d) => d.index == index)) {
      return;
    }
    connecting = true;
    notifyListeners();
    try {
      deviceIndex = index;
      await refreshResolutions();
      await reopenPreview();
    } catch (e) {
      _error('切换设备失败：$e');
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> selectResolution(ScanResolution r) async {
    if (busy || connecting || recording || autoScan) return;
    if (!supportsResolution(r)) {
      _error('当前设备不支持 ${r.label}');
      return;
    }
    _resetGeometry();
    resolution = r;
    await reopenPreview();
  }

  Future<void> reopenPreview() async {
    if (!connected || resolution == null || _disposed) return;
    if (busy || recording || autoScan) {
      _openAgain = true;
      return;
    }
    if (_opening != null) {
      _openAgain = true;
      return _opening;
    }
    final done = Completer<void>();
    _opening = done.future;
    try {
      do {
        _openAgain = false;
        final r = resolution!;
        final wasOpen = previewOpen;
        previewOpen = false;
        notifyListeners();
        if (wasOpen) await backend.close();
        _canvasRgb = Uint8List(canvasW * canvasH * 3);
        await backend.open(
          deviceIndex: deviceIndex,
          canvasW: canvasW,
          canvasH: canvasH,
          captureW: r.width,
          captureH: r.height,
        );
        previewOpen = true;
        _applySettings();
        statusMessage = usingMock ? '演示画面 · 不代表真实扫描仪' : '预览中 ${r.label}';
      } while (_openAgain && !_disposed && !busy && !recording);
    } catch (e) {
      _error('打开摄像头失败：$e');
    } finally {
      _opening = null;
      done.complete();
      notifyListeners();
    }
  }

  Future<void> setCanvasSize(int w, int h) async {
    if (_disposed) return;
    final nw = (w ~/ 10 * 10).clamp(
          320,
          supportsHighDensityPreview ? 3840 : 1920,
        ),
        nh = (h ~/ 10 * 10).clamp(
          240,
          supportsHighDensityPreview ? 2160 : 1440,
        );
    if (nw == canvasW && nh == canvasH) {
      _canvasTimer?.cancel();
      _pendingCanvasSize = null;
      return;
    }
    // Frame notifications rebuild the preview. Repeated requests for the same
    // size must not keep postponing the resize until the camera stops streaming.
    if (_pendingCanvasSize == (nw, nh)) return;
    _canvasTimer?.cancel();
    _pendingCanvasSize = (nw, nh);
    _canvasTimer = Timer(const Duration(milliseconds: 350), () {
      _pendingCanvasSize = null;
      _canvasTimer = null;
      if (_disposed) return;
      if (busy || recording || autoScan) return;
      canvasW = nw;
      canvasH = nh;
      unawaited(reopenPreview());
    });
  }

  void _applySettings() {
    if (!connected) return;
    backend.setFileType(0);
    backend.setJpgQuality(jpgQuality);
    backend.setColorMode(0);
    backend.setDeleteBlackEdge(0);
    backend.setDeleteBgColor(0);
    // Crop/flatten is applied to the full sensor image in our shared pipeline.
    // Keep preview geometry unchanged so guide coordinates remain meaningful.
    backend.setCutMode(0);
    backend.setZpMode(0);
  }

  void _onFrame(PreviewFrame f) {
    if (_disposed ||
        f.x < 0 ||
        f.y < 0 ||
        f.width <= 0 ||
        f.height <= 0 ||
        f.x + f.width > canvasW ||
        f.y + f.height > canvasH ||
        f.rgb.length != f.width * f.height * 3) {
      return;
    }
    final buf = _canvasRgb ??= Uint8List(canvasW * canvasH * 3);
    if (buf.length != canvasW * canvasH * 3) return;
    buf.fillRange(0, buf.length, 0);
    previewImageX = f.x / canvasW;
    previewImageY = f.y / canvasH;
    previewImageWidth = f.width / canvasW;
    previewImageHeight = f.height / canvasH;
    if (!busy && !recording) {
      if (autoScan) _feedAuto(f);
      if (cutMode != CutMode.none ||
          smartEdge ||
          mode == ScanMode.book ||
          autoScan) {
        unawaited(_detectDocuments(f));
      }
    }
    for (var row = 0; row < f.height; row++) {
      final dst = ((f.y + row) * canvasW + f.x) * 3;
      buf.setRange(dst, dst + f.width * 3, f.rgb, row * f.width * 3);
    }
    unawaited(_convertToImage(buf, canvasW, canvasH));
  }

  Future<void> _detectDocuments(PreviewFrame f) async {
    if (_detecting ||
        DateTime.now().difference(_lastDetection).inMilliseconds < 350) {
      return;
    }
    _detecting = true;
    _lastDetection = DateTime.now();
    final generation = _visionGeneration;
    try {
      final regions = await compute(DocumentVision.detectRgb, (
        f.rgb,
        f.width,
        f.height,
      ));
      if (_disposed || generation != _visionGeneration) return;
      detectedDocuments = regions;
      notifyListeners();
    } catch (e) {
      debugPrint('边界检测：$e');
    } finally {
      _detecting = false;
    }
  }

  bool get _autoEligible =>
      cutMode == CutMode.none && mode != ScanMode.book ||
      cutMode == CutMode.manual && manualRegion?.valid == true ||
      detectedDocuments.isNotEmpty;

  void _feedAuto(PreviewFrame frame) {
    final detector = _autoDetector;
    if (detector == null) return;
    autoProgress = detector.feed(
      frame,
      _autoClock.elapsed,
      eligible: _autoEligible,
    );
    _checkAutoCapture();
  }

  void _checkAutoCapture() {
    if (autoProgress.phase == AutoScanPhase.capture && autoScan && !busy) {
      unawaited(capture(automatic: true));
    }
  }

  Future<void> _convertToImage(Uint8List rgb, int w, int h) async {
    if (_converting || _disposed) return;
    _converting = true;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      final rgba = Uint8List(w * h * 4);
      for (int i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
        rgba[j] = rgb[i];
        rgba[j + 1] = rgb[i + 1];
        rgba[j + 2] = rgb[i + 2];
        rgba[j + 3] = 255;
      }
      buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      if (_disposed || w != canvasW || h != canvasH) {
        frame.image.dispose();
        return;
      }
      final old = previewImage;
      previewImage = frame.image;
      if (old != null) Timer(const Duration(milliseconds: 120), old.dispose);
      _fpsCount++;
      if (_fpsClock.elapsedMilliseconds >= 2000) {
        previewFps = _fpsCount * 1000 / _fpsClock.elapsedMilliseconds;
        _fpsCount = 0;
        _fpsClock.reset();
      }
      notifyListeners();
    } catch (e) {
      debugPrint('预览帧：$e');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      _converting = false;
    }
  }

  void _onEvent(ScannerEvent ev) {
    if (_disposed) return;
    switch (ev) {
      case ConnectionEvent(:final connected, :final detail):
        this.connected = connected;
        if (!connected) {
          previewOpen = false;
          _stopLocalAuto();
        }
        statusMessage = detail;
      case CaptureEvent(:final ok, :final path, :final imageBytes):
        if (ok && !capturing && path.isNotEmpty) {
          unawaited(_addPage(path, imageBytes));
        }
      case WiseCaptureEvent(
        :final done,
        :final steady,
        :final path,
        :final imageBytes,
      ):
        if (done && _autoDetector == null) {
          autoScan = false;
          statusMessage = '自动扫描已停止';
        } else if (_autoDetector == null && steady && path.isNotEmpty) {
          unawaited(_addPage(path, imageBytes));
          statusMessage = '自动拍摄：${basename(path)}';
        }
      case BarcodeEvent(:final ok, :final content):
        lastBarcode = ok ? content : '';
        statusMessage = ok ? '识别结果：$content' : '未识别到条码，请调整位置或光线';
      case OcrEvent(:final flag, :final progress):
        if (flag == 1) ocrStatus = 'OCR 识别中 $progress%';
      case IdCardEvent(:final ok):
        lastIdCard = ok ? ev : null;
      default:
        break;
    }
    notifyListeners();
  }

  static String basename(String path) => ScanFileStore.basename(path);
  void _error(String message) {
    lastError = message;
    statusMessage = message;
    notifyListeners();
  }

  void clearError() {
    lastError = null;
  }

  Future<void> _addPage(
    String path,
    Uint8List? bytes, {
    String? sourcePath,
    String text = '',
  }) async {
    if (_disposed || pages.any((p) => p.filePath == path)) return;
    final page = CapturedPage(
      filePath: path,
      sourcePath: sourcePath,
      thumbnailJpg: bytes ?? Uint8List(0),
      time: DateTime.now(),
      ocrText: text,
    );
    pages.add(page);
    _activatePage(pages.length - 1);
    unawaited(_makeThumbnail(page, bytes));
  }

  Future<void> _makeThumbnail(CapturedPage page, Uint8List? bytes) async {
    ui.Codec? codec;
    try {
      bytes ??= await File(page.sourcePath).readAsBytes();
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 240);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      final index = pages.indexWhere(
        (p) => p.filePath == page.filePath && p.sourcePath == page.sourcePath,
      );
      if (data != null && index >= 0 && !_disposed) {
        final current = pages[index];
        pages[index] = CapturedPage(
          filePath: page.filePath,
          sourcePath: page.sourcePath,
          thumbnailJpg: data.buffer.asUint8List(),
          time: page.time,
          ocrText: current.ocrText,
        );
      }
    } catch (e) {
      debugPrint('缩略图：$e');
    } finally {
      codec?.dispose();
      notifyListeners();
    }
  }

  String _nextFileName([String suffix = '']) {
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}_${now.millisecond.toString().padLeft(3, '0')}';
    final value = switch (nameStyle) {
      NameStyle.sequence => '$prefix${(sequence++).toString().padLeft(4, '0')}',
      NameStyle.folderName =>
        '${basename(outputDir.replaceAll(RegExp(r'[\\/]+$'), ''))}_$stamp',
      NameStyle.custom => prefix.isEmpty ? stamp : prefix,
      NameStyle.idCardNum =>
        '$prefix${lastIdCard?.cardNum.isNotEmpty == true ? lastIdCard!.cardNum : stamp}',
      NameStyle.barcode =>
        '$prefix${lastBarcode.isEmpty ? stamp : lastBarcode}',
      _ => '$prefix$stamp',
    };
    unawaited(_savePrefs());
    return '${ScanFileStore.sanitizeName(value, fallback: 'Scan_$stamp')}$suffix';
  }

  Future<String> _recognize(String imagePath) async => usingMock
      ? (await backend.ocrImage(imagePath, ocrLanguage)).text
      : NativeOcr.recognize(imagePath, ocrLanguage);
  Future<void> _saveCapture(Uint8List bytes, String base) async {
    if (mode == ScanMode.idCard && mergeIdSides) {
      if (_idFront == null) {
        _idFront = bytes;
        statusMessage = '正面已拍摄，请翻面后拍摄背面';
        return;
      }
      bytes = DocumentExporter.mergeCards(_idFront!, bytes);
      _idFront = null;
    }
    if (mode == ScanMode.contract) {
      if (signatureBytes != null) {
        bytes = DocumentExporter.addMark(
          bytes,
          signatureBytes!,
          markSize,
          markCorner,
        );
      }
      if (stampBytes != null) {
        bytes = DocumentExporter.addMark(
          bytes,
          stampBytes!,
          markSize,
          markCorner == 3 ? 2 : 3,
        );
      }
    }
    final source = await _files.uniquePath(base, '.jpg', source: true);
    await DocumentExporter.save(
      source,
      await compute(_encodeRaster, (bytes, OutputFormat.jpg, 95)),
    );
    final f = outputFormat;
    String text = '';
    final path = await _files.uniquePath(base, multiPage ? '.jpg' : f.ext);
    if (multiPage ||
        [
          OutputFormat.jpg,
          OutputFormat.png,
          OutputFormat.bmp,
          OutputFormat.tif,
          OutputFormat.txtJpg,
        ].contains(f)) {
      await DocumentExporter.save(
        path,
        await compute(_encodeRaster, (
          bytes,
          multiPage ? OutputFormat.jpg : f,
          jpgQuality,
        )),
      );
      if (f == OutputFormat.txtJpg && !multiPage) {
        await File('$path.txt').writeAsString(lastBarcode, flush: true);
      }
    } else if (f == OutputFormat.imagePdf) {
      await DocumentExporter.save(
        path,
        await compute(DocumentExporter.imagePdf, [bytes]),
      );
    } else {
      text = await _recognize(source);
      if (text.trim().isEmpty) throw StateError('没有识别到文字；原图已保存在 $source');
      await DocumentExporter.save(
        path,
        f == OutputFormat.txt
            ? utf8.encode(text)
            : DocumentExporter.office(text, f),
      );
      lastOcrText = text;
    }
    await _addPage(path, bytes, sourcePath: source, text: text);
    statusMessage = multiPage
        ? '已加入多页文档 · ${pages.length} 页'
        : '已保存：${basename(path)}';
  }

  Future<void> capture({bool automatic = false}) => _capture(
    automatic: automatic,
    book: mode == ScanMode.book && flattenMode != FlattenMode.none,
  );

  Future<void> captureBook({bool automatic = false}) =>
      _capture(automatic: automatic, book: true);

  Future<void> _capture({required bool automatic, required bool book}) async {
    if (automatic
        ? (!connected ||
              !previewOpen ||
              connecting ||
              _opening != null ||
              busy ||
              recording ||
              !autoScan)
        : !canCapture) {
      return;
    }
    capturing = true;
    notifyListeners();
    try {
      _applySettings();
      final base = _nextFileName();
      final rawPath = await _files.uniquePath(
        '${base}_original',
        '.jpg',
        source: true,
      );
      final raw = await ScanFileStore.readCapture(
        await backend.captureRaw(savePath: rawPath),
      );
      // Backends may return bytes without writing the requested file.
      if (!await File(rawPath).exists()) {
        await DocumentExporter.save(rawPath, raw);
      }
      final request = VisionRequest(
        raw,
        cut: cutMode,
        effect: colorEffect,
        manual: manualRegion,
        smartEdge: smartEdge,
        removeBackground: removeBg,
      );
      final output = book
          ? await compute(DocumentVision.flattenBook, (
              request,
              flattenMode,
              bookSeam,
            ))
          : await compute(DocumentVision.process, request);
      for (var i = 0; i < output.images.length; i++) {
        final suffix = output.images.length == 1
            ? ''
            : book
            ? '_${i == 0 ? 'L' : 'R'}'
            : '_${(i + 1).toString().padLeft(2, '0')}';
        await _saveCapture(output.images[i], '$base$suffix');
      }
      if (book) {
        statusMessage = '书籍拍摄完成 · ${output.images.length} 页';
      } else if (output.images.length > 1) {
        statusMessage = '已分别保存 ${output.images.length} 个文档';
      }
      if (automatic && autoScan) {
        _autoDetector?.markCaptured(now: _autoClock.elapsed);
        autoProgress = _autoDetector!.progress;
      }
    } catch (e) {
      if (automatic) _stopLocalAuto();
      _error('${book ? '书籍拍摄' : '拍照'}失败：$e');
    } finally {
      capturing = false;
      notifyListeners();
      if (_openAgain) unawaited(reopenPreview());
    }
  }

  Future<void> recognizeBarcode({required bool qrcode}) async {
    if (!connected || !previewOpen) return;
    this.qrcode = qrcode;
    lastBarcode = '';
    try {
      backend.recognizeBarcodeFromCamera(qrcode ? 1 : 0);
      statusMessage = '正在识别…';
    } catch (e) {
      _error('条码识别失败：$e');
    }
    notifyListeners();
  }

  Future<void> readIdCard() async {
    if (!connected || busy) return;
    recognizing = true;
    notifyListeners();
    try {
      final path = await _files.uniquePath(_nextFileName('_id'), '.jpg');
      final ev = await backend.readIdCard(path);
      if (!ev.ok) throw StateError('未读取到证件，请确认已连接身份证读卡器');
      lastIdCard = ev;
      if (ev.mergedJpg != null) {
        await DocumentExporter.save(path, ev.mergedJpg!);
        await _addPage(path, ev.mergedJpg);
      }
      statusMessage = '身份证读取成功';
    } catch (e) {
      _error('读证失败：$e');
    } finally {
      recognizing = false;
      notifyListeners();
    }
  }

  Future<void> ocrLastCapture() async {
    final page = currentPage;
    if (page == null || busy) {
      if (page == null) _error('请先拍摄或导入图片');
      return;
    }
    recognizing = true;
    ocrStatus = '正在识别文字…';
    notifyListeners();
    try {
      final text = await _recognize(page.sourcePath);
      if (text.trim().isEmpty) throw StateError('没有识别到文字，请检查清晰度和识别语言');
      lastOcrText = text;
      final index = pages.indexWhere(
        (p) => p.filePath == page.filePath && p.sourcePath == page.sourcePath,
      );
      if (index >= 0) {
        pages[index] = CapturedPage(
          filePath: page.filePath,
          sourcePath: page.sourcePath,
          thumbnailJpg: pages[index].thumbnailJpg,
          time: page.time,
          ocrText: text,
        );
      }
      statusMessage = 'OCR 完成 · ${text.length} 字';
    } catch (e) {
      _error('OCR 失败：$e');
    } finally {
      ocrStatus = '';
      recognizing = false;
      notifyListeners();
    }
  }

  Future<void> exportOcr() async {
    if (lastOcrText.isEmpty || busy) return;
    exporting = true;
    notifyListeners();
    try {
      final f = [OutputFormat.word, OutputFormat.excel].contains(outputFormat)
          ? outputFormat
          : OutputFormat.txt;
      final path = await _files.uniquePath(_nextFileName('_OCR'), f.ext);
      await DocumentExporter.save(
        path,
        f == OutputFormat.txt
            ? utf8.encode(lastOcrText)
            : DocumentExporter.office(lastOcrText, f),
      );
      lastExportPath = path;
      statusMessage = '识别结果已导出：${basename(path)}';
    } catch (e) {
      _error('识别结果导出失败：$e');
    } finally {
      exporting = false;
      notifyListeners();
    }
  }

  Future<void> exportPdf({String? destination}) async {
    if (busy) return;
    final chosen = pages
        .where(
          (p) => selectedPaths.isEmpty || selectedPaths.contains(p.filePath),
        )
        .toList();
    if (chosen.isEmpty) {
      _error('没有可导出的页面');
      return;
    }
    exporting = true;
    statusMessage = '正在生成 ${chosen.length} 页 PDF…';
    notifyListeners();
    try {
      final images = <Uint8List>[];
      for (final p in chosen) {
        images.add(await File(p.sourcePath).readAsBytes());
      }
      final path =
          destination ?? await _files.uniquePath(_nextFileName('_合并'), '.pdf');
      await DocumentExporter.save(
        path,
        await compute(DocumentExporter.imagePdf, images),
      );
      lastExportPath = path;
      statusMessage = 'PDF 已生成 · ${chosen.length} 页 · ${basename(path)}';
    } catch (e) {
      _error('PDF 导出失败：$e');
    } finally {
      exporting = false;
      notifyListeners();
    }
  }

  Future<void> importPages(List<String> paths) async {
    if (busy || paths.isEmpty) return;
    exporting = true;
    notifyListeners();
    var imported = 0, skipped = 0;
    final failed = <String>[];
    String key(String path) {
      final absolute = File(path).absolute.path.replaceAll('\\', '/');
      return Platform.isWindows ? absolute.toLowerCase() : absolute;
    }

    final existing = pages.map((p) => key(p.filePath)).toSet();
    try {
      for (final path in paths) {
        if (existing.contains(key(path))) {
          skipped++;
          continue;
        }
        try {
          final bytes = await File(path).readAsBytes();
          // Normalize for Flutter, native OCR and PDF (including TIFF/BMP).
          final normalized = await compute(_encodeRaster, (
            bytes,
            OutputFormat.png,
            95,
          ));
          final source = await _files.uniquePath(
            '${basename(path)}_import',
            '.png',
            source: true,
          );
          await DocumentExporter.save(source, normalized);
          await _addPage(path, normalized, sourcePath: source);
          existing.add(key(path));
          imported++;
        } catch (e) {
          failed.add(basename(path));
          debugPrint('导入 ${basename(path)}：$e');
        }
      }
      final summary =
          '已导入 $imported 张图片${skipped == 0 ? '' : '，跳过 $skipped 张已导入图片'}';
      if (failed.isEmpty) {
        statusMessage = summary;
      } else {
        _error('$summary；无法导入 ${failed.length} 张：${failed.join('、')}');
      }
    } finally {
      exporting = false;
      notifyListeners();
    }
  }

  Future<void> toggleAutoScan() async {
    if (autoScan) {
      _stopLocalAuto();
      statusMessage = '自动扫描已停止';
      notifyListeners();
      return;
    }
    if (!connected || !previewOpen || busy || recording) return;
    try {
      if (mode == ScanMode.document ||
          mode == ScanMode.book ||
          mode == ScanMode.barcode) {
        _applySettings();
        backend.bestSize();
        _autoDetector = AutoScanDetector(
          delay: Duration(seconds: autoDelaySeconds),
        );
        _autoClock
          ..reset()
          ..start();
        autoScan = true;
        autoProgress = const AutoScanProgress(AutoScanPhase.waiting);
        _autoTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (!autoScan || busy || _disposed) return;
          autoProgress = _autoDetector!.tick(_autoClock.elapsed);
          _checkAutoCapture();
          notifyListeners();
        });
        statusMessage = '自动扫描中 · 画面静止后倒计时 $autoDelaySeconds 秒';
      } else {
        throw UnsupportedError('此模式请使用手动拍摄');
      }
    } catch (e) {
      _error('自动扫描无法启动：$e');
    }
    notifyListeners();
  }

  void _stopLocalAuto() {
    autoScan = false;
    _autoTimer?.cancel();
    _autoTimer = null;
    _autoDetector = null;
    _autoClock.stop();
    autoProgress = const AutoScanProgress(AutoScanPhase.waiting);
  }

  void setAutoDelay(int value) {
    if (!autoScan) {
      autoDelaySeconds = value.clamp(1, 10);
      _changed();
    }
  }

  void setAutoMode(bool value) {
    if (!busy && !autoScan && !recording) {
      autoMode = value;
      _changed();
    }
  }

  void setManualCorner(int index, ScanPoint point) {
    if (busy || recording || autoScan || cutMode != CutMode.manual) return;
    final next = (manualRegion ?? DocumentRegion.inset).replaceCorner(
      index,
      point,
    );
    if (next.valid) {
      manualRegion = next;
      notifyListeners();
    }
  }

  void resetManualRegion() {
    if (busy || recording || autoScan) return;
    manualRegion = detectedDocuments.isNotEmpty
        ? detectedDocuments.reduce((a, b) => a.area > b.area ? a : b)
        : DocumentRegion.inset;
    notifyListeners();
  }

  void setBookSeam(double value) {
    if (!busy && !recording && !autoScan) {
      bookSeam = value.clamp(.15, .85);
      notifyListeners();
    }
  }

  Future<void> openFile(String path, {bool reveal = false}) async {
    try {
      if (!await File(path).exists() && !await Directory(path).exists()) {
        throw StateError('文件不存在：$path');
      }
      if (Platform.isWindows) {
        await Process.run('explorer.exe', reveal ? ['/select,$path'] : [path]);
      } else if (Platform.isMacOS) {
        await Process.run('/usr/bin/open', reveal ? ['-R', path] : [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      _error('打开文件失败：$e');
    }
  }

  void selectPage(int index) {
    if (busy || index < 0 || index >= pages.length) return;
    _activatePage(index);
  }

  void _activatePage(int index) {
    selectedPage = index;
    lastCapturePath = pages[index].sourcePath;
    lastOcrText = pages[index].ocrText;
    notifyListeners();
  }

  void toggleSelected(String path) {
    if (!selectedPaths.add(path)) selectedPaths.remove(path);
    notifyListeners();
  }

  void removePage(int index) {
    if (busy || index < 0 || index >= pages.length) return;
    selectedPaths.remove(pages[index].filePath);
    pages.removeAt(index);
    selectedPage = pages.isEmpty ? -1 : index.clamp(0, pages.length - 1);
    lastCapturePath = currentPage?.sourcePath ?? '';
    lastOcrText = currentPage?.ocrText ?? '';
    notifyListeners();
  }

  void movePage(int index, int delta) {
    final next = index + delta;
    if (busy ||
        index < 0 ||
        next < 0 ||
        index >= pages.length ||
        next >= pages.length) {
      return;
    }
    final page = pages.removeAt(index);
    pages.insert(next, page);
    selectPage(next);
  }

  void setMode(ScanMode m) {
    if (busy || recording || autoScan) return;
    if (m == mode) return;
    _modeFormats[mode] = outputFormat;
    mode = m;
    if (m != ScanMode.document && cutMode == CutMode.multiImg) {
      cutMode = CutMode.auto;
    }
    if (m == ScanMode.book) cutMode = CutMode.none;
    if (m != ScanMode.document && m != ScanMode.book && m != ScanMode.barcode) {
      autoMode = false;
    }
    outputFormat =
        _modeFormats[m] ??
        (m == ScanMode.ocr ? OutputFormat.txt : OutputFormat.jpg);
    _idFront = null;
    flattenMode = FlattenMode.none;
    if (!availableColorEffects.contains(colorEffect)) {
      colorEffect = availableColorEffects.first;
    }
    if (!availableFormats.contains(outputFormat)) {
      outputFormat = availableFormats.first;
    }
    if (!availableNameStyles.contains(nameStyle)) {
      nameStyle = availableNameStyles.first;
    }
    if (m != ScanMode.document && m != ScanMode.book) multiPage = false;
    _changed();
  }

  void _changed() {
    try {
      _applySettings();
    } catch (e) {
      _error('$e');
    }
    unawaited(_savePrefs());
    notifyListeners();
  }

  void setCutMode(CutMode v) {
    cutMode = v;
    if (v == CutMode.manual) {
      resetManualRegion();
    }
    if (v != CutMode.none) fitToWindow();
    _visionGeneration++;
    _changed();
  }

  void setColorEffect(ColorEffect v) {
    colorEffect = v;
    _changed();
  }

  void setOutputFormat(OutputFormat v) {
    outputFormat = v;
    if (v != OutputFormat.imagePdf) multiPage = false;
    _changed();
  }

  void setNameStyle(NameStyle v) {
    nameStyle = v;
    _changed();
  }

  void setFlattenMode(FlattenMode v) {
    flattenMode = v;
    _changed();
  }

  void setOcrLanguage(OcrLanguage v) {
    ocrLanguage = v;
    _changed();
  }

  void setRecordFormat(RecordFormat v) {
    recordFormat = v;
    _changed();
  }

  void setRecordSource(RecordSource v) {
    recordSource = v;
    _changed();
  }

  void setSmartEdge(bool v) {
    smartEdge = v;
    _changed();
  }

  void setRemoveBg(bool v) {
    removeBg = v;
    _changed();
  }

  void setJpgQuality(int v) {
    jpgQuality = v.clamp(30, 100);
    _changed();
  }

  void setPrefix(String v) {
    prefix = v;
    unawaited(_savePrefs());
  }

  void setMultiPage(bool v) {
    multiPage = v;
    if (v) outputFormat = OutputFormat.imagePdf;
    _changed();
  }

  void setMergeIdSides(bool v) {
    mergeIdSides = v;
    _idFront = null;
    notifyListeners();
  }

  void setMark(Uint8List? bytes, {required bool stamp}) {
    if (stamp) {
      stampBytes = bytes;
    } else {
      signatureBytes = bytes;
    }
    notifyListeners();
  }

  Future<void> setOutputDir(String v) async {
    try {
      if (Platform.isMacOS && !_testMode) {
        final bookmark = await NativeOcr.channel.invokeMethod<Uint8List>(
          'bookmarkFolder',
          {'path': v},
        );
        if (bookmark == null) throw StateError('无法保存目录授权');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('outputDirBookmark', base64Encode(bookmark));
      }
      await Directory(v).create(recursive: true);
      outputDir = v;
      await _savePrefs();
      notifyListeners();
    } catch (e) {
      _error('保存目录不可用：$e');
    }
  }

  Future<void> startRecord() async {
    if (!canCapture) return;
    capturing = true;
    notifyListeners();
    try {
      final path = await _files.uniquePath(_nextFileName(), recordFormat.ext);
      await backend.startRecord(
        path,
        recordFormat.serverIndex,
        source: recordSource,
      );
      recording = true;
      recordStarted = DateTime.now();
      lastRecordPath = path;
      statusMessage = '正在录制${recordSource.label}画面…';
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final elapsed = DateTime.now().difference(recordStarted!).inSeconds;
        statusMessage =
            '正在录制${recordSource.label} · ${(elapsed ~/ 60).toString().padLeft(2, '0')}:${(elapsed % 60).toString().padLeft(2, '0')}';
        notifyListeners();
      });
    } catch (e) {
      _error('录制失败：$e');
    } finally {
      capturing = false;
    }
    notifyListeners();
  }

  Future<void> stopRecord() async {
    if (!recording || busy) return;
    _recordTimer?.cancel();
    exporting = true;
    notifyListeners();
    try {
      await backend.stopRecord();
      lastExportPath = lastRecordPath;
      statusMessage = '视频已保存：${basename(lastRecordPath)}';
    } catch (e) {
      _error('保存视频失败：$e');
    } finally {
      recording = false;
      exporting = false;
      notifyListeners();
      if (_openAgain) unawaited(reopenPreview());
    }
  }

  void _view(void Function(ScannerBackend) action) {
    if (!connected || !previewOpen || busy || recording || autoScan) return;
    try {
      action(backend);
    } catch (e) {
      _error('$e');
    }
  }

  void zoomIn() {
    if (cutMode == CutMode.none && mode != ScanMode.book) {
      _view((b) => b.zoomIn());
    }
  }

  void zoomOut() {
    if (cutMode == CutMode.none && mode != ScanMode.book) {
      _view((b) => b.zoomOut());
    }
  }

  void fitToWindow() => _view((b) => b.bestSize());
  void trueSize() {
    if (cutMode == CutMode.none && mode != ScanMode.book) {
      _view((b) => b.trueSize());
    }
  }

  void rotateLeft() {
    if (!connected || !previewOpen || busy || recording || autoScan) return;
    _resetGeometry();
    _view((b) => b.rotateLeft());
  }

  void rotateRight() {
    if (!connected || !previewOpen || busy || recording || autoScan) return;
    _resetGeometry();
    _view((b) => b.rotateRight());
  }

  void _resetGeometry() {
    _visionGeneration++;
    detectedDocuments = [];
    manualRegion = DocumentRegion.inset;
  }

  Future<void> manualFocus() async {
    if (_disposed || !canCapture) return;
    focusing = true;
    lastError = null;
    statusMessage = '正在重新对焦…';
    notifyListeners();
    try {
      await backend.manualFocus();
      if (!_disposed) statusMessage = '已触发重新对焦，请等待画面稳定';
    } catch (e) {
      if (!_disposed) {
        final detail = e is PlatformException ? e.message ?? e.code : '$e';
        _error('对焦失败：$detail');
      }
    } finally {
      focusing = false;
      notifyListeners();
      if (_openAgain && !_disposed) unawaited(reopenPreview());
    }
  }

  void setCutRect(int x, int y, int w, int h) {
    if (busy || recording || autoScan) return;
    if (w <= 0 || h <= 0) {
      resetManualRegion();
      return;
    }
    double px(double n) => (n / canvasW - previewImageX) / previewImageWidth;
    double py(double n) => (n / canvasH - previewImageY) / previewImageHeight;
    final next = DocumentRegion([
      ScanPoint(px(x.toDouble()), py(y.toDouble())).clamp(),
      ScanPoint(px((x + w).toDouble()), py(y.toDouble())).clamp(),
      ScanPoint(px((x + w).toDouble()), py((y + h).toDouble())).clamp(),
      ScanPoint(px(x.toDouble()), py((y + h).toDouble())).clamp(),
    ]);
    if (next.valid) {
      manualRegion = next;
      notifyListeners();
    }
  }

  void panDrag(int dx, int dy) => _view(
    (b) => b.moveOffset(dx.abs(), dy.abs(), dx < 0 ? 0 : 1, dy < 0 ? 0 : 1),
  );
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    outputDir = p.getString('outputDir') ?? '';
    if (Platform.isMacOS && p.containsKey('outputDirBookmark')) {
      try {
        final restored = await NativeOcr.channel
            .invokeMapMethod<String, dynamic>('restoreFolder', {
              'bookmark': base64Decode(p.getString('outputDirBookmark')!),
            });
        outputDir = restored?['path'] as String? ?? '';
        if (restored?['bookmark'] case final Uint8List bytes) {
          await p.setString('outputDirBookmark', base64Encode(bytes));
        }
      } catch (_) {
        outputDir = '';
        statusMessage = '保存目录授权失效，请重新选择目录';
      }
    }
    prefix = p.getString('prefix') ?? 'Pic_';
    jpgQuality = (p.getInt('jpgQuality') ?? 85).clamp(30, 100);
    autoDelaySeconds = (p.getInt('autoDelaySeconds') ?? 3).clamp(1, 10);
    nameStyle =
        NameStyle.values[(p.getInt('nameStyle') ?? 1).clamp(
          0,
          NameStyle.values.length - 1,
        )];
    colorEffect =
        ColorEffect.values[(p.getInt('colorEffect') ?? 0).clamp(
          0,
          ColorEffect.values.length - 1,
        )];
    outputFormat =
        OutputFormat.values[(p.getInt('outputFormat') ?? 0).clamp(
          0,
          OutputFormat.values.length - 1,
        )];
    cutMode = CutMode
        .values[(p.getInt('cutMode') ?? 0).clamp(0, CutMode.values.length - 1)];
    ocrLanguage =
        OcrLanguage.values[(p.getInt('ocrLanguage') ?? 0).clamp(
          0,
          OcrLanguage.values.length - 1,
        )];
    smartEdge = p.getBool('smartEdge') ?? false;
    recordFormat =
        RecordFormat.values[(p.getInt('recordFormat') ?? 0).clamp(0, 2)];
    recordSource =
        RecordSource.values[(p.getInt('recordSource') ?? 1).clamp(0, 1)];
    removeBg = p.getBool('removeBg') ?? false;
    sequence = p.getInt('sequence') ?? 1;
    if (!availableFormats.contains(outputFormat)) {
      outputFormat = OutputFormat.jpg;
    }
  }

  Future<void> _savePrefs() async {
    if (_testMode) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('outputDir', outputDir);
    await p.setString('prefix', prefix);
    await p.setInt('jpgQuality', jpgQuality);
    await p.setInt('autoDelaySeconds', autoDelaySeconds);
    await p.setInt('nameStyle', nameStyle.index);
    await p.setInt('colorEffect', colorEffect.index);
    await p.setInt(
      'outputFormat',
      (mode == ScanMode.document
              ? outputFormat
              : _modeFormats[ScanMode.document] ?? OutputFormat.jpg)
          .index,
    );
    await p.setInt('cutMode', cutMode.index);
    await p.setInt('ocrLanguage', ocrLanguage.index);
    await p.setBool('smartEdge', smartEdge);
    await p.setInt('recordFormat', recordFormat.index);
    await p.setInt('recordSource', recordSource.index);
    await p.setBool('removeBg', removeBg);
    await p.setInt('sequence', sequence);
  }

  @override
  void dispose() {
    _disposed = true;
    _canvasTimer?.cancel();
    _recordTimer?.cancel();
    _stopLocalAuto();
    _frameSub?.cancel();
    _eventSub?.cancel();
    unawaited(_backend?.disconnect() ?? Future<void>.value());
    previewImage?.dispose();
    super.dispose();
  }
}
