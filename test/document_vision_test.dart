import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartcv4/dartcv.dart' as cv;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_scanner/core/document_geometry.dart';
import 'package:smart_scanner/core/document_vision.dart';
import 'package:smart_scanner/core/models.dart';

import 'fixtures/documents.dart';

void main() {
  test('自动书脊检测覆盖偏离画面中央的中缝，不能沿固定一半分割', () {
    final image = img.Image(width: 1000, height: 700);
    img.fill(image, color: img.ColorRgb8(25, 25, 25));
    img.fillRect(
      image,
      x1: 100,
      y1: 55,
      x2: 900,
      y2: 650,
      color: img.ColorRgb8(240, 240, 240),
    );
    img.drawLine(
      image,
      x1: 380,
      y1: 55,
      x2: 410,
      y2: 650,
      color: img.ColorRgb8(35, 35, 35),
      thickness: 5,
    );
    final source = cv.imdecode(
      Uint8List.fromList(img.encodePng(image)),
      cv.IMREAD_COLOR,
    );
    try {
      expect(DocumentVision.bookSpine(source, .5), closeTo(.395, .015));
    } finally {
      source.dispose();
    }
  });
  test('较大倾斜的书脊优先于表格边线，左右页中缝附近像素分别保留', () {
    final image = img.Image(width: 1000, height: 700);
    img.fill(image, color: img.ColorRgb8(25, 25, 25));
    img.fillRect(
      image,
      x1: 100,
      y1: 55,
      x2: 900,
      y2: 650,
      color: img.ColorRgb8(240, 240, 240),
    );
    img.drawLine(
      image,
      x1: 400,
      y1: 55,
      x2: 530,
      y2: 650,
      color: img.ColorRgb8(35, 35, 35),
      thickness: 5,
    );
    img.drawLine(
      image,
      x1: 500,
      y1: 350,
      x2: 500,
      y2: 620,
      color: img.ColorRgb8(35, 35, 35),
      thickness: 4,
    );
    img.fillRect(
      image,
      x1: 495,
      y1: 595,
      x2: 502,
      y2: 625,
      color: img.ColorRgb8(240, 25, 25),
    );
    img.fillRect(
      image,
      x1: 430,
      y1: 110,
      x2: 437,
      y2: 140,
      color: img.ColorRgb8(25, 25, 240),
    );
    final bytes = Uint8List.fromList(img.encodePng(image));
    final source = cv.imdecode(bytes, cv.IMREAD_COLOR);
    try {
      final layout = DocumentVision.detectBook(source);
      expect(layout.pages, hasLength(2));
      expect(layout.spineTop!.x, closeTo(.4, .015));
      expect(layout.spineBottom!.x, closeTo(.53, .015));
      for (final page in layout.pages) {
        expect(page.top, greaterThan(.05));
        expect(page.bottom, lessThan(.95));
      }
    } finally {
      source.dispose();
    }
    final output = DocumentVision.flattenBook((
      VisionRequest(bytes),
      FlattenMode.split,
      null,
    ));
    final left = img.decodePng(output.images[0])!,
        right = img.decodePng(output.images[1])!;
    // Perspective correction changes pixel density, especially near the gutter.
    // Check retained ink relative to the original, rather than assuming 1:1.
    expect(
      left.where((p) => p.r > 200 && p.g < 60 && p.b < 60).length,
      greaterThan(
        image.where((p) => p.r > 200 && p.g < 60 && p.b < 60).length * .6,
      ),
    );
    expect(
      right.where((p) => p.b > 200 && p.g < 60 && p.r < 60).length,
      greaterThan(
        image.where((p) => p.b > 200 && p.g < 60 && p.r < 60).length * .6,
      ),
    );
  });
  test('不展平保留完整图像，不触发书页检测和分割', () {
    final image = img.Image(width: 320, height: 240);
    img.fill(image, color: img.ColorRgb8(240, 240, 240));
    final output = DocumentVision.flattenBook((
      VisionRequest(Uint8List.fromList(img.encodePng(image))),
      FlattenMode.none,
      null,
    ));
    expect(output.images, hasLength(1));
    final full = img.decodeImage(output.images.single)!;
    expect((full.width, full.height), (320, 240));
  });
  test('单页展平只处理选中的左右页，空白页保留透视矫正而非整本展平', () {
    final bytes = documentFixture(multiple: true);
    for (final side in BookPage.values) {
      final output = DocumentVision.flattenBook((
        VisionRequest(bytes, bookPage: side),
        FlattenMode.singlePage,
        null,
      ));
      expect(output.images, hasLength(1));
      final page = img.decodePng(output.images.single)!;
      expect(
        page.width,
        side == BookPage.left
            ? inInclusiveRange(390, 425)
            : inInclusiveRange(290, 325),
      );
      expect(page.height, greaterThan(page.width));
      if (side == BookPage.right) expect(output.notice, contains('仅矫正书页透视'));
    }
  });
  test('自动裁切检测纸张四角并透视矫正，不保留整幅背景', () {
    final output = DocumentVision.process(
      VisionRequest(documentFixture(), cut: CutMode.auto),
    );
    expect(output.regions, hasLength(1));
    final region = output.regions.single;
    expect(region.left, closeTo(.09, .015));
    expect(region.right, closeTo(.49, .015));
    final result = img.decodeImage(output.images.single)!;
    expect(result.width, inInclusiveRange(390, 410));
    expect(result.height, inInclusiveRange(500, 525));
    expect(result.getPixel(15, 15).r, greaterThan(200));
  });
  test('多图裁切去除重复内框，按左右顺序返回两个独立文档', () {
    final output = DocumentVision.process(
      VisionRequest(documentFixture(multiple: true), cut: CutMode.multiImg),
    );
    expect(output.images, hasLength(2));
    expect(output.regions[0].left, lessThan(output.regions[1].left));
    expect(img.decodeImage(output.images[0])!.width, greaterThan(380));
    expect(
      img.decodeImage(output.images[1])!.width,
      inInclusiveRange(290, 325),
    );
  });
  test('没有完整边界时提示调整，不把全画面冒充裁切结果', () {
    final image = img.Image(width: 320, height: 240);
    img.fill(image, color: img.ColorRgb8(240, 240, 240));
    final bytes = Uint8List.fromList(img.encodePng(image));
    expect(
      () => DocumentVision.process(VisionRequest(bytes, cut: CutMode.auto)),
      throwsStateError,
    );
    expect(DocumentVision.process(VisionRequest(bytes)).images, hasLength(1));
  });
  test('手动四角在原图坐标裁切，拒绝交叉的角点', () {
    const region = DocumentRegion([
      ScanPoint(.11, .143),
      ScanPoint(.47, .1),
      ScanPoint(.49, .829),
      ScanPoint(.09, .857),
    ]);
    final output = DocumentVision.process(
      VisionRequest(documentFixture(), cut: CutMode.manual, manual: region),
    );
    expect(
      img.decodeImage(output.images.single)!.width,
      inInclusiveRange(398, 405),
    );
    expect(region.replaceCorner(0, const ScanPoint(.9, .9)).valid, isFalse);
    expect(
      () => DocumentVision.process(
        VisionRequest(documentFixture(), cut: CutMode.manual),
      ),
      throwsStateError,
    );
  });
  test('曲线矫正将弯曲行恢复为水平，验证输出像素而非仅分左右页', () {
    const w = 500, h = 600;
    final image = img.Image(width: w, height: h);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    final curves = <(double, List<double>)>[];
    for (final baseline in [100.0, 200.0, 300.0, 400.0, 500.0]) {
      double y(double x) => baseline + 25 * math.sin(x / (w - 1) * math.pi);
      curves.add((baseline, List.generate(17, (i) => y(i / 16 * (w - 1)))));
      for (var x = 0; x < w; x++) {
        for (var offset = -2; offset <= 2; offset++) {
          image.setPixelRgb(x, y(x.toDouble()).round() + offset, 0, 0, 0);
        }
      }
    }
    final mat = cv.imdecode(
      Uint8List.fromList(img.encodePng(image)),
      cv.IMREAD_COLOR,
    );
    final result = DocumentVision.remapCurves(mat, curves);
    try {
      final out = img.decodePng(cv.imencode('.png', result).$2)!;
      for (final baseline in [100, 200, 300, 400, 500]) {
        for (final x in [20, 100, 250, 400, 480]) {
          expect(out.getPixel(x, baseline).r, lessThan(60));
          expect(out.getPixel(x, baseline + 10).r, greaterThan(200));
        }
      }
      expect(DocumentVision.textCurves(mat).length, greaterThanOrEqualTo(5));
    } finally {
      result.dispose();
      mat.dispose();
    }
  });
  test('实拍书脊偏移时校准分割位置，保留靠近中缝的文字像素', () {
    final image = img.Image(width: 1000, height: 700);
    img.fill(image, color: img.ColorRgb8(25, 25, 25));
    img.fillRect(
      image,
      x1: 100,
      y1: 55,
      x2: 900,
      y2: 650,
      color: img.ColorRgb8(240, 240, 240),
    );
    img.fillRect(
      image,
      x1: 538,
      y1: 55,
      x2: 543,
      y2: 650,
      color: img.ColorRgb8(35, 35, 35),
    );
    img.fillRect(
      image,
      x1: 548,
      y1: 300,
      x2: 555,
      y2: 335,
      color: img.ColorRgb8(240, 25, 25),
    );
    final output = DocumentVision.flattenBook((
      VisionRequest(Uint8List.fromList(img.encodePng(image))),
      FlattenMode.split,
      .56,
    ));
    expect(output.images, hasLength(2));
    final page = img.decodePng(output.images[1])!;
    final redPixels = page
        .where((p) => p.r > 200 && p.g < 60 && p.b < 60)
        .length;
    expect(redPixels, greaterThan(200));
  });

  test('倾斜书脊按实际方向分割，左右页两端的文字都保留', () {
    final image = img.Image(width: 1000, height: 700);
    img.fill(image, color: img.ColorRgb8(25, 25, 25));
    img.fillRect(
      image,
      x1: 100,
      y1: 55,
      x2: 900,
      y2: 650,
      color: img.ColorRgb8(240, 240, 240),
    );
    img.drawLine(
      image,
      x1: 540,
      y1: 55,
      x2: 562,
      y2: 650,
      color: img.ColorRgb8(90, 90, 90),
      thickness: 5,
    );
    img.fillRect(
      image,
      x1: 546,
      y1: 585,
      x2: 553,
      y2: 615,
      color: img.ColorRgb8(240, 25, 25),
    );
    img.fillRect(
      image,
      x1: 546,
      y1: 120,
      x2: 553,
      y2: 150,
      color: img.ColorRgb8(25, 25, 240),
    );
    final output = DocumentVision.flattenBook((
      VisionRequest(Uint8List.fromList(img.encodePng(image))),
      FlattenMode.split,
      .55,
    ));
    final left = img.decodePng(output.images[0])!;
    final right = img.decodePng(output.images[1])!;
    expect(
      left.where((p) => p.r > 200 && p.g < 60 && p.b < 60).length,
      greaterThan(180),
    );
    expect(
      right.where((p) => p.b > 200 && p.g < 60 && p.r < 60).length,
      greaterThan(180),
    );
  });
}
