import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'theme.dart';
import 'ui/home_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final forceMock = args.contains('--mock');
  final controller = AppController();
  await controller.init(forceMock: forceMock);
  runApp(SmartScannerApp(controller: controller));
}

class SmartScannerApp extends StatelessWidget {
  final AppController controller;
  const SmartScannerApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '智能高拍仪',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: HomePage(controller: controller),
    );
  }
}
