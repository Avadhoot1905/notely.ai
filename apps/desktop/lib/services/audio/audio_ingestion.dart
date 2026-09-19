// Audio ingestion / router.
//
// The boundary between capture and processing. It consumes raw [AudioFrame]s from one or more
// capture sources, stamps each with its position on a canonical meeting timeline (so mic and system
// frames share one clock), preserves per-source ordering, and re-exposes them as a single broadcast
// [Stream] for downstream consumers (VAD/segmentation, and later ASR).
//
// It must never block the recorder callback: [add] returns immediately and delivery happens on a
// microtask. Buffering is BOUNDED with an explicit **drop-oldest** overflow policy and a [dropped]
// counter — frames are never silently discarded without being counted.

import 'dart:async';
import 'dart:collection';

import 'audio_frame.dart';

class AudioIngestion {
  AudioIngestion({this.capacity = 512, DateTime? startedAt}) {
    _startedAt = startedAt;
  }

  /// Max frames held before the oldest is dropped. Bounds memory if a consumer stalls.
  final int capacity;

  DateTime? _startedAt;
  final Queue<AudioFrame> _queue = Queue<AudioFrame>();
  final StreamController<AudioFrame> _out =
      StreamController<AudioFrame>.broadcast(sync: false);
  bool _draining = false;
  int _dropped = 0;

  /// Frames dropped by the bounded-buffer overflow policy this session.
  int get dropped => _dropped;

  /// The canonical, source-multiplexed frame stream. Broadcast: multiple independent consumers may
  /// subscribe. Frame [AudioFrame.offset] is set to the meeting-timeline position.
  Stream<AudioFrame> get frames => _out.stream;

  /// Establish (or reset) the timeline origin. Frames added afterward are offset from [at].
  void start(DateTime at) => _startedAt = at;

  /// Enqueue a captured frame. Non-blocking; safe to call directly from a recorder callback.
  void add(AudioFrame frame) {
    if (_out.isClosed) return;
    _startedAt ??= frame.capturedAt;
    var offset = frame.capturedAt.difference(_startedAt!);
    if (offset.isNegative) offset = Duration.zero;
    final stamped = frame.withOffset(offset);

    if (_queue.length >= capacity) {
      _queue
          .removeFirst(); // drop-oldest: keep the freshest audio when a consumer stalls
      _dropped++;
    }
    _queue.add(stamped);
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_draining) return;
    _draining = true;
    scheduleMicrotask(_drain);
  }

  void _drain() {
    _draining = false;
    while (_queue.isNotEmpty) {
      if (_out.isClosed) {
        _queue.clear();
        return;
      }
      _out.add(_queue.removeFirst());
    }
  }

  Future<void> dispose() async {
    _queue.clear();
    await _out.close();
  }
}
