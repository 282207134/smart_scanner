import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'models.dart';

class PdfImagePage {
  final List<Uint8List> images;
  final double? cardWidthMm;
  final double scale;
  const PdfImagePage(this.images, {this.cardWidthMm, this.scale = 1});
}

/// All exports consume copies of image bytes; original scans are never moved.
class DocumentExporter {
  static img.Image? _decodeColor(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    return image == null ? null : _expandGray(image);
  }

  static img.Image _expandGray(img.Image image) {
    if (image.numChannels >= 3) return image;
    // Single-channel PNG pixels expose green/blue as zero in package:image.
    // Expand luminance before RGB encoding or compositing; retain gray alpha.
    return image.convert(numChannels: image.hasAlpha ? 4 : 3);
  }

  static List<Uint8List> splitBook(Uint8List bytes) {
    final image = _decodeColor(bytes);
    if (image == null || image.width < 2) {
      throw const FormatException('无法读取书籍图像');
    }
    final middle = image.width ~/ 2;
    return [
      for (final side in [0, 1])
        Uint8List.fromList(
          img.encodeJpg(
            img.copyCrop(
              image,
              x: side == 0 ? 0 : middle,
              y: 0,
              width: side == 0 ? middle : image.width - middle,
              height: image.height,
            ),
            quality: 95,
          ),
        ),
    ];
  }

  static Uint8List encodeImage(
    Uint8List bytes,
    OutputFormat format,
    int quality,
  ) {
    final image = img.decodeImage(bytes);
    if (image == null) throw const FormatException('无法读取图像');
    return Uint8List.fromList(switch (format) {
      OutputFormat.png => img.encodePng(image),
      // Avoid the encoder's incomplete 8-bit palette and 24-bit bitfields.
      OutputFormat.bmp => img.encodeBmp(image.convert(numChannels: 4)),
      OutputFormat.tif => img.encodeTiff(image),
      _ => img.encodeJpg(_expandGray(image), quality: quality),
    });
  }

  static Uint8List resizeImage((Uint8List, double) input) {
    final image = _decodeColor(input.$1);
    if (image == null) throw const FormatException('无法读取图像');
    final scaled = img.copyResize(
      image,
      width: (image.width * input.$2).round().clamp(1, 32768),
      height: (image.height * input.$2).round().clamp(1, 32768),
      interpolation: img.Interpolation.cubic,
    );
    return Uint8List.fromList(img.encodePng(scaled));
  }

  static Future<Uint8List> imagePdf(List<Uint8List> images) => pagesPdf([
    for (final image in images) PdfImagePage([image]),
  ]);

