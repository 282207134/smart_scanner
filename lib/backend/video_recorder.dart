import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/models.dart';

/// Reconstructs complete preview canvases and samples them at a fixed clock.
/// The output duration follows elapsed time, even if the scanner emits 2 fps.
class VideoRecorder {
  final Stream<PreviewFrame> frames;
  final String savePath;
  final RecordFormat format;
  final int width, height, fps;
  final RecordSource source;
  Process? _process;
  StreamSubscription<PreviewFrame>? _subscription;
  Timer? _timer;
  Uint8List? _canvas;
  bool _writing = false, _stopped = false;
  Future<void>? _writeTask;
  String _stderr = '';
  int _samples = 0;
  final _clock = Stopwatch();
  int _written = 0;
  Object? _writeError;
  VideoRecorder({
    required this.frames,
    required this.savePath,
    required this.format,
    required this.width,
    required this.height,
    this.fps = 15,
    this.source = RecordSource.camera,
  });

  Future<VideoRecorder> start() async {
    await File(savePath).parent.create(recursive: true);
    final codec = switch (format) {
      RecordFormat.mp4 => 'libx264',
      RecordFormat.wmv => 'wmv2',
      RecordFormat.avi => 'mpeg4',
    };
    final args = <String>['-hide_banner', '-loglevel', 'error', '-y'];
    if (source == RecordSource.screen) {
      if (Platform.isWindows) {
        args.addAll(['-f', 'gdigrab', '-framerate', '$fps', '-i', 'desktop']);
      } else if (Platform.isMacOS) {
        args.addAll([
          '-f',
          'avfoundation',
          '-framerate',
          '$fps',
          '-i',
          'Capture screen 0:none',
        ]);
      } else {
        throw UnsupportedError('当前系统不支持屏幕录制');
      }
    } else {
      args.addAll([
        '-f',
        'rawvideo',
        '-pix_fmt',
        'rgb24',
        '-s',
        '${width}x$height',
        '-r',
        '$fps',
        '-i',
        'pipe:0',
      ]);
    }
    args.addAll([
      '-an',
      '-vf',
      'pad=ceil(iw/2)*2:ceil(ih/2)*2',
      '-c:v',
      codec,
      '-pix_fmt',
      'yuv420p',
      savePath,
    ]);
    try {
      var executable = 'ffmpeg';
      if (Platform.isMacOS) {
        for (final path in [
          '/opt/homebrew/bin/ffmpeg',
          '/usr/local/bin/ffmpeg',
        ]) {
          if (await File(path).exists()) {
            executable = path;
            break;
          }
        }
      }
      _process = await Process.start(executable, args);
    } on ProcessException {
      throw StateError('视频录制需要 FFmpeg，请安装后重试，或将 ffmpeg 加入系统 PATH');
    }
    final process = _process!;
    final firstFrame = Completer<void>();
    process.stdout.listen((_) {});
    process.stderr.transform(SystemEncoding().decoder).listen((line) {
      _stderr = '$_stderr$line';
      if (_stderr.length > 3000) {
        _stderr = _stderr.substring(_stderr.length - 3000);
      }
    });
    if (source == RecordSource.camera) {
      _canvas = Uint8List(width * height * 3);
      _subscription = frames.listen((f) {
        if (f.x < 0 ||
            f.y < 0 ||
            f.width + f.x > width ||
            f.height + f.y > height ||
            f.rgb.length != f.width * f.height * 3) {
          return;
        }
        final canvas = _canvas!;
        canvas.fillRange(0, canvas.length, 0);
        for (var row = 0; row < f.height; row++) {
          final dst = ((f.y + row) * width + f.x) * 3;
          canvas.setRange(dst, dst + f.width * 3, f.rgb, row * f.width * 3);
        }
        _samples++;
        if (!firstFrame.isCompleted) firstFrame.complete();
      });
    }
    // Surface an immediately rejected source/encoder before claiming recording.
    final code = await process.exitCode.timeout(
      const Duration(milliseconds: 250),
      onTimeout: () => -999,
    );
    if (code != -999) {
      await _subscription?.cancel();
      _timer?.cancel();
      throw StateError('无法启动录制：$_stderr');
    }
    if (source == RecordSource.camera) {
      try {
        await firstFrame.future.timeout(const Duration(seconds: 12));
      } catch (_) {
        await _subscription?.cancel();
        process.kill();
        throw StateError('摄像头未返回画面，录像未启动');
      }
      _clock.start();
      _timer = Timer.periodic(Duration(microseconds: 1000000 ~/ fps), (_) {
        if (_stopped || _writing || _samples == 0) return;
        _writing = true;
        _writeTask = _write(process);
      });
    }
    return this;
  }

  Future<void> _write(Process process) async {
    try {
      final target = _clock.elapsedMicroseconds * fps ~/ 1000000;
      while (_written < target) {
        process.stdin.add(Uint8List.fromList(_canvas!));
        await process.stdin.flush();
        _written++;
      }
    } catch (e) {
      _writeError = e;
      _timer?.cancel();
    } finally {
      _writing = false;
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _clock.stop();
    _timer?.cancel();
    await _subscription?.cancel();
    await _writeTask;
    final process = _process;
    if (process == null) return;
    if (source == RecordSource.camera && _writeError == null) {
      await _write(process);
    }
    try {
      if (source == RecordSource.screen) {
        process.stdin.writeln('q');
      }
      await process.stdin.flush();
      await process.stdin.close();
    } catch (_) {
      /* Check the process exit code below. */
    }
    final code = await process.exitCode.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    final file = File(savePath);
    if (code != 0 ||
        _writeError != null ||
        !await file.exists() ||
        await file.length() < 100) {
      throw StateError('视频保存失败：${_writeError ?? _stderr}');
    }
  }
}
