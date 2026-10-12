/// Windows 后端：通过 KHServer (ws://127.0.0.1:22225) 控制高拍仪。
///
/// KHServer 由厂商"多浏览器SDK"安装（C:\Program Files (x86)\KMServer\KHServer.exe），
/// 本实现即厂商 demo/gpyhs.js 的 Dart 等价物。
library;

import 'dart:async';
import 'dart:typed_data';

import '../core/models.dart';
import '../core/protocol.dart';
import '../core/ws_client.dart';
import 'scanner_backend.dart';

class KmServerBackend implements ScannerBackend {
  static const host = '127.0.0.1';
  static const port = 22225;

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
  Completer<String>? _barcodePending;
  Completer<OcrEvent>? _ocrPending;
  Completer<IdCardEvent>? _idCardPending;
  Completer<bool>? _pdfPending;

  @override
  bool get isConnected => _ws != null && !_ws!.isClosed;

  @override
  bool get isOpen => _isOpen;
  bool _isOpen = false;

  @override
  Stream<PreviewFrame> get frames => _frames.stream;

  @override
  Stream<ScannerEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (isConnected) return;
    final ws = await WsClient.connect(host, port,
        timeout: const Duration(seconds: 3));
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
    _barcodePending?.completeError(StateError('连接断开'));
    _barcodePending = null;
    _ocrPending?.complete(OcrEvent(false, 0, '连接断开'));
    _ocrPending = null;
    _idCardPending?.complete(IdCardEvent(ok: false));
    _idCardPending = null;
    _pdfPending?.complete(false);
    _pdfPending = null;
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
    final c = Completer<bool>();
    _openPending = c;
    _send(KmMessage.openCamera(
        deviceIndex, canvasW, canvasH, captureW, captureH));
    final ok = await c.future.timeout(const Duration(seconds: 10));
    if (!ok) throw StateError('打开摄像头失败');
    _isOpen = true;
  }

  @override
  Future<void> close() async {
    _send(KmMessage.cmd(KmCmd.closeCamera, [0x00]));
    _isOpen = false;
  }

  @override
  Future<CaptureResult> capture({String savePath = ''}) async {
    final c = Completer<CaptureResult>();
    _capturePending = c;
    for (final p in KmMessage.capture(savePath)) {
      _send(p);
    }
    return c.future.timeout(const Duration(seconds: 30));
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
  void rotateLeft() => _simple(KmCmd.rotateLeft);
  @override
  void rotateRight() => _simple(KmCmd.rotateRight);
  @override
  void manualFocus() => _simple(KmCmd.manualFocus);

  @override
  void rotate(int angle) => _send(KmMessage.rotate(angle));

  @override
  void moveOffset(int px, int py, int xDir, int yDir) =>
      _send(KmMessage.moveOffset(px, py, xDir, yDir));

  // ---------------- 处理参数 ----------------

  @override
  void setCutMode(int mode) => _send(KmMessage.cmd(KmCmd.setCutMode, [mode]));

  @override
  void setCutRect(int x, int y, int w, int h) =>
      _send(KmMessage.setCutRect(x, y, w, h));

  @override
  void setColorMode(int mode) =>
      _send(KmMessage.cmd(KmCmd.setColorMode, [mode]));

  @override
  void setDeleteBlackEdge(int flag) =>
      _send(KmMessage.cmd(KmCmd.setDeleteBlackEdge, [flag]));

  @override
  void setDeleteBgColor(int flag) =>
      _send(KmMessage.cmd(KmCmd.setDeleteBgColor, [flag]));

  @override
  void setFileType(int index) =>
      _send(KmMessage.cmd(KmCmd.setFileType, [index]));

  @override
  void setJpgQuality(int value) =>
      _send(KmMessage.cmd(KmCmd.setJpgQuality, [value & 0xff]));

  @override
  void setDpi(int xDpi, int yDpi) => _send(KmMessage.cmd(KmCmd.setDpi, [
        xDpi >> 8 & 0xff, xDpi & 0xff,
        yDpi >> 8 & 0xff, yDpi & 0xff
      ]));

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
    _send(KmMessage.cmd(KmCmd.readIdCardEx,
        KmMessage.encodePath(savePath)));
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
  Future<void> captureBook(String leftPath, String rightPath) async {
    await _sendChunked(KmMessage.captureZp(leftPath, rightPath));
    // 结果通过 events 流的 KmZpResult 事件返回
  }

  @override
  Future<void> startWiseCapture(String folderPath) async {
    await _sendChunked(KmMessage.pathCommand(KmCmd.wiseCaptureStart, folderPath));
  }

  @override
  Future<void> stopWiseCapture() async {
    _send(KmMessage.cmd(KmCmd.wiseCaptureStop, [0x00]));
  }

  // ---------------- PDF ----------------

  @override
  Future<void> addImagesToPdf(List<String> imagePaths) async {
    final c = Completer<bool>();
    _pdfPending = c;
    await _sendChunked(
        KmMessage.pathCommand(KmCmd.addImgToPdf, imagePaths.join(';')));
    await c.future.timeout(const Duration(minutes: 1));
  }

  @override
  Future<void> combineToPdf(String destPdfPath) async {
    final c = Completer<bool>();
    _pdfPending = c;
    await _sendChunked(KmMessage.pathCommand(KmCmd.combinePdf, destPdfPath));
    await c.future.timeout(const Duration(minutes: 1));
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
            List.generate(names.length, (i) => ScannerDevice(i, names[i])));
        _devicesPending = null;
      case KmResolutions(:final list):
        _resPending?.complete(
            list.map((e) => ScanResolution(e.$1, e.$2)).toList());
        _resPending = null;
      case KmOpenStatus(:final ok):
        _openPending?.complete(ok);
        _openPending = null;
        if (!ok) _isOpen = false;
      case KmCaptureResult(:final ok, :final path, :final imageBytes):
        if (_capturePending != null) {
          _capturePending
              ?.complete(CaptureResult(savedPath: path, imageBytes: imageBytes));
          _capturePending = null;
        } else {
          _events.add(CaptureEvent(ok, path, imageBytes));
        }
      case KmFrame(:final width, :final height, :final x, :final y, :final rgb):
        if (_frames.hasListener) {
          _frames.add(
              PreviewFrame(width: width, height: height, x: x, y: y, rgb: rgb));
        }
      case KmBarcode(:final ok, :final content):
        if (_barcodePending != null) {
          _barcodePending?.complete(ok ? content : '');
          _barcodePending = null;
        }
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
      case KmWiseCapture(:final ok, :final steady, :final path, :final imageBytes):
        _events.add(WiseCaptureEvent(
            done: !ok, steady: steady, path: path, imageBytes: imageBytes));
      case KmZpResult(:final ok):
        _events.add(PdfEvent(ok, ok ? '书籍展平拍摄完成' : '书籍拍摄失败'));
      case KmPdf(:final ok, :final detail):
        if (_pdfPending != null) {
          _pdfPending?.complete(ok);
          _pdfPending = null;
        }
        _events.add(PdfEvent(ok, detail.isEmpty ? (ok ? 'PDF处理成功' : 'PDF处理失败') : detail));
      case KmGeneric(:final cmd, :final ok, :final text):
        _events.add(RawEvent(cmd, text));
        // 未知的完成型响应，别让等待者悬挂
        if (cmd == 0xA8 || cmd == 0x90 || cmd == 0x92) {
          _events.add(PdfEvent(ok, text));
        }
    }
  }
}
