import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/core/models.dart';
import 'package:smart_scanner/state/app_controller.dart';
import 'package:smart_scanner/ui/widgets/status_bar.dart';

class MenuController extends AppController {
  @override
  Future<void> selectDevice(int index) async {
    deviceIndex = index;
    notifyListeners();
  }

  @override
  Future<void> selectResolution(ScanResolution value) async {
    resolution = value;
    notifyListeners();
  }
}

void main() {
  testWidgets('底部菜单在普通和分数缩放窗口内打开、选择及滚动均不越界', (tester) async {
    final c = MenuController();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    c.devices = const [ScannerDevice(0, '设备0'), ScannerDevice(1, '设备1')];
    c.resolutions = [
      for (int i = 20; i >= 1; i--) ScanResolution(i * 100, i * 75),
    ];
    for (final size in [
      const Size(1280, 720),
      const Size(1265.3333333333, 682.6666666667),
      const Size(960, 640),
    ]) {
      c.deviceIndex = 0;
      c.resolution = c.resolutions.first;
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => Column(
                children: [
                  const Expanded(child: SizedBox()),
                  StatusBarWidget(controller: c),
                ],
              ),
            ),
          ),
        ),
      );
      // The first selected item at the bottom triggers DropdownButton's old
      // menuLimits assertion, even with only two options.
      await tester.tap(find.byKey(const Key('device-menu')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('设备1').last);
      await tester.pumpAndSettle();
      expect(c.deviceIndex, 1);
      await tester.tap(find.byKey(const Key('resolution-menu')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text(c.resolutions.last.label),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text(c.resolutions.last.label));
      await tester.pumpAndSettle();
      expect(c.resolution, c.resolutions.last);
      // Reopening with the last item selected must also stay in the viewport.
      await tester.tap(find.byKey(const Key('resolution-menu')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没有设备和尺寸时底部菜单不可打开', (tester) async {
    final c = MenuController();
    addTearDown(c.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StatusBarWidget(controller: c)),
      ),
    );
    for (final key in ['device-menu', 'resolution-menu']) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<int>), findsNothing);
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
