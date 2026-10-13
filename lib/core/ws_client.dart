/// 极简 WebSocket 客户端 (RFC 6455)。
///
/// 为什么不用 dart:io 的 WebSocket：KHServer（高拍仪服务端）对 HTTP 请求头
/// 大小写敏感，而 dart:io 会把所有请求头强制转成小写，导致握手被服务端拒绝
/// （服务端回一个 HTTP/0.9 错误页）。本实现基于原始 Socket，完全控制握手字节，
/// 且不协商 permessage-deflate（预览帧为原始二进制，压缩无益且增加复杂度）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class WsException implements Exception {
  final String message;
  WsException(this.message);
  @override
  String toString() => 'WsException: $message';
}

typedef WsMessageSink = void Function(Uint8List message);

/// 单连接 WebSocket 客户端，仅覆盖本项目所需子集：
/// - 客户端发送二进制帧（强制掩码）
/// - 服务端二进制/文本帧，支持分片（continuation）
/// - ping/pong/close 自动应答
class WsClient {
  final Socket _socket;
  final StreamController<Uint8List> _messages = StreamController.broadcast();
  final StreamController<String> _closes = StreamController.broadcast();

  Uint8List _buf = Uint8List(64 * 1024);
  int _readPos = 0;
  int _writePos = 0;

  // 分片重组状态
  final BytesBuilder _frag = BytesBuilder(copy: false);
  int? _fragOpcode;

  bool _closed = false;
  final Random _rand = Random.secure();

  WsClient._(this._socket);

