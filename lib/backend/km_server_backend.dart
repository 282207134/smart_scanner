/// Windows 后端：通过 KHServer (ws://127.0.0.1:22225) 控制高拍仪。
///
/// KHServer 由厂商"多浏览器SDK"安装（C:\Program Files (x86)\KMServer\KHServer.exe），
/// 本实现即厂商 demo/gpyhs.js 的 Dart 等价物。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'dart:isolate';

import '../core/capture_processor.dart';
import '../core/models.dart';
import '../core/protocol.dart';
import '../core/ws_client.dart';
import '../core/document_exporter.dart';
import 'scanner_backend.dart';
import 'video_recorder.dart';

class KmServerBackend implements ScannerBackend {
  static const host = '127.0.0.1';
  static const port = 22225;
  final String serverHost;
  final int serverPort;
  final Duration openTimeout;
  final Duration captureSettling;

  KmServerBackend({
    this.serverHost = host,
    this.serverPort = port,
    this.openTimeout = const Duration(seconds: 10),
    this.captureSettling = const Duration(seconds: 3),
  });

  WsClient? _ws;
  Timer? _heartbeat;
  StreamSubscription<Uint8List>? _msgSub;
  StreamSubscription<String>? _closeSub;

  final _frames = StreamController<PreviewFrame>.broadcast();
  final _events = StreamController<ScannerEvent>.broadcast();

  // 等待中的请求
  Completer<List<ScannerDevice>>? _devicesPending;
  Completer<List<ScanResolution>>? _resPending;
  Completer<bool>? _openPending;
  Completer<CaptureResult>? _capturePending;
  Completer<OcrEvent>? _ocrPending;
  Completer<IdCardEvent>? _idCardPending;
  Completer<bool>? _pdfPending;
  Completer<bool>? _bookPending;
  final List<String> _pdfPaths = [];
  final Set<String> _expiredCapturePaths = {};

  @override
  bool get isConnected => _ws != null && !_ws!.isClosed;

  @override
  bool get isOpen => _isOpen;
  bool _isOpen = false;
  int _canvasW = 640, _canvasH = 480;
  int _captureW = 1920, _captureH = 1080, _device = 0;
  int _rotation = 0, _colorMode = 0, _cutMode = 0;
  List<int>? _cutRect;
  bool _smartEdge = false, _removeBg = false;

  /// 录制器（本地 ffmpeg 实现）
  VideoRecorder? _recorder;

  @override
  Stream<PreviewFrame> get frames => _frames.stream;

