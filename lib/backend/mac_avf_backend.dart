import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/document_exporter.dart';
import '../core/models.dart';
import '../core/native_ocr.dart';
import 'scanner_backend.dart';
import 'video_recorder.dart';

/// Standard USB/UVC cameras use the macOS camera and Vision APIs.
class MacAvfBackend implements ScannerBackend {
  static const _channel = NativeOcr.channel;
  static const _frameChannel = EventChannel('smart_scanner/frames');
  final _frames = StreamController<PreviewFrame>.broadcast();
  final _events = StreamController<ScannerEvent>.broadcast();
  StreamSubscription<dynamic>? _sub;
  bool _connected = false, _open = false;
  int _canvasW = 640, _canvasH = 480;
  VideoRecorder? _recorder;
  final List<String> _pdfPaths = [];
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
    await _channel.invokeMethod<void>('connect');
    _connected = true;
    _sub ??= _frameChannel.receiveBroadcastStream().listen(
      (value) {
        final map = value as Map;
        _frames.add(
          PreviewFrame(
            width: map['width'] as int,
            height: map['height'] as int,
            x: map['x'] as int? ?? 0,
            y: map['y'] as int? ?? 0,
            rgb: map['rgb'] as Uint8List,
          ),
        );
      },
      onError: (Object error) {
        _events.add(ConnectionEvent(false, '$error'));
      },
    );
    _events.add(ConnectionEvent(true, '摄像头权限已就绪'));
  }

  @override
  Future<void> disconnect() async {
    try {
      await stopRecord();
    } catch (e) {
      _events.add(RawEvent(0, '停止录像：$e'));
    }
    await close();
    await _sub?.cancel();
    _sub = null;
    _connected = false;
  }

  @override
  Future<List<ScannerDevice>> listDevices() async {
    final names = await _channel.invokeListMethod<String>('devices') ?? [];
    return List.generate(names.length, (i) => ScannerDevice(i, names[i]));
  }

  @override
  Future<List<ScanResolution>> listResolutions(int deviceIndex) async {
    final list =
        await _channel.invokeListMethod<dynamic>('resolutions', {
          'device': deviceIndex,
        }) ??
        [];
    return list
        .map((r) => ScanResolution(r['width'] as int, r['height'] as int))
        .toList();
  }

  @override
  Future<void> open({
    required int deviceIndex,
    required int canvasW,
    required int canvasH,
    required int captureW,
    required int captureH,
  }) async {
    await _channel.invokeMethod<void>('open', {
      'device': deviceIndex,
      'canvasW': canvasW,
      'canvasH': canvasH,
      'width': captureW,
      'height': captureH,
    });
    _canvasW = canvasW;
    _canvasH = canvasH;
    _open = true;
  }

  @override
  Future<void> close() async {
    if (_open) await _channel.invokeMethod<void>('close');
    _open = false;
  }

  @override
  Future<CaptureResult> capture({String savePath = ''}) =>
      _capture('capture', savePath);

  @override
  Future<CaptureResult> captureRaw({String savePath = ''}) =>
      _capture('captureRaw', savePath);

  Future<CaptureResult> _capture(String method, String savePath) async {
    final bytes = await _channel.invokeMethod<Uint8List>(method);
    if (bytes == null || bytes.isEmpty) throw StateError('未收到摄像头图像');
    if (savePath.isNotEmpty) {
      await DocumentExporter.save(
        savePath,
        DocumentExporter.encodeImage(bytes, OutputFormat.jpg, 95),
      );
    }
    return CaptureResult(savedPath: savePath, imageBytes: bytes);
  }

  void _set(String key, dynamic value) {
    unawaited(
      _channel
          .invokeMethod<void>('setting', {'key': key, 'value': value})
          .catchError((Object e) {
            _events.add(RawEvent(0, '$e'));
          }),
    );
  }

  @override
  void zoomIn() => _set('zoomDelta', .15);
  @override
  void zoomOut() => _set('zoomDelta', -.15);
  @override
  void bestSize() => _set('zoom', 1.0);
  @override
  void setPreviewSize(bool maximized) => _set('previewSize', maximized);
  @override
  void trueSize() => _set('trueSize', true);
  @override
  void rotateLeft() => _set('rotateDelta', -1);
  @override
  void rotateRight() => _set('rotateDelta', 1);
  @override
  void rotate(int angle) => _set('rotation', angle);
  @override
  void moveOffset(int px, int py, int xDir, int yDir) =>
      _set('pan', [xDir == 0 ? -px : px, yDir == 0 ? -py : py]);
  @override
  Future<void> manualFocus() =>
      _channel.invokeMethod<void>('setting', {'key': 'focus', 'value': true});
  @override
  void setCutMode(int mode) => _set('cutMode', mode);
  @override
  void setCutRect(int x, int y, int w, int h) => _set('cutRect', [x, y, w, h]);
  @override
  void setColorMode(int mode) => _set('colorMode', mode);
  @override
  void setDeleteBlackEdge(int flag) => _set('smartEdge', flag == 1);
  @override
  void setDeleteBgColor(int flag) => _set('removeBg', flag == 1);
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
    unawaited(
      _channel
          .invokeMethod<String>('barcode', {'qr': type == 1})
          .then((text) {
            _events.add(BarcodeEvent(text?.isNotEmpty == true, text ?? ''));
          })
          .catchError((Object e) {
            _events.add(BarcodeEvent(false, ''));
          }),
    );
  }

  @override
  Future<OcrEvent> ocrImage(String imagePath, OcrLanguage language) async =>
      OcrEvent(true, 100, await NativeOcr.recognize(imagePath, language));
  @override
  Future<IdCardEvent> readIdCard(String savePath) =>
      Future.error(UnsupportedError('macOS 暂不支持厂商身份证读卡器；可使用正反面拍照合并'));
  @override
  Future<List<CaptureResult>> captureBook(
    String leftPath,
    String rightPath,
  ) async {
    final result = await capture();
    final halves = DocumentExporter.splitBook(result.imageBytes!);
    final a = halves[0], b = halves[1];
    await DocumentExporter.save(leftPath, a);
    await DocumentExporter.save(rightPath, b);
    return [
      CaptureResult(savedPath: leftPath, imageBytes: a),
      CaptureResult(savedPath: rightPath, imageBytes: b),
    ];
  }

  @override
  Future<void> startWiseCapture(String folderPath) =>
      Future.error(UnsupportedError('macOS 自动翻页检测尚未接入，请使用手动拍摄'));
  @override
  Future<void> stopWiseCapture() async {}
  @override
  Future<void> addImagesToPdf(List<String> paths) async {
    _pdfPaths.addAll(paths);
  }

  @override
  Future<void> combineToPdf(String path) async {
    await DocumentExporter.save(
      path,
      await DocumentExporter.imagePdf(
        await Future.wait(_pdfPaths.map((p) => File(p).readAsBytes())),
      ),
    );
    _pdfPaths.clear();
  }

  @override
  Future<VideoRecorder> startRecord(
    String path,
    int formatIndex, {
    RecordSource source = RecordSource.camera,
  }) async {
    final rec = VideoRecorder(
      frames: frames,
      savePath: path,
      format: RecordFormat.values[formatIndex],
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
    final rec = _recorder;
    _recorder = null;
    await rec?.stop();
  }
}