  static Future<Uint8List> pagesPdf(List<PdfImagePage> pages) async {
    if (pages.isEmpty) throw StateError('没有可导出的图像');
    final pdf = pw.Document();
    for (final page in pages) {
      final images = [
        for (final bytes in page.images)
          _decodeColor(bytes) ??
              (throw const FormatException('PDF 中包含无法读取的图像')),
      ];
      final cardWidth = page.cardWidthMm;
      if (cardWidth != null) {
        final width = cardWidth * page.scale * PdfPageFormat.mm;
        final heights = [
          for (final image in images) width * image.height / image.width,
        ];
        const margin = 15 * PdfPageFormat.mm;
        const gap = 15 * PdfPageFormat.mm;
        final height =
            heights.fold(0.0, (sum, value) => sum + value) +
            gap * (images.length - 1);
        if (images.isEmpty ||
            width <= 0 ||
            height <= 0 ||
            width > PdfPageFormat.a4.width - margin * 2 ||
            height > PdfPageFormat.a4.height - margin * 2) {
          throw StateError('证件排版超出 A4 范围，请减小打印缩放或检查裁切');
        }
        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(margin),
            build: (_) => pw.Center(
              child: pw.Column(
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  for (var i = 0; i < images.length; i++) ...[
                    if (i > 0) pw.SizedBox(height: gap),
                    pw.Image(
                      pw.MemoryImage(img.encodeJpg(images[i], quality: 95)),
                      width: width,
                      height: heights[i],
                      fit: pw.BoxFit.contain,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
        continue;
      }
      final image = images.single;
      final raster = pw.MemoryImage(img.encodeJpg(image, quality: 95));
      final format = image.width > image.height
          ? PdfPageFormat.a4.landscape
          : PdfPageFormat.a4;
      pdf.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(18),
          build: (_) =>
              pw.Center(child: pw.Image(raster, fit: pw.BoxFit.contain)),
        ),
      );
    }
    return pdf.save();
  }

  static Uint8List mergeCards(Uint8List front, Uint8List back) {
    final a = _decodeColor(front), b = _decodeColor(back);
    if (a == null || b == null) throw const FormatException('无法读取证件图像');
    final width = a.width > b.width ? a.width : b.width;
    final second = img.copyResize(b, width: width);
    final first = img.copyResize(a, width: width);
    final canvas = img.Image(
      width: width + 80,
      height: first.height + second.height + 120,
    );
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, first, dstX: 40, dstY: 40);
    img.compositeImage(canvas, second, dstX: 40, dstY: first.height + 80);
    return Uint8List.fromList(img.encodeJpg(canvas, quality: 95));
  }

  static Uint8List addMark(
    Uint8List bytes,
    Uint8List markBytes,
    double size,
    int corner,
  ) {
    final image = _decodeColor(bytes), mark = _decodeColor(markBytes);
    if (image == null || mark == null) throw const FormatException('无法读取签名或印章');
    final margin = math.min(
      (image.width * .03).round(),
      (math.min(image.width, image.height) - 1) ~/ 2,
    );
    final maxWidth = image.width - margin * 2;
    final maxHeight = image.height - margin * 2;
    final scale = math.min(
      (image.width * size).round().clamp(1, maxWidth) / mark.width,
      maxHeight / mark.height,
    );
    final resized = img.copyResize(
      mark,
      width: (mark.width * scale).round().clamp(1, maxWidth),
      height: (mark.height * scale).round().clamp(1, maxHeight),
    );
    final x = corner == 0 || corner == 2
        ? margin
        : image.width - resized.width - margin;
    final y = corner < 2 ? margin : image.height - resized.height - margin;
    img.compositeImage(
      image,
      resized,
      dstX: x.clamp(0, image.width - 1),
      dstY: y.clamp(0, image.height - 1),
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  static String _xml(String value) =>
      const HtmlEscape(HtmlEscapeMode.element).convert(value);

  static Uint8List office(String text, OutputFormat format) {
    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    final word = format == OutputFormat.word;
    final mainPart = word ? 'word/document.xml' : 'xl/workbook.xml';
    final contentType = word
        ? 'wordprocessingml.document'
        : 'spreadsheetml.sheet';
    add(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/$mainPart" ContentType="application/vnd.openxmlformats-officedocument.$contentType.main+xml"/>${word ? '' : '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'}</Types>',
    );
    add(
      '_rels/.rels',
      '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="$mainPart"/></Relationships>',
    );
    if (word) {
      final paragraphs = text
          .split('\n')
          .map(
            (line) =>
                '<w:p><w:r><w:t xml:space="preserve">${_xml(line)}</w:t></w:r></w:p>',
          )
          .join();
      add(
        mainPart,
        '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$paragraphs<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>',
      );
    } else {
      add(
        mainPart,
        '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="识别结果" sheetId="1" r:id="rId1"/></sheets></workbook>',
      );
      add(
        'xl/_rels/workbook.xml.rels',
        '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
      );
      final rows = text
          .split('\n')
          .indexed
          .map(
            (entry) =>
                '<row r="${entry.$1 + 1}"><c r="A${entry.$1 + 1}" t="inlineStr"><is><t xml:space="preserve">${_xml(entry.$2)}</t></is></c></row>',
          )
          .join();
      add(
        'xl/worksheets/sheet1.xml',
        '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="1" width="100" customWidth="1"/></cols><sheetData>$rows</sheetData></worksheet>',
      );
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static Future<void> save(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    if (await file.length() == 0) throw StateError('文件保存失败');
  }
}