  @override
  Stream<ScannerEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (isConnected) return;
    final ws = await WsClient.connect(
      serverHost,
      serverPort,
      timeout: const Duration(seconds: 3),
    );
    _ws = ws;
    _msgSub = ws.messages.listen(_onMessage);
    _closeSub = ws.closes.listen((why) {
      _isOpen = false;
      _failPending();
      _events.add(ConnectionEvent(false, why));
    });
    _heartbeat = Timer.periodic(const Duration(seconds: 6), (_) {
      try {
        ws.sendBytes(KmMessage.heartbeat);
      } catch (_) {}
    });
    _events.add(ConnectionEvent(true, 'KHServer 已连接'));
  }

  @override
  Future<void> disconnect() async {
    try {
      await stopRecord();
    } catch (e) {
      _events.add(RawEvent(0, '停止录像：$e'));
    }
    _heartbeat?.cancel();
    try {
      _ws?.sendBytes(KmMessage.cmd(KmCmd.release));
    } catch (_) {}
    await _msgSub?.cancel();
    await _closeSub?.cancel();
    _ws?.close();
    _ws = null;
    _isOpen = false;
    _failPending();
  }

  void _send(Uint8List msg) {
    final ws = _ws;
    if (ws == null || ws.isClosed) {
      throw StateError('未连接扫描仪服务');
    }
    ws.sendBytes(msg);
  }

  void _failPending() {
    _devicesPending?.completeError(StateError('连接断开'));
    _devicesPending = null;
    _resPending?.completeError(StateError('连接断开'));
    _resPending = null;
    _openPending?.complete(false);
    _openPending = null;
    _capturePending?.completeError(StateError('连接断开'));
    _capturePending = null;
    _ocrPending?.complete(OcrEvent(false, 0, '连接断开'));
    _ocrPending = null;
    _idCardPending?.complete(IdCardEvent(ok: false));
    _idCardPending = null;
    _pdfPending?.complete(false);
    _pdfPending = null;
    _bookPending?.completeError(StateError('连接断开'));
    _bookPending = null;
  }

  // ---------------- 请求 ----------------

  @override
  Future<List<ScannerDevice>> listDevices() async {
    final c = Completer<List<ScannerDevice>>();
    _devicesPending = c;
    _send(KmMessage.cmd(KmCmd.getDevices));
    return c.future.timeout(const Duration(seconds: 8));
  }

  @override
  Future<List<ScanResolution>> listResolutions(int deviceIndex) async {
    final c = Completer<List<ScanResolution>>();
    _resPending = c;
    _send(KmMessage.cmd(KmCmd.getResolutions, [deviceIndex & 0xff]));
    return c.future.timeout(const Duration(seconds: 8));
  }

  @override
  Future<void> open({
    required int deviceIndex,
    required int canvasW,
    required int canvasH,
    required int captureW,
    required int captureH,
  }) async {
    if (_openPending != null) throw StateError('摄像头正在打开');
    _isOpen = false;
    _canvasW = canvasW;
    _canvasH = canvasH;
    _captureW = captureW;
    _captureH = captureH;
    _device = deviceIndex;
    final c = Completer<bool>();
    _openPending = c;
    try {
      _send(
        KmMessage.openCamera(deviceIndex, canvasW, canvasH, captureW, captureH),
      );
      final ok = await c.future.timeout(openTimeout);
      if (!ok) throw StateError('打开摄像头失败');
      _isOpen = true;
    } finally {
      if (identical(_openPending, c)) _openPending = null;
    }
  }

  @override
  Future<void> close() async {
    _send(KmMessage.cmd(KmCmd.closeCamera, [0x00]));
    _isOpen = false;
  }

  @override
  Future<CaptureResult> capture({String savePath = ''}) async {
    if (_capturePending != null) throw StateError('拍摄尚未完成');
    final c = Completer<CaptureResult>();
    _capturePending = c;
    try {
      await _sendChunked(KmMessage.capture(savePath));
      return await c.future.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      if (identical(_capturePending, c)) _capturePending = null;
      if (savePath.isNotEmpty) _expiredCapturePaths.add(savePath.toLowerCase());
      if (_expiredCapturePaths.length > 100) {
        _expiredCapturePaths.remove(_expiredCapturePaths.first);
      }
      // Older services can stream UVC frames while their photo command hangs.
      // Reopen at the actual capture dimensions, then save a full resolution frame.
      return await _captureFullResolutionFrame(savePath);
    } finally {
      if (identical(_capturePending, c)) _capturePending = null;
    }
  }

  @override
  Future<CaptureResult> captureRaw({String savePath = ''}) =>
      _captureFullResolutionFrame(savePath, raw: true);

  Future<CaptureResult> _captureFullResolutionFrame(
    String savePath, {
    bool raw = false,
  }) async {
    final cw = _canvasW,
        ch = _canvasH,
        width = _captureW,
        height = _captureH,
        device = _device;
    PreviewFrame? sharpest;
    double bestSharpness = -1;
    final focusFrames = frames.listen((frame) {
      if (frame.width != width ||
          frame.height != height ||
          frame.x != 0 ||
          frame.y != 0) {
        return;
      }
      final score = _sharpness(frame);
      if (score > bestSharpness) {
        sharpest = frame;
        bestSharpness = score;
      }
    });
    final next = frames
        .firstWhere(
          (f) => f.width == width && f.height == height && f.x == 0 && f.y == 0,
        )
        .timeout(const Duration(seconds: 25));
    // Keep a failure observed even if opening throws before awaiting the frame.
    unawaited(next.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    try {
      _send(KmMessage.rotate(0));
      _send(KmMessage.cmd(KmCmd.setColorMode, [0]));
      _send(KmMessage.cmd(KmCmd.setCutMode, [0]));
      _send(KmMessage.cmd(KmCmd.setDeleteBlackEdge, [0]));
      _send(KmMessage.cmd(KmCmd.setDeleteBgColor, [0]));
      await close();
      await open(
        deviceIndex: device,
        canvasW: width,
        canvasH: height,
        captureW: width,
        captureH: height,
      );
      _send(KmMessage.rotate(0));
      _simple(KmCmd.bestSize);
      _send(KmMessage.cmd(KmCmd.setColorMode, [0]));
      _simple(KmCmd.manualFocus);
      final first = await next;
      // Reopening the camera restarts autofocus on some UVC devices. Avoid
      // saving its blurred first frame; choose the sharpest fresh full frame.
      await Future<void>.delayed(captureSettling);
      final focusDeadline = DateTime.now().add(const Duration(seconds: 3));
      while (bestSharpness < 40 && DateTime.now().isBefore(focusDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      final frame = sharpest ?? first;
      final rotation = _rotation,
          color = raw ? 0 : _colorMode,
          cut = raw ? 0 : _cutMode;
      final rect = _cutRect, edge = _smartEdge, background = _removeBg;
      final bytes = await Isolate.run(
        () => CaptureProcessor.fromFrame(
          rgb: frame.rgb,
          width: width,
          height: height,
          canvasW: cw,
          canvasH: ch,
          rotation: rotation,
          colorMode: color,
          cutMode: cut,
          cutRect: rect,
          smartEdge: raw ? false : edge,
          removeBg: raw ? false : background,
        ),
      );
      if (savePath.isNotEmpty) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
      return CaptureResult(savedPath: savePath, imageBytes: bytes);
    } finally {
      await focusFrames.cancel();
      await close();
      await open(
        deviceIndex: device,
        canvasW: cw,
        canvasH: ch,
        captureW: width,
        captureH: height,
      );
      _send(KmMessage.rotate(_rotation));
      _send(KmMessage.cmd(KmCmd.setColorMode, [_colorMode]));
      _send(KmMessage.cmd(KmCmd.setCutMode, [_cutMode]));
      _send(KmMessage.cmd(KmCmd.setDeleteBlackEdge, [_smartEdge ? 1 : 0]));
      _send(KmMessage.cmd(KmCmd.setDeleteBgColor, [_removeBg ? 1 : 0]));
    }
  }

  static double _sharpness(PreviewFrame frame) {
    final w = frame.width, h = frame.height, rgb = frame.rgb;
    double sum = 0;
    var count = 0;
    int value(int x, int y) => rgb[(y * w + x) * 3 + 1];
    for (var y = 2; y < h - 2; y += 7) {
      for (var x = 2; x < w - 2; x += 7) {
        final lap =
            value(x - 1, y) +
            value(x + 1, y) +
            value(x, y - 1) +
            value(x, y + 1) -
            4 * value(x, y);
        sum += lap * lap;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }

  // ---------------- 视图控制 ----------------

  void _simple(int cmd) {
    _send(KmMessage.cmd(cmd, [0x00]));
  }

  @override
  void zoomIn() => _simple(KmCmd.zoomIn);
  @override
  void zoomOut() => _simple(KmCmd.zoomOut);
  @override
  void bestSize() => _simple(KmCmd.bestSize);
  @override
  void trueSize() => _simple(KmCmd.trueSize);
  @override
  void rotateLeft() {
    _rotation = (_rotation + 3) % 4;
    _simple(KmCmd.rotateLeft);
  }

  @override
  void rotateRight() {
    _rotation = (_rotation + 1) % 4;
    _simple(KmCmd.rotateRight);
  }

  @override
  void manualFocus() => _simple(KmCmd.manualFocus);

  @override
  void rotate(int angle) {
    _rotation = angle % 4;
    _send(KmMessage.rotate(angle));
  }

  @override
  void moveOffset(int px, int py, int xDir, int yDir) =>
      _send(KmMessage.moveOffset(px, py, xDir, yDir));

  // ---------------- 处理参数 ----------------

  @override
  void setCutMode(int mode) {
    _cutMode = mode;
    _send(KmMessage.cmd(KmCmd.setCutMode, [mode]));
  }

  @override
  void setCutRect(int x, int y, int w, int h) {
    _cutRect = [x, y, w, h];
    _send(KmMessage.setCutRect(x, y, w, h));
  }

  @override
  void setColorMode(int mode) {
    _colorMode = mode;
    _send(KmMessage.cmd(KmCmd.setColorMode, [mode]));
  }

  @override
  void setDeleteBlackEdge(int flag) {
    _smartEdge = flag == 1;
    _send(KmMessage.cmd(KmCmd.setDeleteBlackEdge, [flag]));
  }

  @override
  void setDeleteBgColor(int flag) {
    _removeBg = flag == 1;
    _send(KmMessage.cmd(KmCmd.setDeleteBgColor, [flag]));
  }

  @override
  void setFileType(int index) =>
      _send(KmMessage.cmd(KmCmd.setFileType, [index]));

  @override
  void setJpgQuality(int value) =>
      _send(KmMessage.cmd(KmCmd.setJpgQuality, [value & 0xff]));

  @override
  void setDpi(int xDpi, int yDpi) => _send(
    KmMessage.cmd(KmCmd.setDpi, [
      xDpi >> 8 & 0xff,
      xDpi & 0xff,
      yDpi >> 8 & 0xff,
      yDpi & 0xff,
    ]),
  );

  @override
  void setZpMode(int mode) => _send(KmMessage.setZpMode(mode));

  // ---------------- 识别 ----------------

  @override
  void recognizeBarcodeFromCamera(int type) =>
      _send(KmMessage.cmd(KmCmd.qrFromCamera, [type & 0xff]));

  @override
  Future<OcrEvent> ocrImage(String imagePath, OcrLanguage language) async {
    final c = Completer<OcrEvent>();
    _ocrPending = c;
    await _sendChunked(KmMessage.ocr(language.serverIndex, imagePath, ''));
    return c.future.timeout(const Duration(minutes: 2));
  }

  @override
  Future<IdCardEvent> readIdCard(String savePath) async {
    final c = Completer<IdCardEvent>();
    _idCardPending = c;
    // 0x81: 简单拼接，不分包
    _send(KmMessage.cmd(KmCmd.readIdCardEx, KmMessage.encodePath(savePath)));
    return c.future.timeout(const Duration(seconds: 30));
  }

  /// 分包发送（包间加短延时，照厂商 demo 的节奏，避免旧服务端丢包）
  Future<void> _sendChunked(List<Uint8List> packets) async {
    for (int i = 0; i < packets.length; i++) {
      if (i > 0) await Future.delayed(const Duration(milliseconds: 40));
      _send(packets[i]);
    }
  }

  // ---------------- 书籍展平 ----------------

  @override
  Future<List<CaptureResult>> captureBook(
    String leftPath,
    String rightPath,
  ) async {
    if (_bookPending != null) throw StateError('书籍拍摄尚未完成');
    final c = Completer<bool>();
    _bookPending = c;
    try {
      await _sendChunked(KmMessage.captureZp(leftPath, rightPath));
      if (!await c.future.timeout(const Duration(seconds: 45))) {
        throw StateError('书籍展平失败');
      }
      return [
        CaptureResult(savedPath: leftPath),
        CaptureResult(savedPath: rightPath),
      ];
    } finally {
      if (identical(_bookPending, c)) _bookPending = null;
    }
  }

  @override
  Future<void> startWiseCapture(String folderPath) async {
    await _sendChunked(
      KmMessage.pathCommand(KmCmd.wiseCaptureStart, folderPath),
    );
  }

  @override
  Future<void> stopWiseCapture() async {
    _send(KmMessage.cmd(KmCmd.wiseCaptureStop, [0x00]));
  }

  // ---------------- PDF ----------------

  @override
  Future<void> addImagesToPdf(List<String> imagePaths) async {
    for (final path in imagePaths) {
      if (!await File(path).exists()) throw StateError('PDF 源图片不存在：$path');
    }
    _pdfPaths.addAll(imagePaths);
  }

  @override
  Future<void> combineToPdf(String destPdfPath) async {
    final images = await Future.wait(
      _pdfPaths.map((p) => File(p).readAsBytes()),
    );
    await DocumentExporter.save(
      destPdfPath,
      await DocumentExporter.imagePdf(images),
    );
    _pdfPaths.clear();
  }

  // ---------------- 视频录制 ----------------

  @override
  Future<VideoRecorder> startRecord(
    String savePath,
    int formatIndex, {
    RecordSource source = RecordSource.camera,
  }) async {
    final fmt = RecordFormat.values[formatIndex.clamp(0, 2)];
    final rec = VideoRecorder(
      frames: _frames.stream,
      savePath: savePath,
      format: fmt,
      width: _canvasW,
      height: _canvasH,
      source: source,
    );
    await rec.start();
    _recorder = rec;
    return rec;
  }

  @override
  Future<void> stopRecord() async {
    final r = _recorder;
    _recorder = null;
    if (r != null) await r.stop();
  }

  // ---------------- 响应分发 ----------------

  void _onMessage(Uint8List raw) {
    final r = KmParser.parse(raw);
    if (r == null) return;
    switch (r) {
      case KmHeartbeat():
        break;
      case KmDevices(:final names):
        _devicesPending?.complete(
          List.generate(names.length, (i) => ScannerDevice(i, names[i])),
        );
        _devicesPending = null;
      case KmResolutions(:final list):
        _resPending?.complete(
          list.map((e) => ScanResolution(e.$1, e.$2)).toList(),
        );
        _resPending = null;
      case KmOpenStatus(:final ok):
        _openPending?.complete(ok);
        _openPending = null;
        if (!ok) _isOpen = false;
      case KmCaptureResult(:final ok, :final path, :final imageBytes):
        if (_expiredCapturePaths.contains(path.toLowerCase())) return;
        if (_capturePending != null) {
          if (ok) {
            _capturePending?.complete(
              CaptureResult(savedPath: path, imageBytes: imageBytes),
            );
          } else {
            _capturePending?.completeError(StateError('扫描仪拍照失败'));
          }
          _capturePending = null;
        } else {
          _events.add(CaptureEvent(ok, path, imageBytes));
        }
      case KmFrame(:final width, :final height, :final x, :final y, :final rgb):
        // Some KHServer versions stream the requested view without sending 01.
        // KHServer aligns RGB view dimensions to four pixels (410 -> 408).
        // Allow that small rounding gap, while still requiring a centered
        // frame covering the new canvas; smaller old views cannot confirm it.
        if (_openPending != null &&
            x >= 0 &&
            y >= 0 &&
            x + width <= _canvasW &&
            y + height <= _canvasH &&
            (width >= _canvasW - 3 || height >= _canvasH - 3) &&
            (x * 2 + width - _canvasW).abs() <= 2 &&
            (y * 2 + height - _canvasH).abs() <= 2) {
          _openPending!.complete(true);
          _openPending = null;
        }
        if (_frames.hasListener) {
          _frames.add(
            PreviewFrame(width: width, height: height, x: x, y: y, rgb: rgb),
          );
        }
      case KmBarcode(:final ok, :final content):
        _events.add(BarcodeEvent(ok, content));
      case KmOcr(:final ok, :final progress, :final text, :final flag):
        final ev = OcrEvent(ok, progress, text, flag: flag);
        // flag==1 为进度上报，不结束等待；其余（成功/授权失败/其它错误）都结束
        if (_ocrPending != null && flag != 1) {
          _ocrPending?.complete(ev);
          _ocrPending = null;
        }
        _events.add(ev);
      case KmIdCard(:final ok, :final fields, :final images):
        final ev = IdCardEvent(
          ok: ok,
          name: fields.isNotEmpty ? fields[0] : '',
          sex: fields.length > 1 ? fields[1] : '',
          nation: fields.length > 2 ? fields[2] : '',
          born: fields.length > 3 ? fields[3] : '',
          address: fields.length > 4 ? fields[4] : '',
          cardNum: fields.length > 5 ? fields[5] : '',
          issuedAt: fields.length > 6 ? fields[6] : '',
          effectedDate: fields.length > 7 ? fields[7] : '',
          portraitJpg: images.isNotEmpty ? images[0] : null,
          mergedJpg: images.length > 1 ? images[1] : null,
        );
        _idCardPending?.complete(ev);
        _idCardPending = null;
        _events.add(ev);
      case KmWiseCapture(
        :final ok,
        :final steady,
        :final path,
        :final imageBytes,
      ):
        _events.add(
          WiseCaptureEvent(
            done: !ok,
            steady: steady,
            path: path,
            imageBytes: imageBytes,
          ),
        );
      case KmZpResult(:final ok):
        _bookPending?.complete(ok);
        _bookPending = null;
      case KmPdf(:final ok, :final detail):
        if (_pdfPending != null) {
          _pdfPending?.complete(ok);
          _pdfPending = null;
        }
        _events.add(
          PdfEvent(ok, detail.isEmpty ? (ok ? 'PDF处理成功' : 'PDF处理失败') : detail),
        );
      case KmGeneric(:final cmd, :final ok, :final text):
        _events.add(RawEvent(cmd, text));
        // 未知的完成型响应，别让等待者悬挂
        if (cmd == 0xA8 || cmd == 0x90 || cmd == 0x92) {
          _events.add(PdfEvent(ok, text));
        }
    }
  }
}
