import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_scanner/backend/km_server_backend.dart';
import 'package:smart_scanner/backend/windows_camera_backend.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('smart_scanner/native');
  const events = MethodChannel('smart_scanner/frames');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late WindowsCameraBackend backend;
  late List<MethodCall> calls;
  late Directory output;
  final image = Uint8List.fromList([137, 80, 78, 71]);

  setUp(() async {
    output = await Directory.systemTemp.createTemp('native_camera_test');
    backend = WindowsCameraBackend();
    calls = [];
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      return switch (call.method) {
        'devices' => ['USB Camera', 'Integrated Webcam'],
        'resolutions' => [
          {'width': 1920, 'height': 1080},
          {'width': 640, 'height': 480},
        ],
        'captureRaw' => image,
        _ => null,
      };
    });
  });
  tearDown(() async {
    await backend.disconnect();
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(events, null);
    await output.delete(recursive: true);
  });

  Future<void> open() => backend.open(
    deviceIndex: 1,
    canvasW: 800,
    canvasH: 600,
    captureW: 1920,
    captureH: 1080,
  );

  test('系统设备与分辨率来自原生接口，拍照使用完整采集图像', () async {
    await backend.connect();
    final devices = await backend.listDevices();
    expect(devices.map((d) => d.name), ['USB Camera', 'Integrated Webcam']);
    expect((await backend.listResolutions(1)).map((r) => r.label), [
      '1920×1080',
      '640×480',
    ]);
    await open();
    expect(backend.isOpen, isTrue);
    expect(calls.firstWhere((c) => c.method == 'open').arguments, {
      'device': 1,
      'canvasW': 800,
      'canvasH': 600,
      'width': 1920,
      'height': 1080,
    });
    expect((await backend.captureRaw()).imageBytes, image);
    await backend.close();
    expect(backend.isOpen, isFalse);
  });

  test('原生失败不会保留已打开状态，错误完整传回', () async {
    await backend.connect();
    await open();
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'open') {
        throw PlatformException(code: 'CAMERA', message: '设备被占用');
      }
      return null;
    });
    await expectLater(open(), throwsA(isA<PlatformException>()));
    expect(backend.isOpen, isFalse);
  });

  test('帧错误清除连接状态，断开仍释放原生会话', () async {
    await backend.connect();
    await open();
    final failure = backend.events.firstWhere(
      (e) => e is ConnectionEvent && !e.connected,
    );
    await messenger.handlePlatformMessage(
      'smart_scanner/frames',
      const StandardMethodCodec().encodeErrorEnvelope(
        code: 'CAMERA',
        message: '相机已拔出',
      ),
      (_) {},
    );
    await failure;
    expect(backend.isConnected, isFalse);
    expect(backend.isOpen, isFalse);
    await backend.disconnect();
    expect(calls.last.method, 'close');
  });

  test('预览控制和对焦保持同一跨平台协议', () async {
    backend.setPreviewSize(true);
    backend.rotateRight();
    backend.moveOffset(12, 8, 0, 1);
    await backend.manualFocus();
    expect(calls.map((c) => c.arguments), [
      {'key': 'previewSize', 'value': true},
      {'key': 'rotateDelta', 'value': 1},
      {
        'key': 'pan',
        'value': [-12, 8],
      },
      {'key': 'focus', 'value': true},
    ]);
  });

  test('Windows 默认使用系统摄像头，真实设备不会依赖厂商连接', () async {
    if (!Platform.isWindows) return;
    final controller = AppController();
    await controller.init(
      backendOverride: backend,
      outputDirOverride: output.path,
    );
    await controller.useDemo(false);
    expect(controller.backend, isA<WindowsCameraBackend>());
    expect(controller.connected, isTrue);
    expect(controller.previewOpen, isTrue);
    expect(controller.usesSystemCamera, isTrue);
    expect(controller.supportsHighDensityPreview, isTrue);
    expect(controller.devices.length, 2);
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('已保存的厂商服务选择在下次启动时恢复', () async {
    if (!Platform.isWindows) return;
    SharedPreferences.setMockInitialValues({'windowsVendorService': true});
    final controller = AppController();
    await controller.init(outputDirOverride: output.path);
    expect(controller.windowsVendorService, isTrue);
    expect(controller.backend, isA<KmServerBackend>());
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    SharedPreferences.setMockInitialValues({});
  });

  test('系统相机改变预览画布时由原生端复用采集流', () async {
    final controller = AppController();
    await controller.init(
      backendOverride: backend,
      outputDirOverride: output.path,
    );
    await backend.connect();
    await open();
    controller.connected = controller.previewOpen = true;
    controller.resolution = const ScanResolution(1920, 1080);
    calls.clear();
    await controller.reopenPreview();
    expect(calls.where((call) => call.method == 'open').length, 1);
    expect(calls.where((call) => call.method == 'close'), isEmpty);
    expect(controller.previewOpen, isTrue);
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('拍摄和录像期间不允许切换设备接入方式', () async {
    final controller = AppController();
    await controller.init(
      backendOverride: backend,
      outputDirOverride: output.path,
    );
    controller.capturing = true;
    await controller.useWindowsVendorService(true);
    expect(controller.windowsVendorService, isFalse);
    expect(controller.backend, same(backend));
    controller.capturing = false;
    controller.recording = true;
    await controller.useWindowsVendorService(true);
    expect(controller.windowsVendorService, isFalse);
    controller.recording = false;
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
  });
}
