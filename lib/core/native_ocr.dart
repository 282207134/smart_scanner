import 'dart:io';

import 'package:flutter/services.dart';

import 'models.dart';

class NativeOcr {
  static const channel = MethodChannel('smart_scanner/native');
  static Future<String> recognize(
    String path,
    OcrLanguage language, {
    OcrTextLayout layout = OcrTextLayout.horizontal,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      throw UnsupportedError('当前系统不支持 OCR');
    }
    if (layout == OcrTextLayout.vertical && !Platform.isMacOS) {
      throw UnsupportedError('竖排 OCR 需要支持实况文本的 macOS 13 或更新版本');
    }
    final tag = switch (language) {
      OcrLanguage.chineseEnglish || OcrLanguage.chinese => 'zh-Hans',
      OcrLanguage.english => 'en-US',
      OcrLanguage.japanese => 'ja-JP',
    };
    final text = await channel.invokeMethod<String>('ocr', {
      'path': path,
      'language': tag,
      if (layout == OcrTextLayout.vertical) 'textLayout': layout.name,
    });
    return text ?? '';
  }
}
