import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_scanner/backend/mock_backend.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/state/app_controller.dart';

import 'fixtures/documents.dart';

class FixtureBackend extends MockBackend {
  final Uint8List bytes;
  int captures = 0;
  FixtureBackend(this.bytes) : super(emitFrames: false);
  @override
  Future<CaptureResult> captureRaw({String savePath = ''}) async {
    captures++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return CaptureResult(savedPath: '', imageBytes: bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<AppController> setup({Uint8List? bytes}) async {
    final directory = await Directory.systemTemp.createTemp(
      'scanner_documents_',
    );
    final controller = AppController();
    await controller.init(
      backendOverride: FixtureBackend(bytes ?? documentFixture(multiple: true)),
      outputDirOverride: directory.path,
    );
    controller.connected = controller.previewOpen = true;
    controller.setNameStyle(NameStyle.sequence);
    controller.setCutMode(CutMode.multiImg);
    addTearDown(() async {
      controller.dispose();
      await directory.delete(recursive: true);
    });
    return controller;
  }

  test('一次多图扫描分别保存图片、来源和缩略图，不覆盖原文件', () async {
    final c = await setup();
    await c.capture();
    expect(c.lastError, isNull);
    expect(c.pages, hasLength(2));
    for (final page in c.pages) {
      expect(File(page.filePath).existsSync(), isTrue);
      expect(File(page.sourcePath).existsSync(), isTrue);
      expect(
        img.decodeImage(await File(page.filePath).readAsBytes())!.width,
        lessThan(450),
      );
    }
    expect(c.pages[0].filePath, endsWith('_01.jpg'));
    expect(c.pages[1].filePath, endsWith('_02.jpg'));
    final previous = c.pages.map((p) => p.filePath).toList();
    await c.capture();
    expect(c.pages, hasLength(4));
    expect(c.pages.map((p) => p.filePath).toSet(), hasLength(4));
    for (final path in previous) {
      expect(File(path).existsSync(), isTrue);
    }
  });
  test('恢复手动裁切模式后首次拍摄有有效区域，保留未裁切原图', () async {
    final directory = await Directory.systemTemp.createTemp('scanner_manual_');
    final c = AppController()..cutMode = CutMode.manual;
    await c.init(
      backendOverride: FixtureBackend(documentFixture()),
      outputDirOverride: directory.path,
    );
    c.connected = c.previewOpen = true;
    addTearDown(() async {
      c.dispose();
      await directory.delete(recursive: true);
    });
    await c.capture();
    expect(c.lastError, isNull);
    expect(c.pages, hasLength(1));
    final page = img.decodeImage(
      await File(c.pages.single.sourcePath).readAsBytes(),
    )!;
    final original = Directory('${c.outputDir}/.sources')
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.contains('_original'));
    final full = img.decodeImage(await original.readAsBytes())!;
    expect(page.width, lessThan(full.width));
    expect(page.height, lessThan(full.height));
  });
  test('多图模式为每个文档分别生成 PDF，原始整图保留', () async {
    final c = await setup();
    c.setOutputFormat(OutputFormat.imagePdf);
    await c.capture();
    expect(c.lastError, isNull);
    expect(c.pages, hasLength(2));
    for (final page in c.pages) {
      final file = File(page.filePath);
      expect(file.path, endsWith('.pdf'));
      expect(String.fromCharCodes((await file.readAsBytes()).take(4)), '%PDF');
    }
    expect(
      Directory('${c.outputDir}/.sources')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('_original')),
      hasLength(1),
    );
  });
  test('书籍和文档共用一次原图采集，左右页命名与原图保留不变', () async {
    final c = await setup();
    c.setMode(ScanMode.book);
    c.setFlattenMode(FlattenMode.split);
    await c.capture();
    expect(c.lastError, isNull);
    expect((c.backend as FixtureBackend).captures, 1);
    expect(c.pages.map((p) => AppController.basename(p.filePath)), [
      'Pic_0001_L.jpg',
      'Pic_0001_R.jpg',
    ]);
    expect(c.capturing, isFalse);
    for (final page in c.pages) {
      expect(
        img.decodeImage(await File(page.filePath).readAsBytes()),
        isNotNull,
      );
      expect(File(page.sourcePath).existsSync(), isTrue);
    }
    expect(
      Directory('${c.outputDir}/.sources')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('_original')),
      hasLength(1),
    );
  });
  test('多页 PDF 的输出选项生成真正的 PDF，书籍左右页也不被改存 JPG', () async {
    for (final mode in [ScanMode.document, ScanMode.book]) {
      final c = await setup();
      c.setMode(mode);
      c.setFlattenMode(FlattenMode.split);
      c.setMultiPage(true);
      expect(c.outputFormat, OutputFormat.imagePdf);
      await c.capture();
      expect(c.lastError, isNull);
      expect(c.pages, hasLength(2));
      for (final page in c.pages) {
        expect(page.filePath, endsWith('.pdf'));
        final bytes = await File(page.filePath).readAsBytes();
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
        expect(
          img.decodeImage(await File(page.sourcePath).readAsBytes()),
          isNotNull,
        );
      }
      await c.exportPdf();
      expect(c.lastError, isNull);
      expect(c.lastExportPath, endsWith('.pdf'));
      expect(File(c.lastExportPath).existsSync(), isTrue);
    }
  });
  test('裁切失败保留完整原图、停止自动扫描并恢复可拍摄状态', () async {
    final blank = img.Image(width: 320, height: 240);
    img.fill(blank, color: img.ColorRgb8(240, 240, 240));
    final c = await setup(bytes: Uint8List.fromList(img.encodePng(blank)));
    await c.toggleAutoScan();
    expect(c.autoScan, isTrue);
    await c.capture(automatic: true);
    expect(c.lastError, contains('拍照失败'));
    expect(c.autoScan, isFalse);
    expect(c.capturing, isFalse);
    expect(c.canCapture, isTrue);
    expect(c.pages, isEmpty);
    final original = Directory('${c.outputDir}/.sources')
        .listSync()
        .whereType<File>()
        .single;
    final image = img.decodeImage(await original.readAsBytes())!;
    expect((image.width, image.height), (320, 240));
  });
  test('自动模式切换到不支持的页面会恢复手动，裁切选项始终有效', () async {
    final c = await setup();
    c.setAutoMode(true);
    c.setMode(ScanMode.idCard);
    expect(c.autoMode, isFalse);
    expect(c.cutMode, isNot(CutMode.multiImg));
    c.capturing = true;
    final corners = c.manualRegion;
    c.rotateLeft();
    c.resetManualRegion();
    expect(c.manualRegion, same(corners));
    c.capturing = false;
  });
  test('证件两次拍摄只生成一份正反面合成，保留两份完整原图', () async {
    final c = await setup();
    c.setMode(ScanMode.idCard);
    c.setCutMode(CutMode.none);
    c.setMergeIdSides(true);
    await c.capture();
    expect(c.pages, isEmpty);
    expect(c.statusMessage, contains('正面已拍摄'));
    await c.capture();
    expect(c.lastError, isNull);
    expect(c.pages, hasLength(1));
    final image = img.decodeImage(
      await File(c.pages.single.filePath).readAsBytes(),
    )!;
    expect((image.width, image.height), (1080, 1520));
    expect((c.backend as FixtureBackend).captures, 2);
    expect(
      Directory('${c.outputDir}/.sources')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('_original')),
      hasLength(2),
    );
  });
  test('合同签章改变实际输出像素，同时保留未加签章的采集原图', () async {
    final c = await setup();
    c.setMode(ScanMode.contract);
    c.setCutMode(CutMode.none);
    final mark = img.Image(width: 40, height: 20);
    img.fill(mark, color: img.ColorRgb8(255, 0, 0));
    c.setMark(Uint8List.fromList(img.encodePng(mark)), stamp: false);
    await c.capture();
    expect(c.lastError, isNull);
    final output = img.decodeImage(
      await File(c.pages.single.filePath).readAsBytes(),
    )!;
    final pixel = output.getPixel(870, 620);
    expect(pixel.r, greaterThan(240));
    expect(pixel.g, lessThan(25));
    final original = Directory('${c.outputDir}/.sources')
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.contains('_original'));
    final untouched = img
        .decodeImage(await original.readAsBytes())!
        .getPixel(870, 620);
    expect(untouched.r, lessThan(100));
    expect(untouched.g, greaterThan(20));
  });
}
