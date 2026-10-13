import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// File naming and storage shared by manual, automatic, and book captures.
class ScanFileStore {
  final String directory;
  const ScanFileStore(this.directory);

  static String basename(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static String sanitizeName(String value, {required String fallback}) {
    var name = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[ .]+$'), '');
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(name)) {
      name = 'Scan_$name';
    }
    if (name.length > 100) name = name.substring(0, 100);
    return name.isEmpty ? fallback : name;
  }

  static Future<Uint8List> readCapture(CaptureResult result) async {
    final file = File(result.savedPath);
    if (await file.exists()) return file.readAsBytes();
    if (result.imageBytes?.isNotEmpty == true) return result.imageBytes!;
    throw StateError('拍摄没有返回有效图像');
  }

  Future<String> uniquePath(
    String base,
    String extension, {
    bool source = false,
  }) async {
    final folder = Directory(
      source ? '$directory${Platform.pathSeparator}.sources' : directory,
    );
    await folder.create(recursive: true);
    String path(int? index) =>
        '${folder.path}${Platform.pathSeparator}$base${index == null ? '' : '_$index'}$extension';
    var candidate = path(null);
    for (var index = 2; await File(candidate).exists(); index++) {
      candidate = path(index);
    }
    return candidate;
  }
}
