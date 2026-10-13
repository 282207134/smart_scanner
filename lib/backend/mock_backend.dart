/// 离线演示后端，用户明确选择演示模式后使用。
///
/// 生成带时间码的测试图案帧（RGB），拍照返回生成的 BMP 字节。
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core/models.dart';
import 'scanner_backend.dart';
import 'video_recorder.dart';

class MockBackend implements ScannerBackend {
  final bool emitFrames;
  MockBackend({this.emitFrames = true});
  final _frames = StreamController<PreviewFrame>.broadcast();
  final _events = StreamController<ScannerEvent>.broadcast();

  Timer? _timer;
  int _tick = 0;
  bool _connected = false;
  bool _open = false;
  int _canvasW = 640;
  int _canvasH = 480;
  final _rand = Random();

  @override
  bool get isConnected => _connected;

  @override
  bool get isOpen => _open;

  @override
  Stream<PreviewFrame> get frames => _frames.stream;

  @override
  Stream<ScannerEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    _connected = true;
    _events.add(ConnectionEvent(true, 'Mock 后端（无设备演示模式）'));
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _connected = false;
    _open = false;
  }

  @override
  Future<List<ScannerDevice>> listDevices() async {
    await Future.delayed(const Duration(milliseconds: 120));
    return [ScannerDevice(0, '演示相机 (Mock)')];
  }

  @override
  Future<List<ScanResolution>> listResolutions(int deviceIndex) async {
    await Future.delayed(const Duration(milliseconds: 80));
    return const [
      ScanResolution(2592, 1944),
      ScanResolution(1920, 1080),
      ScanResolution(1280, 720),
    ];
  }

  @override
  Future<void> open({
    required int deviceIndex,
    required int canvasW,
    required int canvasH,
    required int captureW,
    required int captureH,
  }) async {
    _canvasW = canvasW;
    _canvasH = canvasH;
    _open = true;
    _timer?.cancel();
    if (emitFrames) {
      _timer = Timer.periodic(const Duration(milliseconds: 66), (_) {
        _tick++;
        _emitFrame();
      });
    }
    _events.add(OpenStatusEvent(true));
  }

  void _emitFrame() {
    final w = _canvasW, h = _canvasH;
    final rgb = Uint8List(w * h * 3);
    final t = _tick;
    // 渐变背景 + 移动扫描线 + 静态“文档”矩形
    for (int y = 0; y < h; y++) {
      final rowBase = y * w * 3;
      final g = (y * 255) ~/ h;
      for (int x = 0; x < w; x++) {
        final i = rowBase + x * 3;
        rgb[i] = ((x + t) ~/ 2) & 0xff;
        rgb[i + 1] = g;
        rgb[i + 2] = 60;
      }
    }
    // 扫描线
    final lineY = (t * 4) % h;
    for (int x = 0; x < w; x++) {
      final i = (lineY * w + x) * 3;
      rgb[i] = 255;
      rgb[i + 1] = 255;
      rgb[i + 2] = 0;
    }
    // “纸张”
    final pw = w * 6 ~/ 10, ph = h * 7 ~/ 10;
    final px = (w - pw) ~/ 2, py = (h - ph) ~/ 2;
    for (int y = py; y < py + ph; y++) {
      for (int x = px; x < px + pw; x++) {
        final i = (y * w + x) * 3;
        rgb[i] = 240;
        rgb[i + 1] = 240;
        rgb[i + 2] = 235;
      }
    }
    _frames.add(PreviewFrame(width: w, height: h, x: 0, y: 0, rgb: rgb));
  }

  @override
  Future<void> close() async {
    _timer?.cancel();
    _open = false;
  }

  @override
  Future<CaptureResult> capture({String savePath = ''}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final w = _canvasW * 2, h = _canvasH * 2;
    final rgb = Uint8List(w * h * 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final i = (y * w + x) * 3;
        rgb[i] = (x * 255) ~/ w;
        rgb[i + 1] = (y * 255) ~/ h;
        rgb[i + 2] = (_rand.nextInt(30) + 100);
      }
    }
    final bmp = _encodeBmp(rgb, w, h);
    return CaptureResult(
      savedPath: savePath.isEmpty ? 'mock://capture' : savePath,
      imageBytes: bmp,
    );
  }

  @override
  Future<CaptureResult> captureRaw({String savePath = ''}) =>
      capture(savePath: savePath);

  static Uint8List _encodeBmp(Uint8List rgb, int w, int h) {
    final rowStride = ((w * 3 + 3) ~/ 4) * 4;
    final dataSize = rowStride * h;
    final buf = ByteData(54 + dataSize);
    final u8 = buf.buffer.asUint8List();
    u8[0] = 0x42;
    u8[1] = 0x4D;
    buf.setUint32(2, 54 + dataSize, Endian.little);
    buf.setUint32(10, 54, Endian.little);
    buf.setUint32(14, 40, Endian.little);
    buf.setInt32(18, w, Endian.little);
    buf.setInt32(22, h, Endian.little);
    buf.setUint16(26, 1, Endian.little);
    buf.setUint16(28, 24, Endian.little);
    buf.setUint32(34, dataSize, Endian.little);
    for (int y = 0; y < h; y++) {
      final srcRow = y * w * 3;
      final dstRow = 54 + (h - 1 - y) * rowStride;
      for (int x = 0; x < w; x++) {
        final s = srcRow + x * 3;
        final d = dstRow + x * 3;
        u8[d] = rgb[s + 2];
        u8[d + 1] = rgb[s + 1];
        u8[d + 2] = rgb[s];
      }
    }
    return u8;
  }

  VideoRecorder? _recorder;

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

  @override
  void zoomIn() {}
  @override
  void zoomOut() {}
  @override
  void bestSize() {}
  @override
  void setPreviewSize(bool maximized) {}
  @override
  void trueSize() {}
  @override
  void rotateLeft() {}
  @override
  void rotateRight() {}
  @override
  void rotate(int angle) {}
  @override
  void moveOffset(int px, int py, int xDir, int yDir) {}
  @override
  Future<void> manualFocus() async {}
  @override
  void setCutMode(int mode) {}
  @override
  void setCutRect(int x, int y, int w, int h) {}
  @override
  void setColorMode(int mode) {}
  @override
  void setDeleteBlackEdge(int flag) {}
  @override
  void setDeleteBgColor(int flag) {}
  @override
  void setFileType(int index) {}
  @override
  void setJpgQuality(int value) {}
  @override
  void setDpi(int xDpi, int yDpi) {}
  @override
  void setZpMode(int mode) {}

  @override
  void recognizeBarcodeFromCamera(int type) {
    Future.delayed(const Duration(milliseconds: 400), () {
      _events.add(BarcodeEvent(true, 'MOCK-1234567890'));
    });
  }

  @override
  Future<OcrEvent> ocrImage(String imagePath, OcrLanguage language) async {
    _events.add(OcrEvent(false, 30, '', flag: 1));
    await Future.delayed(const Duration(milliseconds: 600));
    final ev = OcrEvent(true, 100, '这是 Mock 演示文本\nMock OCR demo text.');
    _events.add(ev);
    return ev;
  }

  @override
  Future<List<CaptureResult>> captureBook(
    String leftPath,
    String rightPath,
  ) async {
    return [
      await capture(savePath: leftPath),
      await capture(savePath: rightPath),
    ];
  }

  @override
  Future<IdCardEvent> readIdCard(String savePath) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final ev = IdCardEvent(
      ok: true,
      name: '张三',
      sex: '男',
      nation: '汉',
      born: '1990-01-01',
      address: '演示地址（Mock）',
      cardNum: '123456789012345678',
      issuedAt: '演示公安局',
      effectedDate: '2020.01.01-2040.01.01',
    );
    _events.add(ev);
    return ev;
  }

  @override
  Future<void> startWiseCapture(String folderPath) async {
    throw UnsupportedError('演示模式不提供自动扫描');
  }

  @override
  Future<void> stopWiseCapture() async {}

  @override
  Future<void> addImagesToPdf(List<String> imagePaths) async {
    _events.add(PdfEvent(true, 'Mock: 已添加 ${imagePaths.length} 页'));
  }

  @override
  Future<void> combineToPdf(String destPdfPath) async {
    _events.add(PdfEvent(true, 'Mock: $destPdfPath'));
  }
}
