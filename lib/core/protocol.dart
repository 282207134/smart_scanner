/// KHServer 高拍仪二进制协议编解码。
///
/// 请求:  [0x77, 0x88, cmd, ...payload]
/// 响应:  [0x55, 0x66, cmd, ...payload]
/// 心跳:  客户端每6秒发 [0x11,0x11,0x11]，服务端原样返回。
///
/// 协议逆向自厂商"多浏览器SDK"的 demo/gpyhs.js（科密/鸿合高拍仪 KMServer）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 客户端命令字
class KmCmd {
  static const int heartbeat = -1; // 特殊：0x11 0x11 0x11 无 0x7788 前缀
  static const int openCamera = 0x01;
  static const int closeCamera = 0x02;
  static const int zoomIn = 0x03;
  static const int zoomOut = 0x04;
  static const int bestSize = 0x05; // 适合大小
  static const int trueSize = 0x06; // 1:1
  static const int rotateLeft = 0x07;
  static const int rotateRight = 0x08;
  static const int moveOffset = 0x09;
  static const int capture = 0x10;
  static const int setCutMode = 0x11;
  static const int showVideoProp = 0x12;
  static const int setCutRect = 0x13;
  static const int setCustomArea = 0x23;
  static const int setFileType = 0x28;
  static const int setJpgQuality = 0x29;
  static const int manualFocus = 0x30;
  static const int addImgToPdf = 0x31;
  static const int combinePdf = 0x32;
  static const int readIdCard = 0x80;
  static const int readIdCardEx = 0x81;
  static const int qrFromCamera = 0xA3;
  static const int qrFromFile = 0xA4;
  static const int setColorMode = 0xA0;
  static const int setDeleteBlackEdge = 0xA1;
  static const int setDeleteBgColor = 0xA2;
  static const int setDpi = 0xA9;
  static const int getDevices = 0x50;
  static const int getResolutions = 0x51;
  static const int rotate = 0x78;
  static const int ocrCall = 0xC2;
  static const int wiseCaptureStart = 0xE0;
  static const int wiseCaptureStop = 0xE1;
  static const int setZpMode = 0xE2; // 展平模式（书籍）
  static const int captureZp = 0xE3; // 展平拍摄（左右页）
  static const int release = 0xFF;
}

/// 服务端响应命令字
class KmRes {
  static const int devices = 0x50;
  static const int resolutions = 0x51;
  static const int openStatus = 0x01;
  static const int captureResult = 0x10;
  static const int frame = 0xCC;
  static const int idCard = 0x80;
  static const int idCardEx = 0x81;
  static const int barcode = 0x91;
  static const int ocr = 0xC2;
  static const int wiseCapture = 0xE0;
  static const int zpResult = 0xE3;
  static const int pdfAdd = 0x31;
  static const int pdfCombine = 0x32;
}

/// 命令构造
class KmMessage {
  /// 编码一条 0x7788 命令
  static Uint8List cmd(int command, [List<int> payload = const []]) {
    final out = Uint8List(3 + payload.length);
    out[0] = 0x77;
    out[1] = 0x88;
    out[2] = command;
    out.setRange(3, out.length, payload);
    return out;
  }

  /// 心跳（无前缀）
  static final Uint8List heartbeat = Uint8List.fromList([0x11, 0x11, 0x11]);

  /// 打开摄像头: 设备号, 画布(流)宽高, 采集宽高
  static Uint8List openCamera(int deviceIndex, int canvasW, int canvasH,
      int captureW, int captureH) {
    return cmd(KmCmd.openCamera, [
      deviceIndex & 0xff,
      canvasW >> 8 & 0xff, canvasW & 0xff,
      canvasH >> 8 & 0xff, canvasH & 0xff,
      captureW >> 8 & 0xff, captureW & 0xff,
      captureH >> 8 & 0xff, captureH & 0xff,
    ]);
  }

