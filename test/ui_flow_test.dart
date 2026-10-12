// UI 流程测试（Mock 后端，不依赖真实设备/插件）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/backend/mock_backend.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/state/app_controller.dart';
import 'package:smart_scanner/theme.dart';
import 'package:smart_scanner/ui/home_page.dart';

Future<AppController> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final c = AppController();
  await c.init(
      backendOverride: MockBackend(),
      outputDirOverride: Directory.systemTemp.path);
  // 清理 Mock 的帧定时器等后台资源
  addTearDown(() async {
    await c.backend.close();
    await c.backend.disconnect();
  });
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: HomePage(controller: c),
  ));
  await tester.pumpAndSettle();
  // 让自动连接流程（Mock 内部延时）跑完，避免残留定时器
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  return c;
}

void main() {
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

    await tester.tap(find.text('拍摄'));
    await tester.pump(); // 进入拍摄中状态
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

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
    expect(find.text('读取身份证'), findsOneWidget);
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
    await tester.tap(find.text('拍摄'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(c.pages.length, 1);

    c.removePage(0);
    await tester.pumpAndSettle();
    expect(c.pages, isEmpty);
    expect(find.textContaining('已扫描 0 页'), findsOneWidget);
  });
}
