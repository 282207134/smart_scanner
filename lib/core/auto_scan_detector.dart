import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

enum AutoScanPhase { waiting, moving, countdown, capture, captured }

class AutoScanProgress {
  final AutoScanPhase phase;
  final int seconds;
  const AutoScanProgress(this.phase, [this.seconds = 0]);
}

/// Frame-driven state machine; no timer can capture a stale camera image.
class AutoScanDetector {
  final Duration delay;
  final Duration stabilization;
  final Duration staleAfter;
  final Duration captureSettling;
  AutoScanDetector({
    this.delay = const Duration(seconds: 3),
    this.stabilization = const Duration(milliseconds: 700),
    this.staleAfter = const Duration(milliseconds: 2500),
    this.captureSettling = const Duration(seconds: 2),
  });
  Float32List? _previous, _saved;
  Duration? _stableSince, _lastFrame;
  Duration? _settleUntil;
  bool _latched = false, _eligible = false;
  AutoScanProgress progress = const AutoScanProgress(AutoScanPhase.waiting);

  AutoScanProgress feed(
    PreviewFrame frame,
    Duration now, {
    bool eligible = true,
  }) {
    final next = fingerprint(frame);
    if (_lastFrame != null && now - _lastFrame! > staleAfter) {
      _stableSince = null;
    }
    _lastFrame = now;
    _eligible = eligible;
    if (_latched) return progress;
    if (_settleUntil != null && now < _settleUntil!) {
      _previous = next;
      _stableSince = null;
      return progress = const AutoScanProgress(AutoScanPhase.captured);
    }
    final moving = _previous != null && difference(_previous!, next) > .035;
    final sameAsSaved = _saved != null && difference(_saved!, next) < .055;
    _previous = next;
    if (!eligible) {
      _stableSince = null;
      return progress = const AutoScanProgress(AutoScanPhase.waiting);
    }
    if (sameAsSaved) {
      _stableSince = null;
      return progress = const AutoScanProgress(AutoScanPhase.captured);
    }
    if (moving) {
      _stableSince = null;
      return progress = const AutoScanProgress(AutoScanPhase.moving);
    }
    _stableSince ??= now;
    return tick(now);
  }

  AutoScanProgress tick(Duration now) {
    if (_latched) return progress;
    if (!_eligible || _lastFrame == null || now - _lastFrame! > staleAfter) {
      _stableSince = null;
      return progress = const AutoScanProgress(AutoScanPhase.waiting);
    }
    // A timer between camera frames must retain the last frame's waiting,
    // moving or captured state. Only a fresh changed frame starts a new wait.
    if (_stableSince == null) return progress;
    final elapsed = now - _stableSince!;
    if (elapsed < stabilization) {
      return progress = const AutoScanProgress(AutoScanPhase.moving);
    }
    final remaining = delay - (elapsed - stabilization);
    if (remaining <= Duration.zero) {
      _latched = true;
      return progress = const AutoScanProgress(AutoScanPhase.capture);
    }
    return progress = AutoScanProgress(
      AutoScanPhase.countdown,
      (remaining.inMilliseconds / 1000).ceil(),
    );
  }

  void markCaptured({Duration? now}) {
    _saved = _previous == null ? null : Float32List.fromList(_previous!);
    _latched = false;
    _stableSince = null;
    _settleUntil = (now ?? _lastFrame ?? Duration.zero) + captureSettling;
    progress = const AutoScanProgress(AutoScanPhase.captured);
  }

  static Float32List fingerprint(PreviewFrame frame) {
    const w = 96, h = 72;
    final result = Float32List(w * h);
    double mean = 0;
    for (var y = 0; y < h; y++) {
      final top = (y * frame.height / h).floor();
      final bottom = math
          .max(top + 1, ((y + 1) * frame.height / h).floor())
          .clamp(1, frame.height);
      for (var x = 0; x < w; x++) {
        final left = (x * frame.width / w).floor();
        final right = math
            .max(left + 1, ((x + 1) * frame.width / w).floor())
            .clamp(1, frame.width);
        double value = 0;
        for (var sy = top; sy < bottom; sy++) {
          for (var sx = left; sx < right; sx++) {
            final i = (sy * frame.width + sx) * 3;
            value +=
                frame.rgb[i] * .299 +
                frame.rgb[i + 1] * .587 +
                frame.rgb[i + 2] * .114;
          }
        }
        // Area averages avoid aliasing of fine text when the restored camera
        // preview shifts by a pixel or autofocus changes edge sharpness.
        value /= (right - left) * (bottom - top);
        result[y * w + x] = value;
        mean += value;
      }
    }
    mean /= result.length;
    final smoothed = Float32List(result.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        double sum = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            sum +=
                result[(y + dy).clamp(0, h - 1) * w + (x + dx).clamp(0, w - 1)];
          }
        }
        smoothed[y * w + x] = sum / 9 - mean;
      }
    }
    return smoothed;
  }

  static double difference(Float32List a, Float32List b) {
    var changed = 0;
    double sum = 0;
    for (var i = 0; i < a.length; i++) {
      final d = (a[i] - b[i]).abs();
      if (d > 13) changed++;
      sum += d;
    }
    return math.max(changed / a.length, sum / a.length / 100);
  }
}
