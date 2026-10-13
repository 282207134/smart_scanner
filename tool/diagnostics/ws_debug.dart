// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:smart_scanner/core/ws_client.dart';

Future<void> main() async {
  stdout.writeln('connecting...');
  final c = await WsClient.connect('127.0.0.1', 22225);
  stdout.writeln('connected');
  c.messages.listen((m) {
    stdout.writeln(
      'MSG len=${m.length} head=${m.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
    );
  });
  c.closes.listen((w) => stdout.writeln('CLOSE $w'));
  stdout.writeln('sending 0x50...');
  c.sendBytes([0x77, 0x88, 0x50]);
  await Future.delayed(const Duration(seconds: 2));
  stdout.writeln('sending heartbeat...');
  c.sendBytes([0x11, 0x11, 0x11]);
  await Future.delayed(const Duration(seconds: 1));
  c.close();
  stdout.writeln('done');
}
