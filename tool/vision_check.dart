// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dartcv4/dartcv.dart' as cv;
import 'package:smart_scanner/core/document_vision.dart';
import 'package:smart_scanner/core/models.dart';

Future<void> main(List<String> args) async {
  final bytes = await File(args.first).readAsBytes();
  final dir = Directory(args.length > 1 ? args[1] : 'build/vision_check');
  final seam = args.length > 2 ? double.parse(args[2]) : .5;
  await dir.create(recursive: true);
  final regions = DocumentVision.detectBytes(bytes);
  print(
    'Detected ${regions.length}: ${regions.map((r) => r.corners.map((p) => (p.x.toStringAsFixed(3), p.y.toStringAsFixed(3))).toList()).toList()}',
  );
  final source = cv.imdecode(bytes, cv.IMREAD_COLOR);
  print(
    'Book spine: guide=$seam detected=${DocumentVision.bookSpine(source, seam)}',
  );
  for (var i = 0; i < regions.length; i++) {
    final page = DocumentVision.warp(source, regions[i]);
    final curves = DocumentVision.textCurves(page);
    print('Page $i: ${page.cols}x${page.rows}; curves=${curves.length}');
    await File('${dir.path}/crop_$i.png')
        .writeAsBytes(cv.imencode('.png', page).$2);
    page.dispose();
  }
  source.dispose();
  for (final mode in [FlattenMode.split, FlattenMode.flatten]) {
    try {
      final result = DocumentVision.flattenBook((
        VisionRequest(bytes),
        mode,
        seam,
      ));
      for (var i = 0; i < result.images.length; i++) {
        if (mode == FlattenMode.split) {
          final page = cv.imdecode(result.images[i], cv.IMREAD_COLOR);
          final curves = DocumentVision.textCurves(page);
          print(
            'Half $i ${page.cols}x${page.rows}: ${curves.map((c) => (c.$1.toInt(), c.$2.map((v) => v.toInt()).toList())).toList()}',
          );
          page.dispose();
        }
        await File('${dir.path}/${mode.name}_$i.png')
            .writeAsBytes(result.images[i]);
        if (mode == FlattenMode.flatten) {
          final page = cv.imdecode(result.images[i], cv.IMREAD_COLOR);
          final curves = DocumentVision.textCurves(page);
          print(
            'Flattened half $i: ${curves.map((c) => (c.$1.toInt(), (c.$2.reduce((a, b) => a > b ? a : b) - c.$2.reduce((a, b) => a < b ? a : b)).toStringAsFixed(1))).toList()}',
          );
          page.dispose();
        }
      }
      print('${mode.name}: ${result.images.length} pages');
    } catch (e) {
      print('${mode.name}: $e');
    }
  }
}
