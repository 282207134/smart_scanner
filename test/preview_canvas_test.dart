import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/core/document_geometry.dart';
import 'package:smart_scanner/state/app_controller.dart';
import 'package:smart_scanner/ui/widgets/preview_view.dart';

class CanvasController extends AppController {
  final moves = <(int, int)>[];
  @override
  Future<void> setCanvasSize(int w, int h) async {}
  @override
  void panDrag(int dx, int dy) => moves.add((dx, dy));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CanvasController> canvas(WidgetTester tester) async {
    final c = CanvasController();
    addTearDown(c.dispose);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.black, BlendMode.src);
    final picture = recorder.endRecording();
    c.previewImage = await tester.runAsync(() => picture.toImage(568, 368));
    picture.dispose();
    c.connected = c.previewOpen = true;
    c.previewImageX = .25;
    c.previewImageY = .125;
    c.previewImageWidth = .5;
    c.previewImageHeight = .75;
    return c;
  }

  Future<void> pumpCanvas(WidgetTester tester, AppController c) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: const Key('canvas-pixels'),
            child: SizedBox(
              width: 600,
              height: 400,
              child: PreviewView(controller: c),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('黑色视频之外显示蓝色网格，视频内部保留纯黑像素', (tester) async {
    final c = await canvas(tester);
    await pumpCanvas(tester, c);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('canvas-pixels')),
    );
    final screenshot = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => screenshot!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    List<int> rgb(int x, int y) {
      final offset = (y * screenshot!.width + x) * 4;
      return data!.buffer.asUint8List(offset, 3).toList();
    }

    expect(rgb(300, 200), [0, 0, 0]);
    expect(rgb(35, 55)[2], greaterThan(20));
    expect(rgb(40, 55), isNot(rgb(35, 55)), reason: '网格线不能被黑色留白覆盖');
    screenshot!.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自动裁切模式也能拖动画面，拖动背景不会移动视频', (tester) async {
    final c = await canvas(tester);
    c.cutMode = CutMode.auto;
    await pumpCanvas(tester, c);
    await tester.dragFrom(const Offset(300, 200), const Offset(35, 20));
    expect(c.moves, isNotEmpty);
    c.moves.clear();
    await tester.dragFrom(const Offset(50, 80), const Offset(40, 30));
    expect(c.moves, isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('视频边缘上的手动裁切角点仍可拖动', (tester) async {
    final c = await canvas(tester);
    c.cutMode = CutMode.manual;
    c.manualRegion = const DocumentRegion([
      ScanPoint(0, 0),
      ScanPoint(1, 0),
      ScanPoint(1, 1),
      ScanPoint(0, 1),
    ]);
    await pumpCanvas(tester, c);
    await tester.dragFrom(
      const Offset(442, 338),
      const Offset(-35, -20),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    expect(c.manualRegion!.corners[2].x, closeTo(1 - 35 / 284, .001));
    expect(c.manualRegion!.corners[2].y, closeTo(1 - 20 / 276, .001));
    expect(c.moves, isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OCR 空画布也显示网格', (tester) async {
    final c = CanvasController()..mode = ScanMode.ocr;
    addTearDown(c.dispose);
    await pumpCanvas(tester, c);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('canvas-pixels')),
    );
    final screenshot = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => screenshot!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    final bytes = data!.buffer.asUint8List();
    final background = (55 * screenshot!.width + 35) * 4;
    final grid = (55 * screenshot.width + 24) * 4;
    expect(bytes[background + 2], greaterThan(20));
    expect(bytes[grid + 2], greaterThan(bytes[background + 2]));
    screenshot.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
