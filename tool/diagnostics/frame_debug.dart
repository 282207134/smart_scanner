// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:smart_scanner/core/ws_client.dart';

Future<void> main(List<String> args) async {
  final canvasW = args.isNotEmpty ? int.parse(args[0]) : 320;
  final canvasH = args.isNotEmpty ? int.parse(args[1]) : 240;
  stdout.writeln('== 帧调试 canvas=${canvasW}x$canvasH ==');

  final c = await WsClient.connect('127.0.0.1', 22225);
  int msgCount = 0;
  final sw = Stopwatch()..start();
  int fpsCount = 0;
  double fpsWindow = 0;
  c.messages.listen((m) {
    msgCount++;
    if (m.length > 1000) {
      fpsCount++;
      final elapsed = sw.elapsedMicroseconds / 1e6 - fpsWindow;
      if (elapsed >= 2.0) {
        stdout.writeln(
          '[fps] ${(fpsCount / elapsed).toStringAsFixed(1)} fps  (frame=${m.length}B)',
        );
        fpsWindow = sw.elapsedMicroseconds / 1e6;
        fpsCount = 0;
      }
    } else if (msgCount <= 3) {
      final head = m
          .take(12)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      stdout.writeln('MSG#$msgCount len=${m.length} head=$head');
    }
  });
  c.closes.listen((w) => stdout.writeln('CLOSE $w'));

  final heart = Timer.periodic(const Duration(seconds: 6), (_) {
    c.sendBytes([0x11, 0x11, 0x11]);
  });

  // 打开摄像头
  final capW = args.length > 2 ? int.parse(args[2]) : 2592;
  final capH = args.length > 3 ? int.parse(args[3]) : 1944;
  c.sendBytes([
    0x77,
    0x88,
    0x01,
    0x00,
    canvasW >> 8,
    canvasW & 0xff,
    canvasH >> 8,
    canvasH & 0xff,
    capW >> 8,
    capW & 0xff,
    capH >> 8,
    capH & 0xff,
  ]);
  await Future.delayed(const Duration(seconds: 5));
  stdout.writeln('total msgs: $msgCount');

  // 试着不带打开直接拍照?
  stdout.writeln('sending capture...');
  c.sendBytes([0x77, 0x88, 0x10, 0x00, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0]);
  await Future.delayed(const Duration(seconds: 8));
  stdout.writeln('total msgs: $msgCount');

  c.sendBytes([0x77, 0x88, 0x02, 0x00]);
  await Future.delayed(const Duration(milliseconds: 200));
  heart.cancel();
  c.close();
}
