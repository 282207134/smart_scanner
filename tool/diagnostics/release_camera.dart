import 'package:smart_scanner/core/ws_client.dart';
import 'package:smart_scanner/core/protocol.dart';

Future<void> main() async {
  final ws = await WsClient.connect('127.0.0.1', 22225);
  ws.sendBytes(KmMessage.cmd(KmCmd.wiseCaptureStop));
  ws.sendBytes(KmMessage.cmd(KmCmd.closeCamera, [0]));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  ws.close();
}
