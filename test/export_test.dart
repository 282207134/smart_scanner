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
}
