// ignore_for_file: avoid_print
import 'dart:io';

import 'package:smart_scanner/backend/km_server_backend.dart';
import 'package:smart_scanner/core/document_vision.dart';
import 'package:smart_scanner/core/models.dart';

Future<void> main() async {
  final out = Directory('build/实机图像验证');
  await out.create(recursive: true);
  final backend = KmServerBackend();
  try {
    await backend.connect();
    final device = (await backend.listDevices()).first;
    final sizes = await backend.listResolutions(device.index);
    sizes.sort(
      (a, b) => (a.width - 2592).abs().compareTo((b.width - 2592).abs()),
    );
    final size = sizes.first;
    print('${device.name} ${size.label}');
    await backend.open(
      deviceIndex: device.index,
      canvasW: 960,
      canvasH: 720,
      captureW: size.width,
      captureH: size.height,
    );
    backend.setCutMode(0);
    backend.setColorMode(0);
    backend.setDeleteBlackEdge(0);
    backend.setDeleteBgColor(0);
    final raw = await backend.captureRaw(savePath: '${out.path}/原图.jpg');
    final regions = DocumentVision.detectBytes(raw.imageBytes!);
    print(
      'Full frame regions=${regions.length}: ${regions.map((r) => r.corners.map((p) => (p.x, p.y)).toList()).toList()}',
    );
    final result = DocumentVision.process(
      VisionRequest(raw.imageBytes!, cut: CutMode.multiImg),
    );
    for (var i = 0; i < result.images.length; i++) {
      await File('${out.path}/多图_${i + 1}.png').writeAsBytes(result.images[i]);
    }
    print('Saved ${result.images.length} documents');
  } finally {
    await backend.disconnect();
  }
}