  /// 通用分包发送器。
  ///
  /// 包格式: [0x77,0x88,cmd, ...fixedHeader, pkgCount(2B), chunkLen(1B), pindex(2B), data(≤90)]
  /// 空 body 时发单包（pkg=1, chunk=0, pindex=0）。
  static List<Uint8List> chunked(int command, List<int> fixedHeader,
      Uint8List body) {
    final len = body.length;
    final packageCount = len == 0 ? 1 : (len / 90).ceil();
    final packets = <Uint8List>[];
    if (len == 0) {
      packets.add(cmd(command, [
        ...fixedHeader,
        0, 1, // packageCount = 1
        0, // chunkLen = 0
        0, 0, // pindex = 0
      ]));
      return packets;
    }
    int offset = 0;
    int pindex = 0;
    while (offset < len) {
      final chunkLen = (len - offset) > 90 ? 90 : (len - offset);
      final head = cmd(command, [
        ...fixedHeader,
        packageCount >> 8 & 0xff, packageCount & 0xff,
        chunkLen,
        pindex >> 8 & 0xff, pindex & 0xff,
      ]);
      final pkt = Uint8List(head.length + chunkLen);
      pkt.setRange(0, head.length, head);
      pkt.setRange(head.length, pkt.length, body, offset);
      packets.add(pkt);
      offset += chunkLen;
      pindex++;
    }
    return packets;
  }

  /// 拍照。[savePath] 为空时仅取服务端返回的 base64 图像。
  static List<Uint8List> capture(String savePath) {
    final pathBytes = savePath.isEmpty ? Uint8List(0) : _encodeUriBytes(savePath);
    final len = pathBytes.length;
    return chunked(KmCmd.capture, [
      0x00, // flag
      len >> 16 & 0xff, len >> 8 & 0xff, len & 0xff, // 总长度(3B)
    ], pathBytes);
  }

  static Uint8List moveOffset(int px, int py, int xDir, int yDir) =>
      cmd(KmCmd.moveOffset, [
        px >> 8 & 0xff, px & 0xff,
        py >> 8 & 0xff, py & 0xff,
        xDir, yDir
      ]);

  static Uint8List setCutRect(int x, int y, int w, int h) =>
      cmd(KmCmd.setCutRect, [
        x >> 8 & 0xff, x & 0xff,
        y >> 8 & 0xff, y & 0xff,
        w >> 8 & 0xff, w & 0xff,
        h >> 8 & 0xff, h & 0xff
      ]);

  static Uint8List setCustomArea(int x1, int y1, int x2, int y2) =>
      cmd(KmCmd.setCustomArea, [
        x1 >> 8 & 0xff, x1 & 0xff,
        y1 >> 8 & 0xff, y1 & 0xff,
        x2 >> 8 & 0xff, x2 & 0xff,
        y2 >> 8 & 0xff, y2 & 0xff
      ]);

  static Uint8List rotate(int angle) =>
      cmd(KmCmd.rotate, [0x00, angle & 0x03]);

  static Uint8List setZpMode(int mode) => cmd(KmCmd.setZpMode, [mode & 0xff]);

  /// 展平拍摄（书籍左右页）。头部: totalLen(3) + leftLen(3) + rightLen(3)
  static List<Uint8List> captureZp(String leftPath, String rightPath) {
    final l = _encodeUriBytes(leftPath);
    final r = _encodeUriBytes(rightPath);
    final body = Uint8List.fromList([...l, ...r]);
    final total = body.length;
    return chunked(KmCmd.captureZp, [
      total >> 16 & 0xff, total >> 8 & 0xff, total & 0xff,
      l.length >> 16 & 0xff, l.length >> 8 & 0xff, l.length & 0xff,
      r.length >> 16 & 0xff, r.length >> 8 & 0xff, r.length & 0xff,
    ], body);
  }

  /// OCR (0xC2): 头部 languageIndex(1) + totalLen(3) + imgPathLen(3) + txtPathLen(3)，
  /// body = 图片路径 + 文本输出路径 拼接
  static List<Uint8List> ocr(int languageIndex, String imgPath, String txtPath) {
    final img = _encodeUriBytes(imgPath);
    final txt = _encodeUriBytes(txtPath);
    final body = Uint8List.fromList([...img, ...txt]);
    final total = body.length;
    return chunked(KmCmd.ocrCall, [
      languageIndex & 0xff,
      total >> 16 & 0xff, total >> 8 & 0xff, total & 0xff,
      img.length >> 16 & 0xff, img.length >> 8 & 0xff, img.length & 0xff,
      txt.length >> 16 & 0xff, txt.length >> 8 & 0xff, txt.length & 0xff,
    ], body);
  }

  /// 路径型命令 (0x31添加PDF / 0x32合并PDF / 0xE0连拍目录): 头部 totalLen(3)
  static List<Uint8List> pathCommand(int command, String path) {
    final body = _encodeUriBytes(path);
    final len = body.length;
    return chunked(command, [
      len >> 16 & 0xff, len >> 8 & 0xff, len & 0xff,
    ], body);
  }

