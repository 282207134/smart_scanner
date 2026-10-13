import 'dart:io';

import 'package:flutter/services.dart';

import 'models.dart';

class NativeOcr {
  static const channel = MethodChannel('smart_scanner/native');
  static Future<String> recognize(String path, OcrLanguage language) async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      throw UnsupportedError('当前系统不支持 OCR');
    }
    final tag = switch (language) {
      OcrLanguage.chineseEnglish || OcrLanguage.chinese => 'zh-Hans',
      OcrLanguage.english => 'en-US',
      OcrLanguage.japanese => 'ja-JP',
    };
    final text = await channel.invokeMethod<String>('ocr', {
      'path': path,
      'language': tag,
    });
    return text ?? '';
  }
}
