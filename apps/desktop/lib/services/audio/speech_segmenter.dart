// Speech-aware segmentation.
//
// Turns a per-source stream of [AudioFrame]s + [VoiceActivityDetector] verdicts into [SpeechSegment]s
// ready for ASR. One segmenter instance handles ONE source, so microphone and system audio never mix.
//
// Design goals (kept deliberately simple, not an ML endpointer):
//   - a pre-roll ring buffer so VAD latency never clips the START of a word;
//   - a post-roll "hangover" so a short pause inside a sentence doesn't split it;
//   - a minimum speech duration so noise blips don't create tiny segments;
//   - a maximum duration so a monologue is still bounded;
//   - timestamps + source identity preserved on every segment.
//
// VAD never discards audio here — the segmenter keeps the frames it needs (pre-roll + speech +
// trailing hangover) and emits them as a segment; only clearly-silent gaps between segments drop out.

import 'dart:typed_data';

import 'audio_frame.dart';
import 'vad.dart';

/// A contiguous run of speech from a single source, with its frames and timing.
class SpeechSegment {
  SpeechSegment({
    required this.id,
    required this.source,
    required this.start,
    required this.end,
    required this.frames,
    required this.meanEnergy,
  });

  final String id;
  final AudioSource source;
  final Duration start;
  final Duration end;

  /// The frames composing this segment (pre-roll + speech + hangover), in order. References the
  /// captured buffers; no PCM is copied until [pcm] is called.
  final List<AudioFrame> frames;

  /// Mean VAD energy across the speech portion — a cheap "how loud" signal (not a confidence).
  final double meanEnergy;

  Duration get duration => end - start;

  /// Concatenate the segment's PCM into one buffer (allocated on demand, e.g. to hand to ASR).
  Uint8List pcm() {
    final total = frames.fold<int>(0, (n, f) => n + f.data.lengthInBytes);
    final out = Uint8List(total);
    var o = 0;
    for (final f in frames) {
      out.setRange(o, o + f.data.lengthInBytes, f.data);
      o += f.data.lengthInBytes;
    }
    return out;
  }
}

/// Tunable segmentation parameters. Defaults suit conversational speech.
class SegmenterConfig {
  const SegmenterConfig({
    this.preRoll = const Duration(milliseconds: 300),
    this.hangover = const Duration(milliseconds: 600),
    this.minSpeech = const Duration(milliseconds: 250),
    this.maxSegment = const Duration(seconds: 30),
  });

  /// Audio kept before the first speech frame so word onsets aren't clipped.
  final Duration preRoll;

  /// Silence tolerated inside a segment before it is closed (absorbs mid-sentence pauses).
  final Duration hangover;

  /// Segments shorter than this (after trimming hangover) are discarded as blips.
  final Duration minSpeech;

  /// Hard cap so a continuous talker still yields bounded segments.
  final Duration maxSegment;
}

/// Stateful, single-source segmenter. Feed it frames in order with [add]; it returns a completed
/// [SpeechSegment] when one closes (else null). Call [flush] at end-of-stream to emit any open segment.
class SpeechSegmenter {
  SpeechSegmenter({
    required this.source,
    VoiceActivityDetector? vad,
    this.config = const SegmenterConfig(),
    String? idPrefix,
  }) : vad = vad ?? EnergyVad(),
       _idPrefix = idPrefix ?? source.name;

  final AudioSource source;
  final VoiceActivityDetector vad;
  final SegmenterConfig config;
  final String _idPrefix;

  final List<AudioFrame> _preRoll = [];
  Duration _preRollDuration = Duration.zero;

  bool _inSpeech = false;
  final List<AudioFrame> _current = [];
  Duration _speechDuration = Duration.zero;
  Duration _trailingSilence = Duration.zero;
  double _energySum = 0;
  int _speechFrames = 0;
  int _seq = 0;

  /// Feed one frame. Returns a segment if one just completed, otherwise null.
  SpeechSegment? add(AudioFrame frame) {
    final v = vad.analyze(frame);
    if (!_inSpeech) {
      if (v.isSpeech) {
        _beginSegment();
        _appendSpeech(frame, v);
      } else {
        _rememberPreRoll(frame);
      }
      return null;
    }

    // In an open segment.
    _current.add(frame);
    if (v.isSpeech) {
      _speechDuration += frame.duration;
      _trailingSilence = Duration.zero;
      _energySum += v.energy;
      _speechFrames++;
    } else {
      _trailingSilence += frame.duration;
    }

    final segDuration = _current.fold<Duration>(
      Duration.zero,
      (d, f) => d + f.duration,
    );
    if (_trailingSilence >= config.hangover ||
        segDuration >= config.maxSegment) {
      return _closeSegment();
    }
    return null;
  }

  /// Close any open segment (end of session). Returns it if it meets [SegmenterConfig.minSpeech].
  SpeechSegment? flush() => _inSpeech ? _closeSegment() : null;

  void _rememberPreRoll(AudioFrame frame) {
    _preRoll.add(frame);
    _preRollDuration += frame.duration;
    while (_preRollDuration > config.preRoll && _preRoll.length > 1) {
      _preRollDuration -= _preRoll.removeAt(0).duration;
    }
  }

  void _beginSegment() {
    _inSpeech = true;
    _current
      ..clear()
      ..addAll(_preRoll);
    _speechDuration = Duration.zero;
    _trailingSilence = Duration.zero;
    _energySum = 0;
    _speechFrames = 0;
    _preRoll.clear();
    _preRollDuration = Duration.zero;
  }

  void _appendSpeech(AudioFrame frame, VadResult v) {
    _current.add(frame);
    _speechDuration += frame.duration;
    _energySum += v.energy;
    _speechFrames++;
  }

  SpeechSegment? _closeSegment() {
    _inSpeech = false;
    final frames = List<AudioFrame>.unmodifiable(_current);
    _current.clear();
    if (_speechDuration < config.minSpeech || frames.isEmpty) {
      return null; // too short — a blip, not speech
    }
    final start = frames.first.offset ?? Duration.zero;
    final end = (frames.last.offset ?? start) + frames.last.duration;
    final mean = _speechFrames == 0 ? 0.0 : _energySum / _speechFrames;
    return SpeechSegment(
      id: '$_idPrefix-${_seq++}',
      source: source,
      start: start,
      end: end,
      frames: frames,
      meanEnergy: mean,
    );
  }
}