  /// 路径按 URI 编码为字节（照抄厂商 JS stringToByte(encodeURI(path))）
  static Uint8List _encodeUriBytes(String path) {
    final encoded = Uri.encodeFull(path);
    return Uint8List.fromList(encoded.codeUnits);
  }

  /// 路径字节（公开，供简单拼接型命令使用）
  static Uint8List encodePath(String path) => _encodeUriBytes(path);
}

/// 响应解析结果
sealed class KmResponse {
  const KmResponse();
}

class KmHeartbeat extends KmResponse {}

class KmDevices extends KmResponse {
  final List<String> names;
  KmDevices(this.names);
}

class KmResolutions extends KmResponse {
  final List<(int, int)> list;
  KmResolutions(this.list);
}

class KmOpenStatus extends KmResponse {
  final bool ok;
  KmOpenStatus(this.ok);
}

class KmCaptureResult extends KmResponse {
  final bool ok;
  final String path;
  final Uint8List? imageBytes;
  KmCaptureResult(this.ok, this.path, this.imageBytes);
}

class KmFrame extends KmResponse {
  final int width;
  final int height;
  final int x;
  final int y;
  final Uint8List rgb; // 直接引用消息内存，勿长期持有
  KmFrame(this.width, this.height, this.x, this.y, this.rgb);
}

class KmBarcode extends KmResponse {
  final bool ok;
  final String content;
  KmBarcode(this.ok, this.content);
}

class KmOcr extends KmResponse {
  final bool ok;
  final int progress;
  final String path; // 服务端导出的文件路径（.txt / .pdf）
  final Uint8List? exportBytes; // 随包返回的导出文件内容

  /// 服务端标志位: 0=成功 1=进度上报 40=授权失败 其它=失败
  final int flag;
  KmOcr(this.ok, this.progress, this.path, this.exportBytes, this.flag);

  bool get isProgress => flag == 1;
  bool get licenseFailed => flag == 40;

