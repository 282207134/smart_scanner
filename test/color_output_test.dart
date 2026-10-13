import 'dart:typed_data';

import 'package:dartcv4/dartcv.dart' as cv;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_scanner/core/document_exporter.dart';
import 'package:smart_scanner/core/document_vision.dart';
import 'package:smart_scanner/core/models.dart';

Uint8List _page() {
  final page = img.Image(width: 96, height: 64);
  img.fill(page, color: img.ColorRgb8(210, 230, 250));
  img.fillRect(
    page,
    x1: 16,
    y1: 24,
    x2: 79,
    y2: 31,
    color: img.ColorRgb8(10, 20, 30),
  );
  return Uint8List.fromList(img.encodePng(page));
}

void _expectNeutral(Uint8List bytes, {bool independent = true}) {
  var pixels = img.decodeImage(bytes)!.convert(numChannels: 3);
  if (independent) {
    // Decode independently; this OpenCV build does not include TIFF support.
    final decoded = cv.imdecode(bytes, cv.IMREAD_COLOR);
    try {
      expect(decoded.isEmpty, isFalse);
      final (ok, bmp) = cv.imencode('.bmp', decoded);
      expect(ok, isTrue);
      pixels = img.decodeBmp(bmp)!;
    } finally {
      decoded.dispose();
    }
  }
  var darkest = 255, lightest = 0;
  for (final pixel in pixels) {
    expect((pixel.r - pixel.g).abs(), lessThanOrEqualTo(2));
    expect((pixel.g - pixel.b).abs(), lessThanOrEqualTo(2));
    if (pixel.r < darkest) darkest = pixel.r.toInt();
    if (pixel.r > lightest) lightest = pixel.r.toInt();
  }
  expect(lightest, greaterThan(200));
  expect(darkest, lessThan(40));
}

Uint8List _pdfJpeg(Uint8List pdf) {
  var start = -1;
  for (var i = 0; i < pdf.length - 1; i++) {
    if (start < 0 && pdf[i] == 0xff && pdf[i + 1] == 0xd8) start = i;
    if (start >= 0 && pdf[i] == 0xff && pdf[i + 1] == 0xd9) {
      return Uint8List.sublistView(pdf, start, i + 2);
    }
  }
  throw StateError('PDF 没有内嵌 JPEG 图像');
}

void main() {
  for (final effect in [ColorEffect.grayscale, ColorEffect.blackWhite]) {
    test('${effect.name} 从实际处理到四种图片导出保持中性色', () {
      final processed = DocumentVision.process(
        VisionRequest(_page(), effect: effect),
      ).images.single;
      for (final format in [
        OutputFormat.jpg,
        OutputFormat.png,
        OutputFormat.bmp,
        OutputFormat.tif,
      ]) {
        final bytes = DocumentExporter.encodeImage(processed, format, 95);
        _expectNeutral(bytes, independent: format != OutputFormat.tif);
        final output = img.decodeImage(bytes)!;
        final paper = output.getPixel(4, 4).r;
        expect(paper, closeTo(effect == ColorEffect.grayscale ? 226 : 255, 2));
        if (effect == ColorEffect.blackWhite && format != OutputFormat.jpg) {
          expect(output.map((p) => p.r).toSet(), {0, 255});
        }
      }
    });

    test('${effect.name} PDF 内嵌图片保持中性色', () async {
      final processed = DocumentVision.process(
        VisionRequest(_page(), effect: effect),
      ).images.single;
      _expectNeutral(_pdfJpeg(await DocumentExporter.imagePdf([processed])));
    });
  }

  test('单通道书页分割后的 JPEG 保持中性色', () {
    final gray = img.decodeImage(_page())!.convert(numChannels: 1);
    final bytes = Uint8List.fromList(img.encodePng(gray));
    for (final half in DocumentExporter.splitBook(bytes)) {
      _expectNeutral(half);
    }
  });

  test('灰度证件合并后的 JPEG 保持中性色', () {
    final gray = img.decodeImage(_page())!.convert(numChannels: 1);
    final bytes = Uint8List.fromList(img.encodePng(gray));
    _expectNeutral(DocumentExporter.mergeCards(bytes, bytes));
  });

  test('灰度页面可以保留彩色印章，纸张不会变红', () {
    final gray = img.decodeImage(_page())!.convert(numChannels: 1);
    final mark = img.Image(width: 8, height: 8);
    img.fill(mark, color: img.ColorRgb8(240, 10, 10));
    final output = img.decodePng(
      DocumentExporter.addMark(
        Uint8List.fromList(img.encodePng(gray)),
        Uint8List.fromList(img.encodePng(mark)),
        .1,
        3,
      ),
    )!;
    final paper = output.getPixel(4, 4);
    expect(paper.g, paper.r);
    expect(paper.b, paper.r);
    expect(output.any((p) => p.r > 200 && p.g < 40 && p.b < 40), isTrue);
  });

  test('灰度透明图片转换时保留亮度与透明度', () {
    final grayAlpha = img.Image(width: 8, height: 8, numChannels: 2);
    for (final pixel in grayAlpha) {
      pixel[0] = 160;
      pixel[1] = 80;
    }
    final output = img.decodePng(
      DocumentExporter.encodeImage(
        Uint8List.fromList(img.encodePng(grayAlpha)),
        OutputFormat.png,
        95,
      ),
    )!;
    final pixel = output.getPixel(4, 4);
    expect([pixel.r, pixel.g, pixel.b, pixel.a], [160, 160, 160, 80]);
  });
}
