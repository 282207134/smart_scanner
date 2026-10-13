import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_scanner/core/document_exporter.dart';
import 'package:smart_scanner/core/models.dart';

void main() {
  final image = img.Image(width: 30, height: 40);
  img.fill(image, color: img.ColorRgb8(120, 40, 180));
  final source = Uint8List.fromList(img.encodePng(image));
  test('每种图像输出具有正确的文件格式和尺寸', () {
    for (final format in [
      OutputFormat.jpg,
      OutputFormat.png,
      OutputFormat.bmp,
      OutputFormat.tif,
    ]) {
      final bytes = DocumentExporter.encodeImage(source, format, 90);
      final decoded = img.decodeImage(bytes)!;
      expect(decoded.width, 30);
      expect(decoded.height, 40);
      final pixel = decoded.getPixel(10, 10);
      expect(pixel.r, closeTo(120, 3), reason: format.name);
      expect(pixel.g, closeTo(40, 3), reason: format.name);
      expect(pixel.b, closeTo(180, 3), reason: format.name);
      expect(img.findDecoderForData(bytes)!.format, switch (format) {
        OutputFormat.jpg => img.ImageFormat.jpg,
        OutputFormat.png => img.ImageFormat.png,
        OutputFormat.bmp => img.ImageFormat.bmp,
        _ => img.ImageFormat.tiff,
      });
    }
  });
  test('重复导出 PDF 保留源图', () async {
    final dir = await Directory.systemTemp.createTemp('scanner_export_');
    final path = '${dir.path}${Platform.pathSeparator}source.png';
    await File(path).writeAsBytes(source);
    for (var n = 0; n < 2; n++) {
      final pdf = await DocumentExporter.imagePdf([
        await File(path).readAsBytes(),
        source,
      ]);
      await DocumentExporter.save(
        '${dir.path}${Platform.pathSeparator}result$n.pdf',
        pdf,
      );
      expect(utf8.decode(pdf.take(5).toList()), '%PDF-');
      expect(await File(path).readAsBytes(), source);
    }
  });
  test('Word 和 Excel 导出是有效 OOXML 包并保留特殊字符', () {
    const text = '中文 日本語 English & <测试>\n第二行';
    for (final format in [OutputFormat.word, OutputFormat.excel]) {
      final bytes = DocumentExporter.office(text, format);
      final zip = ZipDecoder().decodeBytes(bytes);
      expect(zip.findFile('[Content_Types].xml'), isNotNull);
      final name = format == OutputFormat.word
          ? 'word/document.xml'
          : 'xl/worksheets/sheet1.xml';
      final content = utf8.decode(zip.findFile(name)!.content);
      expect(content, contains('中文 日本語 English &amp; &lt;测试&gt;'));
      expect(content, contains('第二行'));
    }
  });
  test('PDF 遇到损坏图片不能报告成功', () async {
    expect(
      () => DocumentExporter.imagePdf([
        Uint8List.fromList([1, 2, 3]),
      ]),
      throwsFormatException,
    );
  });
  test('细长签章完整落在页面内并保留上下端，四个角都不截断', () {
    final page = img.Image(width: 300, height: 200);
    img.fill(page, color: img.ColorRgb8(255, 255, 255));
    final mark = img.Image(width: 20, height: 400);
    img.fill(mark, color: img.ColorRgb8(240, 10, 10));
    img.fillRect(
      mark,
      x1: 0,
      y1: 0,
      x2: 19,
      y2: 80,
      color: img.ColorRgb8(0, 30, 240),
    );
    for (var corner = 0; corner < 4; corner++) {
      final output = img.decodeImage(
        DocumentExporter.addMark(
          Uint8List.fromList(img.encodePng(page)),
          Uint8List.fromList(img.encodePng(mark)),
          .2,
          corner,
        ),
      )!;
      var red = 0, blue = 0;
      var minX = output.width, minY = output.height, maxX = -1, maxY = -1;
      for (final pixel in output) {
        if (pixel.r > 200 && pixel.g < 80 && pixel.b < 80) red++;
        if (pixel.b > 200 && pixel.r < 80) blue++;
        if (pixel.g < 80) {
          if (pixel.x < minX) minX = pixel.x;
          if (pixel.x > maxX) maxX = pixel.x;
          if (pixel.y < minY) minY = pixel.y;
          if (pixel.y > maxY) maxY = pixel.y;
        }
      }
      expect(red, greaterThan(0), reason: '签章下端丢失，角落 $corner');
      expect(blue, greaterThan(0), reason: '签章上端丢失，角落 $corner');
      expect(blue / red, closeTo(.25, .12), reason: '签章比例或范围被截断');
      expect(
        (maxX - minX + 1) / (maxY - minY + 1),
        closeTo(.05, .01),
        reason: '细长签章被压扁',
      );
    }
  });
}