  /// 导出内容为文本时返回文本（PDF 等二进制返回空串）
  String get text {
    final b = exportBytes;
    if (b == null || b.isEmpty) return '';
    if (b.length > 4 && b[0] == 0x25 && b[1] == 0x50) return ''; // %PDF
    try {
      return utf8.decode(b, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }
}

class KmIdCard extends KmResponse {
  final bool ok;
  final List<String> fields; // name,sex,nation,born,address,cardNum,issuedAt,effectDate
  final List<Uint8List> images; // base64解码后的图
  KmIdCard(this.ok, this.fields, this.images);
}

class KmWiseCapture extends KmResponse {
  final bool ok;
  final bool steady;
  final String path;
  final Uint8List? imageBytes;
  KmWiseCapture(this.ok, this.steady, this.path, this.imageBytes);
}

class KmPdf extends KmResponse {
  final int cmd; // 0x31 添加, 0x32 合并
  final bool ok;
  final String detail;
  KmPdf(this.cmd, this.ok, this.detail);
}

class KmZpResult extends KmResponse {
  final bool ok;
  KmZpResult(this.ok);
}

class KmGeneric extends KmResponse {
  final int cmd;
  final bool ok;
  final String text;
  KmGeneric(this.cmd, this.ok, this.text);
}

/// 响应解析器
class KmParser {
  static int _be2(Uint8List d, int o) => (d[o] << 8) | d[o + 1];
  static int _be3(Uint8List d, int o) =>
      (d[o] << 16) | (d[o + 1] << 8) | d[o + 2];

  /// 解析一条完整消息；未知/过短消息返回 null
  static KmResponse? parse(Uint8List d) {
    if (d.length < 3) return null;
    if (d[0] == 0x11 && d[1] == 0x11 && d[2] == 0x11) return KmHeartbeat();
    if (d[0] != 0x55 || d[1] != 0x66) return null;
    final cmd = d[2];
    switch (cmd) {
      case KmRes.devices:
        final count = d[3];
        final names = <String>[];
        if (count > 0 && d.length > 4) {
          final raw = String.fromCharCodes(d.sublist(4));
          names.addAll(Uri.decodeFull(raw).split('|').where((s) => s.isNotEmpty));
        }
        return KmDevices(names);

      case KmRes.resolutions:
        final count = d[3];
        final list = <(int, int)>[];
        for (int i = 0; i < count; i++) {
          list.add((_be2(d, 4 + i * 4), _be2(d, 6 + i * 4)));
        }
        return KmResolutions(list);

      case KmRes.openStatus:
        return KmOpenStatus(d[3] == 0x01);

      case KmRes.captureResult:
        if (d[3] != 0x01) return KmCaptureResult(false, '', null);
        final pathLen = _be2(d, 4);
        final b64Len = _be3(d, 6);
        String path = '';
        if (pathLen > 0) {
          path = Uri.decodeFull(String.fromCharCodes(d.sublist(9, 9 + pathLen)));
        }
        Uint8List? bytes;
        if (b64Len > 0 && 9 + pathLen + b64Len <= d.length) {
          final b64 = String.fromCharCodes(
              d.sublist(9 + pathLen, 9 + pathLen + b64Len));
          try {
            bytes = base64.decode(b64);
          } catch (_) {}
        }
        return KmCaptureResult(true, path, bytes);

      case KmRes.frame:
        final w = _be2(d, 3);
        final h = _be2(d, 5);
        final x = _be2(d, 7);
        final y = _be2(d, 9);
        final expect = 11 + w * h * 3;
        if (expect != d.length) {
          // 与预期尺寸不符（或被截断），丢弃
          return null;
        }
        return KmFrame(w, h, x, y, Uint8List.sublistView(d, 11));

      case KmRes.barcode:
        final ok = d[3] == 0x01;
        String content = '';
        if (ok && d.length > 4) {
          content =
              Uri.decodeFull(String.fromCharCodes(d.sublist(4)));
        }
        return KmBarcode(ok, content);

      case KmRes.ocr:
        final flag = d[3];
        final ok = flag == 0x00;
        final progress = d.length > 4 ? d[4] : 0;
        if (!ok || d.length < 10) return KmOcr(false, progress, '', null, flag);
        final pathLen = _be2(d, 5);
        final b64Len = _be3(d, 7);
        String path = '';
        if (pathLen > 0 && 10 + pathLen <= d.length) {
          final raw = String.fromCharCodes(d.sublist(10, 10 + pathLen));
          try {
            path = Uri.decodeFull(raw);
          } catch (_) {
            path = raw;
          }
        }
        Uint8List? bytes;
        if (b64Len > 0 && 10 + pathLen + b64Len <= d.length) {
          final b64 = String.fromCharCodes(
              d.sublist(10 + pathLen, 10 + pathLen + b64Len));
          try {
            bytes = base64.decode(b64);
          } catch (_) {}
        }
        return KmOcr(true, progress, path, bytes, flag);

      case KmRes.idCard:
      case KmRes.idCardEx:
        final ok = d[3] == 0x01;
        if (!ok) return KmIdCard(false, const [], const []);
        final raw = Uri.decodeFull(String.fromCharCodes(d.sublist(4)));
        final parts = raw.split(';');
        // [0..7] 信息字段, [8] 证件照路径, [9..] base64 图像
        final fields = <String>[];
        for (int i = 0; i < 8 && i < parts.length; i++) {
          fields.add(parts[i]);
        }
        final images = <Uint8List>[];
        for (int i = 9; i < parts.length; i++) {
          try {
            images.add(base64.decode(parts[i]));
          } catch (_) {}
        }
        return KmIdCard(true, fields, images);

      case KmRes.wiseCapture:
        if (d[3] == 0x00) return KmWiseCapture(false, false, '', null);
        final steady = d[4] == 1;
        if (!steady) return KmWiseCapture(true, false, '', null);
        final pathLen = _be2(d, 5);
        final b64Len = _be3(d, 7);
        String path = '';
        Uint8List? bytes;
        if (pathLen > 0) {
          path =
              Uri.decodeFull(String.fromCharCodes(d.sublist(10, 10 + pathLen)));
        }
        if (b64Len > 0 && 10 + pathLen + b64Len <= d.length) {
          final b64 = String.fromCharCodes(
              d.sublist(10 + pathLen, 10 + pathLen + b64Len));
          try {
            bytes = base64.decode(b64);
          } catch (_) {}
        }
        return KmWiseCapture(true, true, path, bytes);

      case KmRes.zpResult:
        return KmZpResult(d[4] == 0);

      case KmRes.pdfAdd:
      case KmRes.pdfCombine:
        final ok = d[3] == 0x01;
        String detail = '';
        if (d.length > 4) {
          detail = String.fromCharCodes(d.sublist(4));
        }
        return KmPdf(cmd, ok, detail);

      default:
        // 未知命令：按通用约定 [result(1), text] 解
        String text = '';
        if (d.length > 4) {
          final raw = String.fromCharCodes(d.sublist(4));
          try {
            text = Uri.decodeFull(raw);
          } catch (_) {
            text = raw;
          }
        }
        return KmGeneric(cmd, d[3] == 0x01, text);
    }
  }
}
