import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/backend/mock_backend.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/state/app_controller.dart';
import 'package:smart_scanner/ui/widgets/status_bar.dart';

class ResolutionBackend extends MockBackend {
  final List<ScanResolution> sizes;
  final Map<int, List<ScanResolution>> deviceSizes;
  int opens = 0;
  int? lastDevice, lastWidth, lastHeight;
  ResolutionBackend(this.sizes, {this.deviceSizes = const {}})
    : super(emitFrames: false);
  @override
  Future<List<ScanResolution>> listResolutions(int deviceIndex) async =>
      deviceSizes[deviceIndex] ?? sizes;
  @override
  Future<void> open({
    required int deviceIndex,
    required int canvasW,
    required int canvasH,
    required int captureW,
    required int captureH,
  }) async {
    opens++;
    lastDevice = deviceIndex;
    lastWidth = captureW;
    lastHeight = captureH;
    await super.open(
      deviceIndex: deviceIndex,
      canvasW: canvasW,
      canvasH: canvasH,
      captureW: captureW,
      captureH: captureH,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('菜单只显示当前摄像头返回的全部尺寸，包括参考图以外的尺寸', (tester) async {
    final c = AppController();
    addTearDown(c.dispose);
    c.resolutions = const [
      ScanResolution(4160, 3120),
      ScanResolution(1024, 768),
      ScanResolution(800, 600),
      ScanResolution(640, 480),
    ];
    c.resolution = c.resolutions.first;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StatusBarWidget(controller: c)),
      ),
    );
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    final items = dropdown.items!;
    expect(items.map((item) => item.value), [
      '4160×3120',
      '1024×768',
      '800×600',
      '640×480',
    ]);
    expect(items.every((item) => item.enabled), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('不支持的分辨率不能发送打开请求或覆盖当前选择', () async {
    final backend = ResolutionBackend(const [ScanResolution(4160, 3120)]);
    final c = AppController();
    await c.init(
      backendOverride: backend,
      outputDirOverride: Directory.systemTemp.path,
    );
    addTearDown(c.dispose);
    c.connected = true;
    await c.refreshResolutions();
    await c.selectResolution(const ScanResolution(5408, 4056));
    expect(c.resolution?.label, '4160×3120');
    expect(backend.opens, 0);
    expect(c.lastError, contains('不支持'));
  });

  test('低分辨率设备仅显示自身可用尺寸', () async {
    final c = AppController();
    await c.init(
      backendOverride: ResolutionBackend(const [ScanResolution(640, 480)]),
      outputDirOverride: Directory.systemTemp.path,
    );
    addTearDown(c.dispose);
    await c.refreshResolutions();
    expect(c.resolution?.label, '640×480');
    expect(c.resolutions.map((r) => r.label), ['640×480']);
    expect(c.supportsResolution(c.resolution!), isTrue);
  });

  testWidgets('切换摄像头后重新读取、去重并排序尺寸，保留可用选择或回退', (tester) async {
    final backend = ResolutionBackend(
      const [],
      deviceSizes: const {
        0: [ScanResolution(800, 600), ScanResolution(4160, 3120)],
        1: [
          ScanResolution(640, 480),
          ScanResolution(1280, 720),
          ScanResolution(1920, 1080),
          ScanResolution(1280, 720),
        ],
        2: [
          ScanResolution(1920, 1080),
          ScanResolution(5408, 4056),
          ScanResolution(4896, 3672),
          ScanResolution(4608, 3456),
        ],
      },
    );
    final c = AppController();
    await c.init(
      backendOverride: backend,
      outputDirOverride: Directory.systemTemp.path,
    );
    addTearDown(c.dispose);
    c.connected = true;
    c.devices = const [
      ScannerDevice(0, '扫描仪'),
      ScannerDevice(1, '内置相机'),
      ScannerDevice(2, '高分辨率相机'),
    ];
    Future<void> select(int index) async {
      await tester.runAsync(() => c.selectDevice(index));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StatusBarWidget(controller: c)),
        ),
      );
    }

    List<String?> menu() => tester
        .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
        .items!
        .map((item) => item.value)
        .toList();

    await select(0);
    expect(menu(), ['4160×3120', '800×600']);
    expect(backend.lastWidth, 4160);
    await select(1);
    expect(menu(), ['1920×1080', '1280×720', '640×480']);
    expect(c.resolution?.label, '1920×1080');
    expect(
      (backend.lastDevice, backend.lastWidth, backend.lastHeight),
      (1, 1920, 1080),
    );
    await select(2);
    expect(menu(), ['5408×4056', '4896×3672', '4608×3456', '1920×1080']);
    expect(c.resolution?.label, '1920×1080', reason: '新设备仍支持的尺寸应保留');
    await tester.runAsync(() => c.selectResolution(c.resolutions.first));
    expect(
      (backend.lastDevice, backend.lastWidth, backend.lastHeight),
      (2, 5408, 4056),
    );
    await select(0);
    expect(menu(), ['4160×3120', '800×600']);
    expect(c.resolution?.label, '4160×3120');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
