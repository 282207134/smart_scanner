import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/core/auto_scan_detector.dart';
import 'package:smart_scanner/core/models.dart';

PreviewFrame fineText({int shift = 0, bool anotherPage = false}) {
  const w = 480, h = 360;
  final bytes = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var value = 20;
      if (x >= 50 && x < 430 && y >= 30 && y < 330) {
        value = 220;
        if (y % 14 >= 3 &&
            y % 14 <= 5 &&
            (x + shift) % 10 < (anotherPage ? 7 : 3)) {
          value = 40;
        }
      }
      final i = (y * w + x) * 3;
      bytes[i] = bytes[i + 1] = bytes[i + 2] = value;
    }
  }
  return PreviewFrame(width: w, height: h, x: 0, y: 0, rgb: bytes);
}

PreviewFrame scene({int pattern = 0, int brightness = 0}) {
  const w = 192, h = 144;
  final bytes = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final value =
          ((x ~/ 20 + y ~/ 20 + pattern) % 3 == 0 ? 70 : 180) + brightness;
      final i = (y * w + x) * 3;
      bytes[i] = bytes[i + 1] = bytes[i + 2] = value;
    }
  }
  return PreviewFrame(width: w, height: h, x: 0, y: 0, rgb: bytes);
}

void main() {
  test('稳定后倒计时，只拍一次；换页稳定后再次拍摄', () {
    final detector = AutoScanDetector(delay: const Duration(seconds: 2));
    var phase = AutoScanPhase.waiting;
    for (var t = 0; t <= 2800; t += 100) {
      phase = detector.feed(scene(), Duration(milliseconds: t)).phase;
    }
    expect(phase, AutoScanPhase.capture);
    detector.markCaptured();
    for (var t = 3000; t < 7000; t += 100) {
      expect(
        detector.feed(scene(), Duration(milliseconds: t)).phase,
        AutoScanPhase.captured,
      );
      expect(
        detector.tick(Duration(milliseconds: t + 50)).phase,
        AutoScanPhase.captured,
      );
    }
    expect(
      detector
          .feed(scene(pattern: 1), const Duration(milliseconds: 7000))
          .phase,
      AutoScanPhase.moving,
    );
    for (var t = 7100; t <= 9900; t += 100) {
      phase = detector.feed(scene(pattern: 1), Duration(milliseconds: t)).phase;
    }
    expect(phase, AutoScanPhase.capture);
  });
  test('画面变化取消倒计时，轻微整体亮度变化不重复拍摄', () {
    final detector = AutoScanDetector();
    detector.feed(scene(), Duration.zero);
    expect(
      detector.feed(scene(), const Duration(seconds: 1)).phase,
      AutoScanPhase.countdown,
    );
    expect(
      detector
          .feed(scene(pattern: 1), const Duration(milliseconds: 1100))
          .phase,
      AutoScanPhase.moving,
    );
    detector.markCaptured();
    expect(
      detector
          .feed(scene(pattern: 1, brightness: 10), const Duration(seconds: 2))
          .phase,
      AutoScanPhase.captured,
    );
  });
  test('无文档或摄像头帧中断时不触发拍摄', () {
    final detector = AutoScanDetector(delay: const Duration(seconds: 1));
    detector.feed(scene(), Duration.zero, eligible: false);
    expect(
      detector.tick(const Duration(seconds: 10)).phase,
      AutoScanPhase.waiting,
    );
    detector.feed(scene(), const Duration(seconds: 11));
    expect(
      detector.tick(const Duration(seconds: 15)).phase,
      AutoScanPhase.waiting,
    );
    expect(
      detector.feed(scene(), const Duration(seconds: 16)).phase,
      AutoScanPhase.moving,
    );
  });
  test('细字一像素采样变化不重复拍摄，恢复预览短暂变化不启动倒计时', () {
    final detector = AutoScanDetector();
    detector.feed(fineText(), Duration.zero);
    detector.markCaptured(now: const Duration(seconds: 10));
    expect(
      detector.feed(scene(pattern: 1), const Duration(seconds: 11)).phase,
      AutoScanPhase.captured,
    );
    for (var t = 12000; t < 25000; t += 200) {
      expect(
        detector.feed(fineText(shift: 1), Duration(milliseconds: t)).phase,
        AutoScanPhase.captured,
      );
      expect(
        detector.tick(Duration(milliseconds: t + 100)).phase,
        AutoScanPhase.captured,
      );
    }
    var phase = AutoScanPhase.waiting;
    for (var t = 25000; t <= 29000; t += 200) {
      phase = detector
          .feed(fineText(anotherPage: true), Duration(milliseconds: t))
          .phase;
    }
    expect(phase, AutoScanPhase.capture);
  });
}
