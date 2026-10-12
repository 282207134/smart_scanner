/// macOS 后端骨架。
///
/// KHServer/OCX/DLL 均为 Windows 专属，macOS 上高拍仪作为标准 UVC 相机
/// 由 AVFoundation 接入。本文件定义了实现落点，真实实现需要在 macOS 上：
///
/// 1. 用 AVCaptureSession 枚举 AVCaptureDevice（UVC 设备）；
/// 2. 以 AVCaptureVideoDataOutput 接收 CVPixelBuffer（预览帧），
///    转为 RGB/RGBA 后通过 EventChannel/Texture 推给 Flutter；
/// 3. 拍摄用 AVCaptureStillImageOutput / photoOutput 抓帧存文件；
/// 4. 裁剪/色彩/PDF 等后处理在 Dart 侧（package:image）或原生侧完成，
///    OCR 用 Vision 框架、条码用 AVFoundation 的 metadataObjectTypes。
///
/// 当前状态：接口已对齐，未实现时 connect() 抛出 UnimplementedError，
/// 上层捕获后自动降级为 MockBackend 并提示用户。
library;

import '../core/models.dart';
import 'scanner_backend.dart';

class MacAvfBackend implements ScannerBackend {
  @override
  bool get isConnected => false;

  @override
  bool get isOpen => false;

  @override
  Stream<PreviewFrame> get frames => const Stream.empty();

  @override
  Stream<ScannerEvent> get events => const Stream.empty();

  @override
  Future<void> connect() async {
    throw UnimplementedError(
        'macOS AVFoundation 后端尚未实现（当前版本请在 Windows 上配合 KHServer 使用）');
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<ScannerDevice>> listDevices() async => const [];

  @override
  Future<List<ScanResolution>> listResolutions(int deviceIndex) async => const [];

  @override
  Future<void> open({
    required int deviceIndex,
    required int canvasW,
    required int canvasH,
    required int captureW,
    required int captureH,
  }) async {}

  @override
  Future<void> close() async {}

  @override
  Future<CaptureResult> capture({String savePath = ''}) async =>
      CaptureResult(savedPath: '');

  @override
  void zoomIn() {}
  @override
  void zoomOut() {}
  @override
  void bestSize() {}
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
  void manualFocus() {}
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
  void recognizeBarcodeFromCamera(int type) {}
  @override
  Future<OcrEvent> ocrImage(String imagePath, OcrLanguage language) async =>
      OcrEvent(false, 0, '');

  @override
  Future<IdCardEvent> readIdCard(String savePath) async =>
      IdCardEvent(ok: false);
  @override
  Future<void> captureBook(String leftPath, String rightPath) async {}
  @override
  Future<void> startWiseCapture(String folderPath) async {}
  @override
  Future<void> stopWiseCapture() async {}
  @override
  Future<void> addImagesToPdf(List<String> imagePaths) async {}
  @override
  Future<void> combineToPdf(String destPdfPath) async {}
}
