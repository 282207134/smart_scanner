import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_scanner/backend/mock_backend.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/state/app_controller.dart';

class SwitchingBackend extends MockBackend {
  final closed = Completer<void>();
  int captures = 0;
  SwitchingBackend() : super(emitFrames: false);
  @override
  Future<void> close() => closed.future;
  @override
  Future<CaptureResult> captureRaw({String savePath = ''}) async {
    captures++;
    return super.captureRaw(savePath: savePath);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppController c;
  late String first, second, broken;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('scanner_pages_');
    c = AppController();
    await c.init(
      backendOverride: MockBackend(emitFrames: false),
      outputDirOverride: '${directory.path}/output',
    );
    final image = img.Image(width: 40, height: 60);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    final bytes = img.encodePng(image);
    first = '${directory.path}/第一页.png';
    second = '${directory.path}/第二页.png';
    broken = '${directory.path}/损坏.png';
    await File(first).writeAsBytes(bytes);
    await File(second).writeAsBytes(bytes);
    await File(broken).writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    c.dispose();
    await directory.delete(recursive: true);
  });

  test('移动另一页成为当前页时同步 OCR 和图像来源，导出使用当前页', () async {
    await c.importPages([first, second]);
    for (var i = 0; i < c.pages.length; i++) {
      final page = c.pages[i];
      c.pages[i] = CapturedPage(
        filePath: page.filePath,
        sourcePath: page.sourcePath,
        thumbnailJpg: Uint8List(0),
        time: page.time,
        ocrText: '第${i + 1}页识别结果',
      );
    }
    c.selectPage(1);
    c.movePage(0, 1);
    expect(c.currentPage!.filePath, first);
    expect(c.lastCapturePath, c.currentPage!.sourcePath);
    expect(c.lastOcrText, '第1页识别结果');
    c.setOutputFormat(OutputFormat.txt);
    await c.exportOcr();
    expect(await File(c.lastExportPath).readAsString(), '第1页识别结果');
  });

  test('批量导入跳过坏图并继续后续文件，准确报告成功和失败数量', () async {
    await c.importPages([first, broken, second]);
    expect(c.pages.map((p) => p.filePath), [first, second]);
    expect(c.statusMessage, contains('2'));
    expect(c.lastError, contains('损坏.png'));
    expect(c.exporting, isFalse);
    for (final page in c.pages) {
      expect(
        img.decodeImage(await File(page.sourcePath).readAsBytes()),
        isNotNull,
      );
    }
  });

  test('重复导入同一张图片不产生重复列表项，勾选和 PDF 页数保持一致', () async {
    await c.importPages([first, first, second]);
    final page = c.pages.first;
    c.pages[0] = CapturedPage(
      filePath: page.filePath,
      sourcePath: page.sourcePath,
      thumbnailJpg: page.thumbnailJpg,
      time: page.time,
      ocrText: '已经校对过的文字',
    );
    await c.importPages([first]);
    expect(c.pages, hasLength(2));
    expect(c.pages.map((p) => p.filePath).toSet(), hasLength(2));
    expect(c.pages.singleWhere((p) => p.filePath == first).ocrText, '已经校对过的文字');
    c.toggleSelected(first);
    expect(
      c.pages.where((p) => c.selectedPaths.contains(p.filePath)),
      hasLength(1),
    );
    expect(await File(first).readAsBytes(), isNotEmpty);
    expect(
      Directory('${c.outputDir}/.sources').listSync().whereType<File>(),
      hasLength(2),
    );
  });
  test('新增页面后清空前一页 OCR，未识别的新页不能导出旧文字', () async {
    await c.importPages([first]);
    c.lastOcrText = '上一页的识别结果';
    await c.importPages([second]);
    expect(c.currentPage!.filePath, second);
    expect(c.lastOcrText, isEmpty);
    await c.exportOcr();
    expect(c.lastExportPath, isEmpty);
  });
  test('切换分辨率关闭旧预览期间禁止拍摄，打开完成后恢复', () async {
    final backend = SwitchingBackend();
    final other = AppController();
    await other.init(backendOverride: backend, outputDirOverride: c.outputDir);
    await other.refreshResolutions();
    other.connected = other.previewOpen = true;
    other.resolution = const ScanResolution(1920, 1080);
    final switching = other.selectResolution(const ScanResolution(1280, 720));
    try {
      expect(other.canCapture, isFalse);
      await other.capture();
      expect(backend.captures, 0);
    } finally {
      backend.closed.complete();
      await switching;
      expect(other.previewOpen, isTrue);
      expect(other.canCapture, isTrue);
      other.dispose();
    }
  });
}
