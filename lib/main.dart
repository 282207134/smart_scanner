import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'localization.dart';
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
  Widget build(BuildContext context) => ValueListenableBuilder<AppLanguage>(
    valueListenable: controller.interfaceLanguage,
    builder: (context, language, home) => MaterialApp(
      onGenerateTitle: (context) => context.tr('智能高拍仪'),
      locale: language.locale,
      supportedLocales: AppLanguage.values.map((value) => value.locale),
      localizationsDelegates: const [
        AppLanguage.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(japanese: language == AppLanguage.japanese),
      home: home,
    ),
    child: HomePage(controller: controller),
  );
}
