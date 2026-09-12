// Audio capture abstraction for a meeting session.
//
// The UI talks to this interface only — never to platform audio APIs. A session can capture
// the microphone and (eventually) system/speaker audio. Capability is reported honestly via
// [AudioCapabilities]: microphone is genuinely wired through the `record` package; system
// audio is reported as unsupported on the current platform until a native capture path exists
// (see RecordMeetingAudioService for the rationale).
//
// Future: `start*` would hand PCM frames to the Rust engine over IPC for ASR. Today the mic
// stream is opened (proving permission + capture work) and drained; no processing happens.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Availability of an individual audio source.
enum AudioSourceStatus {
  available,
  permissionRequired,
  unsupported,
  unavailable,
}

/// Snapshot of what audio sources this platform/session can use.
@immutable
class AudioCapabilities {
  const AudioCapabilities({
    required this.microphone,
    required this.systemAudio,
    this.systemAudioNote,
  });

  final AudioSourceStatus microphone;
  final AudioSourceStatus systemAudio;

  /// Human-readable explanation for the system-audio status (shown in the UI).
  final String? systemAudioNote;

  AudioCapabilities copyWith({
    AudioSourceStatus? microphone,
    AudioSourceStatus? systemAudio,
    String? systemAudioNote,
  }) => AudioCapabilities(
    microphone: microphone ?? this.microphone,
    systemAudio: systemAudio ?? this.systemAudio,
    systemAudioNote: systemAudioNote ?? this.systemAudioNote,
  );
}

/// Lifecycle contract for meeting audio capture.
abstract class MeetingAudioService {
  /// Probe/request OS permissions. Returns the resulting capability snapshot.
  Future<AudioCapabilities> requestPermissions();

  /// Latest known capabilities (from the last [requestPermissions]).
  AudioCapabilities get capabilities;

  Future<void> startMicrophone();
  Future<void> startSystemAudio();

  /// Start all available capture sources for a new session.
  Future<void> start();
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

/// Microphone capture via the `record` package (works on macOS and Windows alike). Opens a PCM
/// stream to prove capture works, then drains it (no bytes are stored or processed yet — that's
/// the Rust engine's job later).
///
/// System audio: `record` captures input devices (microphone), NOT the system output mix.
/// Capturing what the *other* participants say requires an OS-level loopback mechanism, and the
/// mechanism differs per platform — macOS uses ScreenCaptureKit audio capture (macOS 13+) or a
/// virtual audio device; Windows uses WASAPI loopback; Linux uses a PulseAudio/PipeWire monitor
/// source. All of these must be implemented natively (a platform plugin or the Rust engine).
/// Until that exists we report system audio as unsupported — with a platform-appropriate note —
/// rather than pretending it is captured. The application-level behaviour stays identical.
String _systemAudioNoteForPlatform() {
  if (Platform.isMacOS) {
    return 'System/call audio needs native loopback capture '
        '(macOS ScreenCaptureKit or the Rust engine).';
  }
  if (Platform.isWindows) {
    return 'System/call audio needs native loopback capture '
        '(Windows WASAPI loopback or the Rust engine).';
  }
  return 'System/call audio needs native loopback capture '
      '(a PulseAudio/PipeWire monitor or the Rust engine).';
}

class RecordMeetingAudioService implements MeetingAudioService {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  int _bytesCaptured = 0;

  AudioCapabilities _capabilities = AudioCapabilities(
    microphone: AudioSourceStatus.permissionRequired,
    systemAudio: AudioSourceStatus.unsupported,
    systemAudioNote: _systemAudioNoteForPlatform(),
  );

  @override
  AudioCapabilities get capabilities => _capabilities;

  /// Total microphone bytes seen this session — lets the UI show that capture is live.
  int get bytesCaptured => _bytesCaptured;

  @override
  Future<AudioCapabilities> requestPermissions() async {
    AudioSourceStatus mic;
    try {
      mic = await _recorder.hasPermission()
          ? AudioSourceStatus.available
          : AudioSourceStatus.permissionRequired;
    } catch (_) {
      mic = AudioSourceStatus.unavailable;
    }
    _capabilities = _capabilities.copyWith(microphone: mic);
    return _capabilities;
  }

  @override
  Future<void> startMicrophone() async {
    if (_capabilities.microphone != AudioSourceStatus.available) {
      await requestPermissions();
    }
    if (_capabilities.microphone != AudioSourceStatus.available) return;

    _bytesCaptured = 0;
    final stream = await _recorder.startStream(
      const RecordConfig(encoder: AudioEncoder.pcm16bits),
    );
    _micSub = stream.listen(
      (chunk) => _bytesCaptured += chunk.length,
      cancelOnError: false,
    );
  }

  @override
  Future<void> startSystemAudio() async {
    // Intentionally a no-op: unsupported on this platform. See class docs.
  }

  @override
  Future<void> start() async {
    await requestPermissions();
    await startMicrophone();
    await startSystemAudio();
  }

  @override
  Future<void> pause() async {
    if (await _recorder.isRecording()) await _recorder.pause();
  }

  @override
  Future<void> resume() async {
    if (await _recorder.isPaused()) await _recorder.resume();
  }

  @override
  Future<void> stop() async {
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _recorder.isRecording() || await _recorder.isPaused()) {
        await _recorder.stop();
      }
    } catch (_) {
      // Already stopped / never started.
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
