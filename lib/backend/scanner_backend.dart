/// 扫描仪后端抽象。
///
/// Windows / macOS: NativeCameraBackend (Media Foundation / AVFoundation)
/// Windows optional: KHServer (KmServerBackend)
/// 离线:    MockBackend (无设备联调/UI开发)
library;

import '../core/models.dart';
import 'video_recorder.dart';

abstract class ScannerBackend {
  /// 连接系统摄像头，或用户选择的厂商服务。
  Future<void> connect();

  Future<void> disconnect();
  bool get isConnected;

  /// 设备与分辨率
  Future<List<ScannerDevice>> listDevices();
  Future<List<ScanResolution>> listResolutions(int deviceIndex);

  /// 打开摄像头预览。
  /// [canvasW]/[canvasH] 为预览流尺寸（服务端按此缩放），
  /// [captureW]/[captureH] 为拍摄分辨率。
  Future<void> open({
    required int deviceIndex,
    required int canvasW,
    required int canvasH,
    required int captureW,
    required int captureH,
  });

  Future<void> close();
  bool get isOpen;

  /// 预览帧流（RGB 矩形块）
  Stream<PreviewFrame> get frames;

  /// 其它事件流（拍照结果、识别结果等）
  Stream<ScannerEvent> get events;

  /// 拍照。[savePath] 非空时服务端直接保存到该路径（本机路径）。
  Future<CaptureResult> capture({String savePath = ''});

  /// Full sensor image with rotation, without crop or color processing.
  Future<CaptureResult> captureRaw({String savePath = ''});

  // ---- 视图控制 ----
  void zoomIn();
  void zoomOut();
  void bestSize();

  /// Display a compact preview or fill the canvas height, without changing capture size.
  void setPreviewSize(bool maximized);
  void trueSize();
  void rotateLeft();
  void rotateRight();
  void rotate(int angle);
  void moveOffset(int px, int py, int xDir, int yDir);

  /// Completes when the refocus request is sent/accepted, not when the lens settles.
  Future<void> manualFocus();

  // ---- 处理参数 ----
  void setCutMode(int mode); // 0无 1自动 2手动 3自定义
  void setCutRect(int x, int y, int w, int h);
  void setColorMode(int mode);
  void setDeleteBlackEdge(int flag);
  void setDeleteBgColor(int flag);
  void setFileType(int index); // 0jpg 1png 2tif 3pdf
  void setJpgQuality(int value);
  void setDpi(int xDpi, int yDpi);
  void setZpMode(int mode); // 展平（书籍）

  // ---- 识别 ----
  void recognizeBarcodeFromCamera(int type);

  /// OCR 识别，返回识别结果（失败时 ok=false）
  Future<OcrEvent> ocrImage(String imagePath, OcrLanguage language);
  Future<IdCardEvent> readIdCard(String savePath);

  // ---- 书籍展平拍摄 ----
  Future<List<CaptureResult>> captureBook(String leftPath, String rightPath);

  // ---- 自动连拍 ----
  Future<void> startWiseCapture(String folderPath);
  Future<void> stopWiseCapture();

  // ---- PDF ----
  Future<void> addImagesToPdf(List<String> imagePaths);
  Future<void> combineToPdf(String destPdfPath);

  // ---- 视频录制 ----
  /// 开始录制。[formatIndex] 0=MP4 1=WMV 2=AVI；返回录制器（含帧流订阅）
  Future<VideoRecorder> startRecord(
    String savePath,
    int formatIndex, {
    RecordSource source = RecordSource.camera,
  });

  /// 停止录制
  Future<void> stopRecord();
}
