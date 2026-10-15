// Build/run this Flutter entry point with the real Windows runner. A Dart VM
// alone cannot exercise platform channels or the native camera lifecycle.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:smart_scanner/backend/windows_camera_backend.dart';
import 'package:smart_scanner/core/document_exporter.dart';
import 'package:smart_scanner/core/models.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('正在验证 Windows 系统摄像头…'))),
    ),
  );
  final backend = WindowsCameraBackend();
  final directory = Directory(
    '${Directory.current.path}/build/validation/windows-camera',
  );
  await directory.create(recursive: true);
  final checks = <Map<String, Object?>>[];
  Future<void> save() =>
      File('${directory.path}/result.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(checks));
  void check(String name, bool passed, [Object? detail]) {
    checks.add({'check': name, 'passed': passed, 'detail': detail?.toString()});
    if (!passed) throw StateError('$name: $detail');
  }

  StreamSubscription<ScannerEvent>? events;
  try {
    events = backend.events.listen((event) {
      if (event is ConnectionEvent && !event.connected) {
        checks.add({
          'check': 'camera stream',
          'passed': false,
          'detail': event.detail,
        });
      }
    });
    await backend.connect();
    check('connect', backend.isConnected);
    final devices = await backend.listDevices();
    check(
      'enumerate devices',
      devices.isNotEmpty,
      devices.map((d) => '${d.index}: ${d.name}').join(', '),
    );
    await save();
    for (final device in devices) {
      final sizes = await backend.listResolutions(device.index);
      check(
        '${device.name}: actual resolutions',
        sizes.isNotEmpty,
        sizes.map((r) => r.label).join(', '),
      );
      sizes.sort((a, b) => (a.width * a.height).compareTo(b.width * b.height));
      final preferred =
          sizes.where((r) => r.width == 1920 && r.height == 1080).firstOrNull ??
          sizes.last;
      final selected = {
        sizes.first.label: sizes.first,
        preferred.label: preferred,
      };
      for (final size in selected.values) {
        final frame = backend.frames.first.timeout(const Duration(seconds: 18));
        await backend.open(
          deviceIndex: device.index,
          canvasW: 800,
          canvasH: 600,
          captureW: size.width,
          captureH: size.height,
        );
        final preview = await frame;
        check(
          '${device.name} ${size.label}: preview',
          preview.rgb.length == preview.width * preview.height * 3 &&
              preview.x >= 0 &&
              preview.y >= 0 &&
              preview.x + preview.width <= 800 &&
              preview.y + preview.height <= 600,
          '${preview.width}x${preview.height} at ${preview.x},${preview.y}',
        );
        backend.zoomIn();
        backend.moveOffset(12, 8, 1, 1);
        final capture = await backend.captureRaw();
        final bytes = capture.imageBytes!;
        final photo = img.decodeImage(bytes)!;
        final mean =
            photo.fold<double>(
              0,
              (sum, pixel) => sum + (pixel.r + pixel.g + pixel.b) / 3,
            ) /
            (photo.width * photo.height);
        checks.add({
          'observation': '${device.name} ${size.label}: brightness',
          'detail': mean.toStringAsFixed(2),
        });
        check(
          '${device.name} ${size.label}: full sensor photo after zoom',
          photo.width == size.width && photo.height == size.height,
          '${photo.width}x${photo.height}',
        );
        await File(
          '${directory.path}/camera${device.index}_${size.width}x${size.height}.png',
        ).writeAsBytes(bytes);
        backend.rotateRight();
        final rotated = img.decodeImage(
          (await backend.captureRaw()).imageBytes!,
        )!;
        check(
          '${device.name} ${size.label}: rotation',
          rotated.width == size.height && rotated.height == size.width,
        );
        backend.rotateLeft();
        backend.setPreviewSize(false);
        final pdf = await DocumentExporter.imagePdf([bytes]);
        await File(
          '${directory.path}/camera${device.index}_${size.width}x${size.height}.pdf',
        ).writeAsBytes(pdf);
        check('${device.name} ${size.label}: PDF', pdf.length > 100);
        if (device.index == devices.first.index &&
            size.label == preferred.label) {
          final recording = '${directory.path}/camera${device.index}.mp4';
          await backend.startRecord(recording, 0);
          await Future<void>.delayed(const Duration(seconds: 3));
          await backend.stopRecord();
          check(
            '${device.name}: camera recording',
            await File(recording).length() > 100,
          );
          final resizedFrame = backend.frames
              .firstWhere((f) => f.x + f.width <= 640 && f.y + f.height <= 480)
              .timeout(const Duration(seconds: 5));
          final resizeTime = Stopwatch()..start();
          await backend.open(
            deviceIndex: device.index,
            canvasW: 640,
            canvasH: 480,
            captureW: size.width,
            captureH: size.height,
          );
          check(
            '${device.name}: resize reuses live camera',
            resizeTime.elapsedMilliseconds < 1500,
            '${resizeTime.elapsedMilliseconds} ms',
          );
          final resized = await resizedFrame;
          check(
            '${device.name}: resized preview bounds',
            resized.rgb.length == resized.width * resized.height * 3,
          );
          final resizedPhoto = img.decodeImage(
            (await backend.captureRaw()).imageBytes!,
          )!;
          check(
            '${device.name}: resize preserves sensor photo',
            resizedPhoto.width == size.width &&
                resizedPhoto.height == size.height,
          );
        }
        await backend.close();
        check('${device.name} ${size.label}: close', !backend.isOpen);
        await save();
      }
    }
    // Unsupported dimensions fail explicitly and release the camera for retry.
    await backend.listResolutions(devices.first.index);
    var rejected = false;
    try {
      await backend.open(
        deviceIndex: devices.first.index,
        canvasW: 800,
        canvasH: 600,
        captureW: 123,
        captureH: 117,
      );
    } on PlatformException {
      rejected = true;
    }
    check('unsupported resolution rejected', rejected && !backend.isOpen);
    final sizes = await backend.listResolutions(devices.first.index);
    final size = sizes.first;
    await backend.open(
      deviceIndex: devices.first.index,
      canvasW: 640,
      canvasH: 480,
      captureW: size.width,
      captureH: size.height,
    );
    check(
      'reopen after failed open',
      (await backend.captureRaw()).imageBytes!.isNotEmpty,
    );
  } catch (error, stack) {
    checks.add({
      'check': 'exception',
      'passed': false,
      'detail': '$error\n$stack',
    });
    exitCode = 1;
  } finally {
    await backend.disconnect();
    await events?.cancel();
    await save();
    // SystemNavigator.pop can leave a hidden Windows runner message loop alive.
    // The diagnostic has already released the camera and recorder explicitly.
    exit(exitCode);
  }
}
