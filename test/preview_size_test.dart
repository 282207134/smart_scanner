import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/backend/mac_avf_backend.dart';
import 'package:smart_scanner/backend/mock_backend.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/state/app_controller.dart';
import 'package:smart_scanner/ui/widgets/left_toolbar.dart';

class PreviewSizeBackend extends MockBackend {
  PreviewSizeBackend() : super(emitFrames: false);
  final sizes = <bool>[];
  @override
  void setPreviewSize(bool maximized) => sizes.add(maximized);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Mac 显示大小只发送预览指令，不重新打开或更改拍摄分辨率', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('smart_scanner/native');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final backend = MacAvfBackend();
    backend.setPreviewSize(true);
    backend.setPreviewSize(false);
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['setting', 'setting']);
    expect(calls.map((c) => c.arguments), [
      {'key': 'previewSize', 'value': true},
      {'key': 'previewSize', 'value': false},
    ]);
  });

  testWidgets('工具栏倒数第 3/1 个按钮切换显示大小，忙碌时禁用', (tester) async {
    final backend = PreviewSizeBackend();
    final c = AppController();
    await c.init(
      backendOverride: backend,
      outputDirOverride: Directory.systemTemp.path,
    );
    addTearDown(c.dispose);
    c.connected = c.previewOpen = true;
    c.resolution = const ScanResolution(4160, 3120);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: c,
          builder: (_, _) => Scaffold(body: LeftToolbar(controller: c)),
        ),
      ),
    );
    final tooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message)
        .toList();
    expect(tooltips.sublist(tooltips.length - 3), [
      '缩小化视频区域',
      '手动对焦',
      '最大化视频区域',
    ]);
    await tester.tap(find.byTooltip('最大化视频区域'));
    await tester.tap(find.byTooltip('缩小化视频区域'));
    await tester.tap(find.byTooltip('缩小化视频区域'));
    expect(backend.sizes, [true, false, false]);
    expect(c.resolution?.label, '4160×3120');
    c.capturing = true;
    c.notifyListeners();
    await tester.pump();
    final button = tester.widget<IconButton>(
      find.descendant(
        of: find.byTooltip('最大化视频区域'),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
    c.maximizePreview();
    expect(backend.sizes, [true, false, false]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
