/// 数据模型定义
library;

import 'dart:typed_data';

/// 扫描仪设备
class ScannerDevice {
  final int index;
  final String name;
  const ScannerDevice(this.index, this.name);
  @override
  String toString() => name;
}

/// 采集分辨率
class ScanResolution {
  final int width;
  final int height;
  const ScanResolution(this.width, this.height);
  String get label => '$width×$height';
  @override
  String toString() => label;
}

/// 功能模式（对应顶部标签页）
enum ScanMode {
  document('文档'),
  book('书籍'),
  idCard('证件'),
  barcode('条码识别'),
  video('视频录制'),
  ocr('OCR'),
  contract('合同管理');

  const ScanMode(this.label);
  final String label;
}

/// 裁切方式
enum CutMode {
  none('不裁切'),
  auto('自动裁切'),
  manual('手动裁切'),
  custom('自定义区域');

  const CutMode(this.label);
  final String label;
}

/// 输出效果（服务端0xA0：0彩色 1灰度 2黑白）
enum ColorEffect {
  native('原生色彩', 0),
  grayscale('灰度', 1),
  blackWhite('黑白', 2);

  const ColorEffect(this.label, this.serverIndex);
  final String label;
  final int serverIndex;
}

/// 输出格式（服务端0x28：0=jpg 1=png 2=tif 3=pdf）
enum OutputFormat {
  jpg('JPG', 0, '.jpg'),
  png('PNG', 1, '.png'),
  tif('TIF', 2, '.tif'),
  pdf('PDF', 3, '.pdf');

  const OutputFormat(this.label, this.serverIndex, this.ext);
  final String label;
  final int serverIndex;
  final String ext;
}

/// 命名方式
enum NameStyle {
  dateTime('日期时间'),
  sequence('自增序号');

  const NameStyle(this.label);
  final String label;
}

/// 展平方式（书籍模式，服务端0xE2）
enum FlattenMode {
  none('不展平'),
  flatten('展平');

  const FlattenMode(this.label);
  final String label;
}

/// OCR 识别语言（服务端0xC2 languageIndex）
enum OcrLanguage {
  chineseEnglish('中文简体,English', 0),
  english('English', 1),
  chinese('中文简体', 2);

  const OcrLanguage(this.label, this.serverIndex);
  final String label;
  final int serverIndex;
}

/// 预览帧（canvas 坐标系下的一块 RGB 矩形）
class PreviewFrame {
  final int width;
  final int height;
  final int x;
  final int y;
  final Uint8List rgb; // 3字节/像素
  const PreviewFrame(
      {required this.width,
      required this.height,
      required this.x,
      required this.y,
      required this.rgb});
}

/// 拍摄结果
class CaptureResult {
  final String savedPath; // 服务端保存路径（本机路径）
  final Uint8List? imageBytes; // 服务端返回的图像数据（可空）
  const CaptureResult({required this.savedPath, this.imageBytes});
}

/// 已拍摄页面（缩略图列表项）
class CapturedPage {
  final String filePath;
  final Uint8List thumbnailJpg;
  final DateTime time;
  final String ocrText; // OCR结果（如有）
  CapturedPage({
    required this.filePath,
    required this.thumbnailJpg,
    required this.time,
    this.ocrText = '',
  });
}

/// 后端事件基类
sealed class ScannerEvent {}

/// 设备列表
class DevicesEvent extends ScannerEvent {
  final List<ScannerDevice> devices;
  DevicesEvent(this.devices);
}

/// 分辨率列表
class ResolutionsEvent extends ScannerEvent {
  final int deviceIndex;
  final List<ScanResolution> resolutions;
  ResolutionsEvent(this.deviceIndex, this.resolutions);
}

/// 打开/关闭结果
class OpenStatusEvent extends ScannerEvent {
  final bool ok;
  OpenStatusEvent(this.ok);
}

/// 拍照结果
class CaptureEvent extends ScannerEvent {
  final bool ok;
  final String path;
  final Uint8List? imageBytes;
  CaptureEvent(this.ok, this.path, this.imageBytes);
}

/// 条码/二维码识别结果
class BarcodeEvent extends ScannerEvent {
  final bool ok;
  final String content;
  BarcodeEvent(this.ok, this.content);
}

/// OCR 结果
class OcrEvent extends ScannerEvent {
  final bool ok;
  final int progress;
  final String text;

  /// 服务端标志位（0成功 1进度 40授权失败 其它失败）
  final int flag;
  OcrEvent(this.ok, this.progress, this.text, {this.flag = 0});

  /// 适合展示给用户的失败原因
  String get errorLabel {
    if (ok) return '';
    if (flag == 40) return 'OCR授权失败：服务端未开通OCR功能（请联系厂商授权）';
    if (flag == 1 || flag == 0) return 'OCR识别失败';
    return 'OCR识别失败（错误码 $flag）';
  }
}

/// 身份证信息
class IdCardEvent extends ScannerEvent {
  final bool ok;
  final String name;
  final String sex;
  final String nation;
  final String born;
  final String address;
  final String cardNum;
  final String issuedAt;
  final String effectedDate;
  final Uint8List? portraitJpg; // 头像
  final Uint8List? mergedJpg; // 正反面合并图
  IdCardEvent({
    required this.ok,
    this.name = '',
    this.sex = '',
    this.nation = '',
    this.born = '',
    this.address = '',
    this.cardNum = '',
    this.issuedAt = '',
    this.effectedDate = '',
    this.portraitJpg,
    this.mergedJpg,
  });
}

/// 自动连拍（自动扫描）结果
class WiseCaptureEvent extends ScannerEvent {
  final bool done; // false = 本页完成, true = 连拍已停止
  final bool steady;
  final String path;
  final Uint8List? imageBytes;
  WiseCaptureEvent(
      {required this.done,
      required this.steady,
      this.path = '',
      this.imageBytes});
}

/// PDF 合并进度/结果
class PdfEvent extends ScannerEvent {
  final bool ok;
  final String detail;
  PdfEvent(this.ok, this.detail);
}

/// 连接状态变化
class ConnectionEvent extends ScannerEvent {
  final bool connected;
  final String detail;
  ConnectionEvent(this.connected, this.detail);
}

/// 服务端返回的错误/未知消息
class RawEvent extends ScannerEvent {
  final int cmd;
  final String detail;
  RawEvent(this.cmd, this.detail);
}
