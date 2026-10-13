// UI 流程测试（Mock 后端，不依赖真实设备/插件）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/backend/mock_backend.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/core/auto_scan_detector.dart';
import 'package:smart_scanner/state/app_controller.dart';
import 'package:smart_scanner/theme.dart';
import 'package:smart_scanner/ui/home_page.dart';
import 'package:smart_scanner/ui/widgets/preview_view.dart';

class ShortcutController extends AppController {
  int exports = 0;
  @override
  Future<void> exportPdf({String? destination}) async {
    exports++;
  }
}

Future<AppController> pumpApp(
  WidgetTester tester, {
  AppController? controller,
}) async {
  // Override logical layout bounds without repeatedly resizing the native
  // Windows flutter_tester render surface between tests.
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final c = controller ?? AppController();
  await c.init(
    backendOverride: MockBackend(emitFrames: false),
    outputDirOverride: Directory.systemTemp.createTempSync('scanner_ui_').path,
  );
  // 清理 Mock 的帧定时器等后台资源
  addTearDown(() async {
    c.dispose();
  });
  final theme = buildAppTheme();
  final testTheme = theme.copyWith(
    textTheme: theme.textTheme.apply(
      fontFamily: 'Ahem',
      fontFamilyFallback: const [],
    ),
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamily: 'Ahem',
      fontFamilyFallback: const [],
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme,
      home: HomePage(controller: c),
    ),
  );
  await tester.pumpAndSettle();
  // 让自动连接流程（Mock 内部延时）跑完，避免残留定时器
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('文档与书籍切换时，多页 PDF 和输出格式保持一致', (tester) async {
    final c = await pumpApp(tester);
    c.setMultiPage(true);
    for (final mode in [ScanMode.book, ScanMode.document]) {
      c.setMode(mode);
      await tester.pumpAndSettle();
      expect(c.multiPage, isTrue);
      expect(c.outputFormat, OutputFormat.imagePdf);
      expect(find.text('多页 PDF'), findsOneWidget);
      expect(find.text('图像PDF'), findsOneWidget);
    }
    c.setOutputFormat(OutputFormat.png);
    await tester.pumpAndSettle();
    expect(c.multiPage, isFalse);
    expect(c.outputFormat, OutputFormat.png);
  });
  testWidgets('单页展平可选择左右页，手动中线可以恢复自动识别', (tester) async {
    final c = await pumpApp(tester);
    c.setMode(ScanMode.book);
    c.setFlattenMode(FlattenMode.singlePage);
    await tester.pumpAndSettle();
    expect(find.text('扫描书页'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<BookPage>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('右页').last);
    await tester.pumpAndSettle();
    expect(c.bookPage, BookPage.right);
    c.setBookSeam(.66);
    await tester.pumpAndSettle();
    expect(c.bookSeamManual, isTrue);
    await tester.tap(find.text('重新识别中线'));
    await tester.pumpAndSettle();
    expect(c.bookSeamManual, isFalse);
    expect(find.text('自动识别中线'), findsOneWidget);
  });
  testWidgets('拍摄按钮处理时失去焦点后，Ctrl+S 仍可导出', (tester) async {
    final controller = ShortcutController();
    await pumpApp(tester, controller: controller);
    Focus.of(tester.element(find.text('拍摄'))).requestFocus();
    await tester.pump();
    controller.capturing = true;
    controller.notifyListeners();
    await tester.pump();
    controller.capturing = false;
    controller.notifyListeners();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.exports, 1);
  });
  testWidgets('编辑前缀后切换 OCR，Ctrl+S 仍触发 PDF 导出快捷键', (tester) async {
    final controller = ShortcutController();
    await pumpApp(tester, controller: controller);
    await tester.tap(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, 'Test_');
    await tester.tap(find.text('OCR').first);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.exports, 1);
  });
  testWidgets('大幅拖动手动裁切角点和书脊保持原来的拖动目标', (tester) async {
    final c = await pumpApp(tester);
    c.setCutMode(CutMode.manual);
    await tester.pumpAndSettle();
    final gesture = find
        .descendant(
          of: find.byType(PreviewView),
          matching: find.byType(GestureDetector),
        )
        .first;
    final rect = tester.getRect(gesture);
    final before = c.manualRegion!.corners.toList();
    await tester.dragFrom(
      rect.topLeft +
          Offset(rect.width * before[0].x, rect.height * before[0].y),
      const Offset(45, 35),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pump();
    expect(
      c.manualRegion!.corners[0].x,
      closeTo(before[0].x + 45 / rect.width, .001),
    );
    expect(
      c.manualRegion!.corners[0].y,
      closeTo(before[0].y + 35 / rect.height, .001),
    );
    for (var i = 1; i < 4; i++) {
      expect(c.manualRegion!.corners[i].x, before[i].x);
      expect(c.manualRegion!.corners[i].y, before[i].y);
    }
    c.setMode(ScanMode.book);
    await tester.pumpAndSettle();
    final bookRect = tester.getRect(gesture);
    await tester.dragFrom(
      Offset(bookRect.left + bookRect.width * .5, bookRect.center.dy),
      const Offset(70, 0),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pump();
    expect(c.bookSeam, closeTo(.5 + 70 / bookRect.width, .001));
    await tester.pump(const Duration(milliseconds: 400));
  });
  testWidgets('自动扫描显示半透明倒计时，处理中仍可停止', (tester) async {
    final c = await pumpApp(tester);
    c.setAutoMode(true);
    await tester.pumpAndSettle();
    expect(find.text('开始自动扫描'), findsOneWidget);
    expect(find.text('静止倒计时'), findsOneWidget);
    c.autoScan = true;
    c.autoProgress = const AutoScanProgress(AutoScanPhase.countdown, 3);
    c.notifyListeners();
    await tester.pump();
    expect(find.byKey(const Key('auto-countdown')), findsOneWidget);
    expect(find.text('画面已稳定，即将拍摄'), findsOneWidget);
    c.capturing = true;
    c.notifyListeners();
    await tester.pump();
    await tester.tap(find.byKey(const Key('primary-capture')));
    await tester.pump();
    expect(c.autoScan, isFalse);
    expect(find.byKey(const Key('auto-countdown')), findsNothing);
    c.capturing = false;
  });
  testWidgets('界面可构建：标签页/参数栏/拍摄按钮都在', (tester) async {
    await pumpApp(tester);
    expect(find.text('拍摄'), findsOneWidget);
    expect(find.text('文档'), findsWidgets);
    expect(find.text('书籍'), findsWidgets);
    expect(find.text('证件'), findsWidgets);
    expect(find.text('OCR'), findsWidgets);
    expect(find.textContaining('已扫描'), findsOneWidget);
  });

  testWidgets('点“拍摄”后缩略图列表出现一页', (tester) async {
    final c = await pumpApp(tester);
    expect(c.pages, isEmpty);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('primary-capture')));
      while (c.capturing) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();

    expect(c.pages.length, 1, reason: '拍摄应产生一页');
    expect(c.pages.first.thumbnailJpg, isNotEmpty);
    expect(find.textContaining('已扫描 1 页'), findsOneWidget);
    expect(find.text('导出PDF'), findsOneWidget);
  });

  testWidgets('切换模式会更新参数栏（书籍模式出现展平选项）', (tester) async {
    final c = await pumpApp(tester);
    expect(c.mode, ScanMode.document);

    await tester.tap(find.text('书籍').first);
    await tester.pumpAndSettle();
    expect(c.mode, ScanMode.book);
    expect(find.text('展平方式'), findsOneWidget);

    await tester.tap(find.text('证件').first);
    await tester.pumpAndSettle();
    expect(c.mode, ScanMode.idCard);
    expect(
      find.text('读取身份证'),
      Platform.isMacOS ? findsNothing : findsOneWidget,
    );
  });

  testWidgets('参数栏改输出效果会传到控制器', (tester) async {
    final c = await pumpApp(tester);
    expect(c.colorEffect, ColorEffect.native);
    // 打开“输出效果”下拉并选择灰度
    await tester.tap(find.text('原生色彩').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('灰度').last);
    await tester.pumpAndSettle();
    expect(c.colorEffect, ColorEffect.grayscale);
  });

  testWidgets('删除缩略图会移除页面', (tester) async {
    final c = await pumpApp(tester);
    await tester.runAsync(c.capture);
    await tester.pumpAndSettle();
    expect(c.pages.length, 1);

    c.removePage(0);
    await tester.pumpAndSettle();
    expect(c.pages, isEmpty);
    expect(find.textContaining('已扫描 0 页'), findsOneWidget);
  });

  testWidgets('最小窗口各模式不溢出，切换证件模式同步颜色选项', (tester) async {
    final c = await pumpApp(tester);
    await tester.binding.setSurfaceSize(const Size(960, 640));
    c.setColorEffect(ColorEffect.whitePaperStamp);
    for (final mode in ScanMode.values) {
      c.setMode(mode);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: mode.label);
      expect(c.availableColorEffects, contains(c.colorEffect));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('重复点击只拍一页，重复导出 PDF 保留原始图像', (tester) async {
    final c = await pumpApp(tester);
    await tester.runAsync(() async {
      final first = c.capture();
      await c.capture();
      await first;
      expect(c.pages.length, 1);
      final original = File(c.pages.single.sourcePath);
      final bytes = await original.readAsBytes();
      await c.exportPdf();
      expect(File(c.lastExportPath).existsSync(), isTrue);
      final firstPdf = c.lastExportPath;
      await c.exportPdf();
      expect(c.lastExportPath, isNot(firstPdf));
      expect(await original.readAsBytes(), bytes);
      expect(c.pages.length, 1);
      c.removePage(0);
      expect(await original.exists(), isTrue);
    });
    await tester.pumpAndSettle();
  });

  testWidgets('自定义文件名避免覆盖并可将扫描页转为 OCR 工作区', (tester) async {
    final c = await pumpApp(tester);
    c.setNameStyle(NameStyle.custom);
    c.setPrefix('CON');
    await tester.runAsync(() async {
      await c.capture();
      await c.capture();
    });
    await tester.pumpAndSettle();
    expect(c.pages.length, 2);
    expect(c.pages[0].filePath, isNot(c.pages[1].filePath));
    expect(AppController.basename(c.pages[0].filePath), startsWith('Scan_CON'));
    c.setMode(ScanMode.ocr);
    await tester.pumpAndSettle();
    expect(find.text('识别结果'), findsOneWidget);
    await tester.runAsync(c.ocrLastCapture);
    await tester.pumpAndSettle();
    expect(c.lastOcrText, isNotEmpty);
    c.setMode(ScanMode.document);
    expect(c.outputFormat, OutputFormat.jpg);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  });
}
