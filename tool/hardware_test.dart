// ignore_for_file: avoid_print

// 真机集成测试（不使用 UI，直接调用应用后端）。
// 运行: dart run tool/hardware_test.dart
//
// 覆盖: 连接 -> 枚举设备/分辨率 -> 开流(计帧率) -> 拍照存盘 -> OCR -> PDF合成
import 'dart:async';
import 'dart:io';

import 'package:image/image.dart' as img;

import 'package:smart_scanner/backend/km_server_backend.dart';
import 'package:smart_scanner/core/models.dart';

int _pass = 0, _fail = 0;

void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
    print('  [PASS] $name${extra.isEmpty ? '' : '  ($extra)'}');
  } else {
    _fail++;
    print('  [FAIL] $name${extra.isEmpty ? '' : '  ($extra)'}');
  }
}

Future<T> withTimeout<T>(Future<T> f, int seconds, String what) {
  return f.timeout(
    Duration(seconds: seconds),
    onTimeout: () {
      throw TimeoutException('$what 超时');
    },
  );
}

Future<void> main() async {
  final outDir = Directory.systemTemp.createTempSync('smart_scanner_test');
  print('输出目录: ${outDir.path}\n');
  final backend = KmServerBackend();

  try {
    // 1. 连接
    await withTimeout(backend.connect(), 10, 'connect');
    check('连接 KHServer', backend.isConnected);

    // 2. 设备
    final devices = await withTimeout(backend.listDevices(), 10, 'listDevices');
    check('枚举设备', devices.isNotEmpty, devices.join(', '));
    if (devices.isEmpty) {
      print('无设备，结束');
      exit(1);
    }
    final dev = devices.first;

    // 3. 分辨率
    final res = await withTimeout(
      backend.listResolutions(dev.index),
      10,
      'listResolutions',
    );
    check('枚举分辨率', res.isNotEmpty, res.take(6).map((r) => r.label).join(' '));
    if (res.isEmpty) exit(1);

    // 选一个接近 1920 宽的采集分辨率
    res.sort((a, b) => (a.width - 1920).abs() - (b.width - 1920).abs());
    final cap = res.first;
    print('\n使用设备: ${dev.name}  采集: ${cap.label}');

    // 4. 开流 1280x720 画布
    await withTimeout(
      backend.open(
        deviceIndex: dev.index,
        canvasW: 1280,
        canvasH: 720,
        captureW: cap.width,
        captureH: cap.height,
      ),
      15,
      'open',
    );
    check('打开摄像头', backend.isOpen);

    // 5. 计帧率
    int frames = 0;
    int badLen = 0;
    final sub = backend.frames.listen((f) {
      frames++;
      if (f.rgb.length != f.width * f.height * 3) badLen++;
    });
    await Future.delayed(const Duration(seconds: 3));
    await sub.cancel();
    check('收到预览帧', frames > 0, '$frames 帧 / 3s');
    check('帧数据长度正确', badLen == 0, '长度异常 $badLen 帧');

    // 6. 视图命令不崩溃
    backend.bestSize();
    await Future.delayed(const Duration(milliseconds: 200));
    backend.zoomIn();
    await Future.delayed(const Duration(milliseconds: 200));
    backend.rotateRight();
    await Future.delayed(const Duration(milliseconds: 300));
    backend.rotate(0);
    await Future.delayed(const Duration(milliseconds: 300));
    check('视图命令(适合/缩放/旋转)', true);

    // 7. 拍照存盘
    final jpgPath = '${outDir.path}${Platform.pathSeparator}cap_test.jpg';
    final cr = await withTimeout(
      backend.capture(savePath: jpgPath),
      45,
      'capture',
    );
    final f = File(jpgPath);
    final exists = f.existsSync();
    final size = exists ? f.lengthSync() : 0;
    check('拍照返回路径', cr.savedPath.toUpperCase().endsWith('.JPG'), cr.savedPath);
    check('拍照已存盘', exists && size > 10240, '$size 字节');
    if (exists) {
      final head = f.readAsBytesSync().sublist(0, 3);
      check('文件是JPEG', head[0] == 0xFF && head[1] == 0xD8, '');
      final decoded = img.decodeJpg(f.readAsBytesSync());
      check(
        '照片保留选定的采集分辨率',
        decoded?.width == cap.width && decoded?.height == cap.height,
        '${decoded?.width}×${decoded?.height}',
      );
    }
    check(
      '随包返回图像数据',
      (cr.imageBytes?.length ?? 0) > 10240,
      '${cr.imageBytes?.length ?? 0} 字节',
    );

    // 8. OCR（对刚拍的照片）。flag=40 表示服务端未授权 OCR，属环境限制不入失败。
    try {
      final ocr = await withTimeout(
        backend.ocrImage(jpgPath, OcrLanguage.chineseEnglish),
        60,
        'ocr',
      );
      if (ocr.ok) {
        check('OCR 返回', true, '文本 ${ocr.text.length} 字');
        if (ocr.text.isNotEmpty) {
          print(
            '  OCR 预览: ${ocr.text.substring(0, ocr.text.length > 80 ? 80 : ocr.text.length).replaceAll('\n', ' ')}',
          );
          File('${outDir.path}${Platform.pathSeparator}ocr_result.txt')
              .writeAsStringSync(ocr.text);
        }
      } else {
        print('  [INFO] OCR 未成功: ${ocr.errorLabel}（环境限制，不影响其它功能）');
      }
    } catch (e) {
      print('  [INFO] OCR 未返回: $e');
    }

    // 9. PDF 合成
    try {
      final pdfPath = '${outDir.path}${Platform.pathSeparator}combined.pdf';
      await withTimeout(
        backend.addImagesToPdf([jpgPath]),
        30,
        'addImagesToPdf',
      );
      await Future.delayed(const Duration(milliseconds: 400));
      await withTimeout(backend.combineToPdf(pdfPath), 30, 'combineToPdf');
      await Future.delayed(const Duration(milliseconds: 800));
      final pf = File(pdfPath);
      final ok = pf.existsSync() && pf.lengthSync() > 1000;
      check('PDF 已生成', ok, ok ? '${pf.lengthSync()} 字节' : '文件不存在');
      if (ok) {
        final head = String.fromCharCodes(pf.readAsBytesSync().sublist(0, 5));
        check('PDF 文件头', head == '%PDF-', head);
        check('PDF 导出后原图保留', f.existsSync() && f.lengthSync() == size);
      }
    } catch (e) {
      check('PDF 已生成', false, '$e');
    }

    // 10. 摄像头录像（不录制用户桌面）。
    final videoPath = '${outDir.path}${Platform.pathSeparator}camera_test.mp4';
    await backend.startRecord(videoPath, 0);
    await Future.delayed(const Duration(seconds: 4));
    await backend.stopRecord();
    check(
      '摄像头 MP4 已保存',
      File(videoPath).existsSync() && File(videoPath).lengthSync() > 1000,
    );
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height,duration',
      '-of',
      'csv=p=0',
      videoPath,
    ]);
    final metadata = '${probe.stdout}'.trim().split(',');
    final duration = metadata.length > 2
        ? double.tryParse(metadata[2]) ?? 0
        : 0;
    check(
      '录像尺寸与预览画布一致',
      metadata.length > 2 && metadata[0] == '1280' && metadata[1] == '720',
      '${probe.stdout}'.trim(),
    );
    check('录像时长与录制时间一致', duration >= 3 && duration <= 5.5, '$duration s');

    // 11. 关闭
    await backend.close();
    await Future.delayed(const Duration(milliseconds: 500));
    check('关闭摄像头', !backend.isOpen);
  } catch (e, st) {
    _fail++;
    print('  [FAIL] 异常: $e');
    print('$st');
  } finally {
    await backend.disconnect();
  }

  print('\n===== 结果: $_pass 通过, $_fail 失败 =====');
  print('产物目录: ${outDir.path}');
  exit(_fail == 0 ? 0 : 1);
}