  /// 连接并完成握手。
  static Future<WsClient> connect(
    String host,
    int port, {
    String path = '/',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);

    final keyBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final key = base64Encode(keyBytes);

    // 注意：头字段名的大小写必须保持规范形式，KHServer 大小写敏感。
    final req =
        'GET $path HTTP/1.1\r\n'
        'Host: $host:$port\r\n'
        'Connection: Upgrade\r\n'
        'Upgrade: websocket\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: $key\r\n'
        '\r\n';
    socket.add(ascii.encode(req));
    await socket.flush();

    final client = WsClient._(socket);
    final hsBuf = BytesBuilder();
    final handshakeDone = Completer<void>();

    late StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) {
        if (!handshakeDone.isCompleted) {
          hsBuf.add(chunk);
          final bytes = hsBuf.toBytes();
          final idx = indexOfCRLFCRLF(bytes);
          if (idx < 0) {
            if (bytes.length > 64 * 1024 && !handshakeDone.isCompleted) {
              handshakeDone.completeError(
                WsException('handshake response too large'),
              );
            }
            return;
          }
          final head = String.fromCharCodes(bytes.sublist(0, idx));
          if (!head.startsWith('HTTP/1.1 101')) {
            handshakeDone.completeError(
              WsException('bad handshake status: ${head.split('\r\n').first}'),
            );
            socket.destroy();
            return;
          }
          handshakeDone.complete();
          final rest = bytes.sublist(idx + 4);
          if (rest.isNotEmpty) client._onData(rest);
        } else {
          client._onData(chunk);
        }
      },
      onError: (Object e) {
        if (!handshakeDone.isCompleted) {
          handshakeDone.completeError(WsException('socket error: $e'));
        } else {
          client._fail('socket error: $e');
        }
      },
      onDone: () {
        if (!handshakeDone.isCompleted) {
          handshakeDone.completeError(WsException('closed during handshake'));
        } else {
          client._fail('connection closed');
        }
      },
      cancelOnError: false,
    );

    try {
      await handshakeDone.future.timeout(timeout);
    } on TimeoutException {
      sub.cancel();
      socket.destroy();
      throw WsException('handshake timeout');
    } catch (e) {
      sub.cancel();
      if (e is WsException) rethrow;
      throw WsException('$e');
    }
    return client;
  }

  /// 消息流（已重组完整的应用消息）
  Stream<Uint8List> get messages => _messages.stream;

  /// 连接关闭流（原因文本）
  Stream<String> get closes => _closes.stream;

  bool get isClosed => _closed;

  /// 发送二进制消息
  void sendBytes(List<int> payload) => _sendFrame(0x2, payload);

  /// 发送文本消息
  void sendText(String text) => _sendFrame(0x1, ascii.encode(text));

  /// 主动关闭
  void close({int code = 1000, String reason = ''}) {
    if (_closed) return;
    final reasonBytes = ascii.encode(reason);
    final body = Uint8List(2 + reasonBytes.length);
    body[0] = (code >> 8) & 0xff;
    body[1] = code & 0xff;
    body.setRange(2, body.length, reasonBytes);
    try {
      _sendFrame(0x8, body);
    } catch (_) {}
    _closed = true;
    _socket.destroy();
    if (!_messages.isClosed) _messages.close();
    if (!_closes.isClosed) _closes.close();
  }

  // ---------- 内部实现 ----------

  void _sendFrame(int opcode, List<int> payload) {
    if (_closed) return;
    final len = payload.length;
    final head = BytesBuilder();
    final b0 = 0x80 | opcode; // FIN + opcode
    if (len < 126) {
      head.add([b0, 0x80 | len]);
    } else if (len < 65536) {
      head.add([b0, 0x80 | 126, (len >> 8) & 0xff, len & 0xff]);
    } else {
      final l = ByteData(8)..setUint64(0, len);
      head.add([b0, 0x80 | 127]);
      head.add(l.buffer.asUint8List());
    }
    final mask = Uint8List.fromList(
      List<int>.generate(4, (_) => _rand.nextInt(256)),
    );
    head.add(mask);
    final masked = Uint8List(len);
    for (int i = 0; i < len; i++) {
      masked[i] = payload[i] ^ mask[i & 3];
    }
    head.add(masked);
    _socket.add(head.takeBytes());
  }

  void _onData(Uint8List chunk) {
    if (_closed) return;
    final unread = _writePos - _readPos;
    if (_writePos + chunk.length > _buf.length) {
      var capacity = _buf.length;
      while (capacity < unread + chunk.length) {
        capacity *= 2;
      }
      final next = Uint8List(capacity);
      next.setRange(0, unread, _buf, _readPos);
      _buf = next;
      _readPos = 0;
      _writePos = unread;
    }
    _buf.setRange(_writePos, _writePos + chunk.length, chunk);
    _writePos += chunk.length;

    while (true) {
      final avail = _writePos - _readPos;
      if (avail < 2) break;
      final b0 = _buf[_readPos];
      final b1 = _buf[_readPos + 1];
      final fin = (b0 & 0x80) != 0;
      final opcode = b0 & 0x0f;
      final masked = (b1 & 0x80) != 0;
      int payloadLen = b1 & 0x7f;
      int offset = 2;
      if (payloadLen == 126) {
        if (avail < 4) break;
        payloadLen = (_buf[_readPos + 2] << 8) | _buf[_readPos + 3];
        offset = 4;
      } else if (payloadLen == 127) {
        if (avail < 10) break;
        final bd = ByteData.sublistView(_buf, _readPos + 2, _readPos + 10);
        payloadLen = bd.getUint64(0);
        offset = 10;
      }
      Uint8List maskKey = Uint8List(0);
      if (masked) {
        if (avail < offset + 4) break;
        maskKey = Uint8List.sublistView(
          _buf,
          _readPos + offset,
          _readPos + offset + 4,
        );
        offset += 4;
      }
      if (avail < offset + payloadLen) break;

      final start = _readPos + offset;
      // Stream delivery is asynchronous. Do not expose our reusable receive buffer.
      final payload = Uint8List.fromList(
        _buf.sublist(start, start + payloadLen),
      );
      if (masked) {
        for (int i = 0; i < payloadLen; i++) {
          payload[i] ^= maskKey[i & 3];
        }
      }
      _readPos = start + payloadLen;

      switch (opcode) {
        case 0x0: // continuation
          _frag.add(payload);
          if (fin) {
            final message = _frag.takeBytes();
            final op = _fragOpcode ?? 0x2;
            _fragOpcode = null;
            _emit(op, message);
          }
          break;
        case 0x1: // text
        case 0x2: // binary
          if (fin) {
            _emit(opcode, payload);
          } else {
            _fragOpcode = opcode;
            _frag.add(payload);
          }
          break;
        case 0x8: // close
          try {
            _sendFrame(0x8, payload); // 尽力应答
          } catch (_) {}
          _closed = true;
          if (!_closes.isClosed) {
            _closes.add(
              payload.length >= 2
                  ? 'closed code=${(payload[0] << 8) | payload[1]}'
                  : 'closed',
            );
          }
          _socket.destroy();
          if (!_messages.isClosed) _messages.close();
          return;
        case 0x9: // ping -> pong
          _sendFrame(0xA, payload);
          break;
        case 0xA: // pong
          break;
        default:
          break;
      }
    }

    // 压缩缓冲区
    if (_readPos == _writePos) {
      _readPos = 0;
      _writePos = 0;
    }
  }

  void _emit(int opcode, Uint8List payload) {
    if (opcode == 0x1) {
      // 文本帧也按字节交付，由上层决定解码
    }
    if (!_messages.isClosed) _messages.add(payload);
  }

  void _fail(String why) {
    if (_closed) return;
    _closed = true;
    if (!_closes.isClosed) _closes.add(why);
    if (!_messages.isClosed) _messages.close();
  }
}

int indexOfCRLFCRLF(Uint8List data) {
  for (int i = 0; i + 3 < data.length; i++) {
    if (data[i] == 0x0d &&
        data[i + 1] == 0x0a &&
        data[i + 2] == 0x0d &&
        data[i + 3] == 0x0a) {
      return i;
    }
  }
  return -1;
}
