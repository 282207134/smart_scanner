import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/core/protocol.dart';

void main() {
  group('命令构造', () {
    test('心跳无前缀', () {
      expect(KmMessage.heartbeat, [0x11, 0x11, 0x11]);
    });

    test('openCamera 字节布局与厂商 JS 一致', () {
      // 设备0, 画布960x540, 采集640x480
      final p = KmMessage.openCamera(0, 960, 540, 640, 480);
      expect(p, [
        0x77, 0x88, 0x01, //
        0x00, //
        0x03, 0xC0, 0x02, 0x1C, //
        0x02, 0x80, 0x01, 0xE0,
      ]);
    });

    test('capture 分包: 长路径->3包, 头部与重组正确', () {
      final path = 'C:/images/${'a' * 200}.jpg';
      final packets = KmMessage.capture(path);
      expect(packets.length, 3);
      // 第一包头: 77 88 10 00 len(3B) pkgCount=3 chunk=90 pindex=0
      final first = packets[0];
      expect(first.sublist(0, 3), [0x77, 0x88, 0x10]);
      expect(first[3], 0x00); // flag
      final totalLen = (first[4] << 16) | (first[5] << 8) | first[6];
      expect(first[7], 0x00);
      expect(first[8], 0x03); // packageCount
      expect(first[9], 90); // chunkLen
      expect(first[10], 0x00);
      expect(first[11], 0x00); // pindex 0
      // 重组 body
      final body = <int>[];
      for (var i = 0; i < packets.length; i++) {
        final pkt = packets[i];
        final chunkLen = pkt[9];
        expect((pkt[10] << 8) | pkt[11], i); // pindex 递增
        expect(chunkLen, i < 2 ? 90 : totalLen - 180);
        body.addAll(pkt.sublist(12));
      }
      expect(body.length, totalLen);
      expect(utf8.decode(body), Uri.encodeFull(path));
    });

    test('capture 空路径发单空包', () {
      final packets = KmMessage.capture('');
      expect(packets.length, 1);
      final p = packets[0];
      expect(p.sublist(0, 7), [0x77, 0x88, 0x10, 0x00, 0x00, 0x00, 0x00]);
      expect(p[8], 0x01); // packageCount=1
      expect(p[9], 0x00); // chunkLen=0
      expect(p.length, 12);
    });

    test('captureZp 头部含左右页长度', () {
      final packets = KmMessage.captureZp('C:/l.jpg', 'C:/r.jpg');
      expect(packets.length, 1);
      final p = packets[0];
      expect(p.sublist(0, 3), [0x77, 0x88, 0xE3]);
      final total = (p[3] << 16) | (p[4] << 8) | p[5];
      final leftLen = (p[6] << 16) | (p[7] << 8) | p[8];
      final rightLen = (p[9] << 16) | (p[10] << 8) | p[11];
      expect(leftLen + rightLen, total);
      final body = p.sublist(17); // 3(cmd) + 9(header) + 5(pkg meta)
      expect(utf8.decode(body.sublist(0, leftLen)), 'C:/l.jpg');
      expect(utf8.decode(body.sublist(leftLen)), 'C:/r.jpg');
    });

    test('oidc 编码中文路径为百分号字节', () {
      final bytes = KmMessage.encodePath('C:/图 片/a.jpg');
      final s = utf8.decode(bytes);
      expect(s, contains('%E5%9B%BE'));
      expect(s, isNot(contains('图片')));
    });
  });

  group('响应解析', () {
    test('设备列表(0台) —— 实机抓到过的报文', () {
      final r = KmParser.parse(Uint8List.fromList([0x55, 0x66, 0x50, 0x00]));
      expect(r, isA<KmDevices>());
      expect((r as KmDevices).names, isEmpty);
    });

    test('设备列表(2台, URL 编码名)', () {
      final names = Uri.encodeFull('USB Camera|CM-HD-1080');
      final bytes = <int>[0x55, 0x66, 0x50, 0x02, ...utf8.encode(names)];
      final r = KmParser.parse(Uint8List.fromList(bytes)) as KmDevices;
      expect(r.names, ['USB Camera', 'CM-HD-1080']);
    });

    test('打开结果', () {
      expect(
        (KmParser.parse(
          Uint8List.fromList([0x55, 0x66, 0x01, 0x01]),
        ) as KmOpenStatus).ok,
        isTrue,
      );
      expect(
        (KmParser.parse(
          Uint8List.fromList([0x55, 0x66, 0x01, 0x00]),
        ) as KmOpenStatus).ok,
        isFalse,
      );
    });

    test('预览帧 RGB 布局', () {
      const w = 2, h = 2;
      final rgb = List<int>.generate(w * h * 3, (i) => i % 256);
      final bytes = <int>[
        0x55, 0x66, 0xCC,
        w >> 8, w & 0xff, //
        h >> 8, h & 0xff, //
        0x00, 0x0A, 0x00, 0x14, // x=10,y=20
        ...rgb,
      ];
      final f = KmParser.parse(Uint8List.fromList(bytes)) as KmFrame;
      expect(f.width, 2);
      expect(f.height, 2);
      expect(f.x, 10);
      expect(f.y, 20);
      expect(f.rgb.length, 12);
      expect(f.rgb[5], 5);
    });

    test('预览帧尺寸不符时丢弃', () {
      final bytes = <int>[0x55, 0x66, 0xCC, 0, 2, 0, 2, 0, 0, 0, 0, 1, 2, 3];
      expect(KmParser.parse(Uint8List.fromList(bytes)), isNull);
    });

    test('拍照回包: 路径 + base64 图', () {
      final jpg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      final b64 = utf8.encode(base64.encode(jpg));
      final path = utf8.encode(Uri.encodeFull('C:/out/a.jpg'));
      final bytes = <int>[
        0x55, 0x66, 0x10, 0x01, //
        path.length >> 8, path.length & 0xff, //
        b64.length >> 16, b64.length >> 8, b64.length & 0xff, //
        ...path, ...b64,
      ];
      final r = KmParser.parse(Uint8List.fromList(bytes)) as KmCaptureResult;
      expect(r.ok, isTrue);
      expect(r.path, 'C:/out/a.jpg');
      expect(r.imageBytes, jpg);
    });

    test('拍照失败短包', () {
      final r = KmParser.parse(
        Uint8List.fromList([0x55, 0x66, 0x10, 0x00]),
      ) as KmCaptureResult;
      expect(r.ok, isFalse);
    });

    test('OCR 授权失败 flag=40 —— 与厂商 demo 一致', () {
      final r = KmParser.parse(
        Uint8List.fromList([0x55, 0x66, 0xC2, 0x28, 0x00]),
      ) as KmOcr;
      expect(r.ok, isFalse);
      expect(r.licenseFailed, isTrue);
    });

    test('OCR 进度上报 flag=1', () {
      final r = KmParser.parse(
        Uint8List.fromList([0x55, 0x66, 0xC2, 0x01, 0x32]),
      ) as KmOcr;
      expect(r.isProgress, isTrue);
      expect(r.progress, 50);
    });

    test('OCR 成功: 导出路径 + base64 文本', () {
      final textBytes = utf8.encode('识别结果 text');
      final b64 = utf8.encode(base64.encode(textBytes));
      final path = utf8.encode(Uri.encodeFull('C:/out/a.txt'));
      final bytes = <int>[
        0x55, 0x66, 0xC2, 0x00, 0x64, // flag=0 完成, progress=100
        path.length >> 8, path.length & 0xff, //
        b64.length >> 16, b64.length >> 8, b64.length & 0xff, //
        ...path, ...b64,
      ];
      final r = KmParser.parse(Uint8List.fromList(bytes)) as KmOcr;
      expect(r.ok, isTrue);
      expect(r.path, 'C:/out/a.txt');
      expect(r.text, '识别结果 text');
    });

    test('未知命令落到 KmGeneric', () {
      final r = KmParser.parse(
        Uint8List.fromList([0x55, 0x66, 0x77, 0x01, 0x4F, 0x4B]),
      );
      expect(r, isA<KmGeneric>());
      final g = r as KmGeneric;
      expect(g.cmd, 0x77);
      expect(g.ok, isTrue);
      expect(g.text, 'OK');
    });

    test('非协议数据返回 null', () {
      expect(KmParser.parse(Uint8List.fromList([1, 2])), isNull);
      expect(KmParser.parse(Uint8List.fromList([0x55, 0x66])), isNull);
      expect(
        KmParser.parse(Uint8List.fromList([0xAA, 0xBB, 0x01, 0x00])),
        isNull,
      );
    });
  });
}
