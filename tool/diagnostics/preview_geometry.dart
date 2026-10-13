// ignore_for_file: avoid_print
// Run with the scanner app closed: dart run tool/diagnostics/preview_geometry.dart
import 'package:smart_scanner/backend/km_server_backend.dart';

Future<void> main() async {
  final backend = KmServerBackend();
  var samples = 0;
  final subscription = backend.frames.listen((f) {
    if (samples++ < 4) print('FRAME ${f.width}x${f.height} at ${f.x},${f.y}');
  });
  try {
    await backend.connect();
    final device = (await backend.listDevices()).first;
    for (final height in [410, 420, 430]) {
      samples = 0;
      print('REQUEST 980x$height');
      await backend.close();
      try {
        await backend.open(
          deviceIndex: device.index,
          canvasW: 980,
          canvasH: height,
          captureW: 2592,
          captureH: 1944,
        );
        print('OPEN OK');
        await Future<void>.delayed(const Duration(seconds: 1));
      } catch (error) {
        print('OPEN FAILED: $error');
      }
    }
  } finally {
    await subscription.cancel();
    await backend.disconnect();
  }
}
