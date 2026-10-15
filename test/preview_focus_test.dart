import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/backend/native_camera_backend.dart';
import 'package:smart_scanner/backend/mock_backend.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/state/app_controller.dart';
import 'package:smart_scanner/ui/widgets/left_toolbar.dart';
import 'package:smart_scanner/ui/widgets/preview_view.dart';

class FocusBackend extends MockBackend {
  FocusBackend() : super(emitFrames: false);
  int requests = 0;
  Completer<void> response = Completer<void>();
  @override
  Future<void> manualFocus() {
    requests++;
    return response.future;
  }
}

class PreviewSizeController extends AppController {
  (int, int)? requestedSize;
  @override
  bool get supportsHighDensityPreview => true;
  @override
  Future<void> setCanvasSize(int w, int h) async {
    requestedSize = (w, h);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> controller(FocusBackend backend) async {
    final c = AppController();
    await c.init(
      backendOverride: backend,
      outputDirOverride: Directory.systemTemp.path,
    );
    c.connected = c.previewOpen = true;
    c.resolution = const ScanResolution(1920, 1080);
    addTearDown(c.dispose);
    return c;
  }

  test('Mac 对焦等待原生回执，并将不支持对焦的错误传回调用方', () async {
    const channel = MethodChannel('smart_scanner/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final accepted = Completer<void>();
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      await accepted.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final backend = NativeCameraBackend();
    var completed = false;
    final request = backend.manualFocus().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(received?.method, 'setting');
    expect(received?.arguments, {'key': 'focus', 'value': true});
    expect(completed, isFalse);
    accepted.complete();
    await request;
    expect(completed, isTrue);

    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'SCANNER', message: '当前相机不支持自动对焦');
    });
    await expectLater(backend.manualFocus(), throwsA(isA<PlatformException>()));
  });

  testWidgets('手动对焦立即显示处理中，阻止重复指令，失败后可以重试', (tester) async {
    final backend = FocusBackend();
    final c = await controller(backend);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: c,
          builder: (_, _) => Scaffold(body: LeftToolbar(controller: c)),
        ),
      ),
    );
    await tester.tap(find.byTooltip('手动对焦'));
    await tester.pump();
    expect(backend.requests, 1);
    expect(c.focusing, isTrue);
    expect(c.canCapture, isFalse);
    expect(c.statusMessage, '正在重新对焦…');
    final button = tester.widget<IconButton>(
      find.descendant(
        of: find.byTooltip('正在重新对焦…'),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
    await c.manualFocus();
    expect(backend.requests, 1);
    backend.response.completeError(
      PlatformException(code: 'SCANNER', message: '当前相机不支持自动对焦'),
    );
    await tester.pump();
    expect(c.focusing, isFalse);
    expect(c.lastError, '对焦失败：当前相机不支持自动对焦');
    backend.response = Completer<void>();
    await tester.tap(find.byTooltip('手动对焦'));
    backend.response.complete();
    await tester.pump();
    expect(backend.requests, 2);
    expect(c.lastError, isNull);
    expect(c.statusMessage, '已触发重新对焦，请等待画面稳定');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('没有预览时不发送对焦指令', () async {
    final backend = FocusBackend();
    final c = await controller(backend);
    c.previewOpen = false;
    await c.manualFocus();
    expect(backend.requests, 0);
  });

  testWidgets('连续帧刷新不会一直推迟预览尺寸更新', (tester) async {
    final c = await controller(FocusBackend());
    for (var i = 0; i < 5; i++) {
      await c.setCanvasSize(1180, 560);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.canvasSize, (1180, 560));
    expect(c.previewOpen, isTrue);
  });

  testWidgets('窗口恢复原尺寸会取消过期的尺寸请求', (tester) async {
    final c = await controller(FocusBackend());
    await c.setCanvasSize(1180, 560);
    await tester.pump(const Duration(milliseconds: 100));
    await c.setCanvasSize(640, 480);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.canvasSize, (640, 480));
  });

  testWidgets('Mac Retina 预览按实际像素请求画布', (tester) async {
    final c = PreviewSizeController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            height: 400,
            child: MediaQuery(
              data: const MediaQueryData(devicePixelRatio: 2),
              child: PreviewView(controller: c),
            ),
          ),
        ),
      ),
    );
    expect(c.requestedSize, (1136, 736));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
