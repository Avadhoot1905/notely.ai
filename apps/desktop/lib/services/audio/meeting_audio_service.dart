// Audio capture abstraction for a meeting session.
//
// The UI talks to this interface only — never to platform audio APIs. A session captures the
// microphone and, where a loopback endpoint exists, system/speaker audio. Both are reported
// HONESTLY via [AudioCapabilities]: a source only reports `capturing` once real PCM frames have
// actually arrived, `available` when an endpoint is found/opened but no frames have arrived yet,
// and `error` when opening the endpoint failed.
//
// Future: `start*` would hand PCM frames to the Rust engine over IPC for ASR. Today each stream is
// opened and its frames are counted/drained (no bytes are stored or processed yet — that's the
// engine's job later). Byte counters + a peak-amplitude probe exist purely to prove the capture
// path is live and to distinguish "no frames" from "frames arriving but silent".
//
// System-audio routing model (macOS, the reference platform):
//
//   app/system audio ──▶ loopback device (BlackHole / Background Music / Aggregate)
//                              │  (user must route output INTO this device — step Notely can't do)
//                              ▼
//                     the device's INPUT/capture endpoint
//                              │  (record → AVAudioEngine.inputNode.setDeviceID by CoreAudio UID)
//                              ▼
//                     PCM stream Notely records
//
// Detecting the device only proves the capture endpoint EXISTS. Whether the user has routed system
// output into it is a separate step — so we never claim `capturing` until frames actually arrive.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Availability of an individual audio source. Ordered from strongest to weakest positive claim.
enum AudioSourceStatus {
  /// Endpoint opened AND real PCM frames have arrived. The strongest claim.
  capturing,

  /// Endpoint found (and, for a capture source, opened) but no frames have arrived yet.
  available,

  /// The OS needs the user to grant capture permission first.
  permissionRequired,

  /// No capture path exists on this platform/config (e.g. no loopback device installed).
  unsupported,

  /// A source that should exist could not be used (e.g. probe failed).
  unavailable,

  /// The endpoint exists but opening/recording it failed.
  error,
}

/// Snapshot of what audio sources this platform/session can use.
@immutable
class AudioCapabilities {
  const AudioCapabilities({
    required this.microphone,
    required this.systemAudio,
    this.systemAudioNote,
    this.microphoneNote,
  });

  final AudioSourceStatus microphone;
  final AudioSourceStatus systemAudio;

  /// Human-readable explanation for the system-audio status (shown in the UI).
  final String? systemAudioNote;

  /// Human-readable explanation for the microphone status (shown in the UI).
  final String? microphoneNote;

  AudioCapabilities copyWith({
    AudioSourceStatus? microphone,
    AudioSourceStatus? systemAudio,
    String? systemAudioNote,
    String? microphoneNote,
  }) => AudioCapabilities(
    microphone: microphone ?? this.microphone,
    systemAudio: systemAudio ?? this.systemAudio,
    systemAudioNote: systemAudioNote ?? this.systemAudioNote,
    microphoneNote: microphoneNote ?? this.microphoneNote,
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

// ---------------------------------------------------------------------------
// Loopback device detection (system audio).
// ---------------------------------------------------------------------------

/// Pick the best loopback device from [devices] by walking [hints] in priority order and taking the
/// first device whose (lower-cased) label contains a hint. Pure and hardware-free, so the ranking /
/// false-positive behavior is unit-testable. Returns `null` when nothing matches.
@visibleForTesting
InputDevice? selectLoopbackDevice(
  List<InputDevice> devices,
  List<String> hints,
) {
  for (final hint in hints) {
    for (final d in devices) {
      if (d.label.toLowerCase().contains(hint)) return d;
    }
  }
  return null;
}

/// Exposed for tests: the ranked, platform-scoped loopback hints for the running platform.
@visibleForTesting
List<String> loopbackHintsForPlatform() => _loopbackHintsForPlatform();

/// Loopback input-device name hints, **ranked** (strongest first) and **scoped per platform** so we
/// don't match, say, a macOS display named "…Monitor" or an output-only "Multi-Output" device.
///
/// Note: on macOS `record.listInputDevices()` is backed by `AVCaptureDevice` audio discovery, which
/// only returns *input-capable* devices — so a pure output/Multi-Output device won't appear here at
/// all. The hints still exist to pick a *loopback* input among possibly several real inputs, and to
/// keep the intent legible on the platforms we can't runtime-verify.
List<String> _loopbackHintsForPlatform() {
  if (Platform.isMacOS) {
    // Real virtual loopback devices first; "aggregate" last (an aggregate may or may not be a
    // loopback, so only pick it when nothing more specific matched).
    return const [
      'blackhole',
      'background music',
      'soundflower',
      'loopback', // Rogue Amoeba Loopback
      'aggregate',
    ];
  }
  if (Platform.isWindows) {
    return const [
      'stereo mix',
      'vb-audio',
      'vb-cable',
      'cable output',
      'voicemeeter',
      'wave link',
    ];
  }
  // Linux (PulseAudio/PipeWire). A capturable loopback is a monitor source.
  return const ['monitor', 'pipewire', 'pulse', 'loopback'];
}

String _systemAudioSetupHint() {
  if (Platform.isMacOS) {
    return 'No loopback input found. Install a virtual audio device (e.g. BlackHole or '
        'Background Music) and route system output through it.';
  }
  if (Platform.isWindows) {
    return 'No loopback input found. Enable "Stereo Mix" in Sound settings, or install a '
        'virtual cable (VB-CABLE / VoiceMeeter).';
  }
  return 'No loopback input found. Select the PulseAudio/PipeWire "Monitor of <output>" source.';
}

/// Highest int16 sample magnitude (0..32767) in a little-endian PCM16 buffer — a cheap "is this
/// silent?" probe used only to log whether arriving frames actually carry sound. Not used to gate
/// availability (legitimately-silent system audio must still count as capturing).
int _peakPcm16(Uint8List pcm16le) {
  final n = pcm16le.lengthInBytes & ~1; // whole samples only
  if (n == 0) return 0;
  final data = ByteData.sublistView(pcm16le, 0, n);
  var peak = 0;
  // Sample at most ~512 points per chunk so this stays O(1)-ish regardless of buffer size.
  final step = (n ~/ 2 <= 512) ? 2 : ((n ~/ 2 ~/ 512) * 2);
  for (var i = 0; i + 1 < n; i += step) {
    final v = data.getInt16(i, Endian.little).abs();
    if (v > peak) peak = v;
  }
  return peak;
}

/// Below this int16 peak a frame is treated as silence for diagnostic logging (~ -60 dBFS).
const int _silenceThreshold = 32;

class RecordMeetingAudioService implements MeetingAudioService {
  /// [onCapabilitiesChanged] is invoked when a source's status changes *after* start (e.g. the
  /// first PCM frame flips `available` → `capturing`, or an open fails → `error`) so the UI can
  /// refresh. Optional: injected fakes/tests don't need it.
  RecordMeetingAudioService({VoidCallback? onCapabilitiesChanged})
    : _onChanged = onCapabilitiesChanged;

  final VoidCallback? _onChanged;

  final AudioRecorder _micRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  int _micBytes = 0;
  bool _micFramesArrived = false;

  // System audio is captured from a SEPARATE recorder bound to a loopback input device, so it
  // never shares state with the microphone stream.
  final AudioRecorder _sysRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sysSub;
  int _sysBytes = 0;
  bool _sysFramesArrived = false;
  bool _sysHeardSound = false;
  InputDevice? _loopbackDevice;

  AudioCapabilities _capabilities = AudioCapabilities(
    microphone: AudioSourceStatus.permissionRequired,
    systemAudio: AudioSourceStatus.unsupported,
    systemAudioNote: _systemAudioSetupHint(),
  );

  @override
  AudioCapabilities get capabilities => _capabilities;

  /// Total microphone bytes seen this session — lets the UI show that capture is live.
  int get bytesCaptured => _micBytes;

  /// Total system-audio bytes seen this session.
  int get systemBytesCaptured => _sysBytes;

  void _setSystem(AudioSourceStatus status, String note) {
    _capabilities = _capabilities.copyWith(
      systemAudio: status,
      systemAudioNote: note,
    );
    _onChanged?.call();
  }

  void _setMicrophone(AudioSourceStatus status, {String? note}) {
    _capabilities = _capabilities.copyWith(
      microphone: status,
      microphoneNote: note,
    );
    _onChanged?.call();
  }

  /// Find the best loopback input device (ranked hints), if any. Every returned device came from
  /// [AudioRecorder.listInputDevices], so it is already an input-capable capture endpoint; we then
  /// pick the one whose label best matches a known loopback device, using its stable [InputDevice.id].
  Future<InputDevice?> _findLoopbackDevice() async {
    List<InputDevice> devices;
    try {
      devices = await _micRecorder.listInputDevices();
    } catch (e) {
      debugPrint('[SystemAudio] listInputDevices failed: $e');
      return null;
    }
    debugPrint(
      '[SystemAudio] enumerated ${devices.length} input device(s): '
      '${devices.map((d) => d.label).join(', ')}',
    );
    final device = selectLoopbackDevice(devices, _loopbackHintsForPlatform());
    if (device != null) {
      debugPrint(
        '[SystemAudio] selected loopback input: "${device.label}" (id=${device.id})',
      );
    } else {
      debugPrint('[SystemAudio] no loopback input found');
    }
    return device;
  }

  @override
  Future<AudioCapabilities> requestPermissions() async {
    AudioSourceStatus mic;
    String? micNote;
    try {
      mic = await _micRecorder.hasPermission()
          ? AudioSourceStatus.available
          : AudioSourceStatus.permissionRequired;
    } catch (e) {
      mic = AudioSourceStatus.unavailable;
      micNote = 'Microphone unavailable: $e';
    }

    // Detecting a loopback endpoint only proves it EXISTS. We report `available` (endpoint found);
    // the real open happens in [startSystemAudio], which downgrades to `error` on failure and
    // upgrades to `capturing` once frames actually arrive.
    _loopbackDevice = await _findLoopbackDevice();
    final AudioSourceStatus sys;
    final String sysNote;
    if (_loopbackDevice != null) {
      sys = AudioSourceStatus.available;
      sysNote =
          'Loopback input "${_loopbackDevice!.label}" found. Route system output into it to capture.';
    } else {
      sys = AudioSourceStatus.unsupported;
      sysNote = _systemAudioSetupHint();
    }

    _capabilities = AudioCapabilities(
      microphone: mic,
      microphoneNote: micNote,
      systemAudio: sys,
      systemAudioNote: sysNote,
    );
    return _capabilities;
  }

  @override
  Future<void> startMicrophone() async {
    if (_capabilities.microphone != AudioSourceStatus.available &&
        _capabilities.microphone != AudioSourceStatus.capturing) {
      await requestPermissions();
    }
    if (_capabilities.microphone != AudioSourceStatus.available) return;

    _micBytes = 0;
    _micFramesArrived = false;
    try {
      final stream = await _micRecorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits),
      );
      _micSub = stream.listen(
        _onMicChunk,
        onError: (Object e) {
          debugPrint('[Mic] stream error: $e');
          _setMicrophone(
            AudioSourceStatus.error,
            note: 'Microphone stream error: $e',
          );
        },
        cancelOnError: false,
      );
      debugPrint('[Mic] stream opened');
    } catch (e) {
      // A microphone failure must not abort the whole session (system audio / transcript continue).
      debugPrint('[Mic] failed to open: $e');
      _setMicrophone(
        AudioSourceStatus.error,
        note: 'Could not open microphone: $e',
      );
    }
  }

  void _onMicChunk(Uint8List chunk) {
    _micBytes += chunk.length;
    if (!_micFramesArrived && chunk.isNotEmpty) {
      _micFramesArrived = true;
      debugPrint('[Mic] first PCM frames received (${chunk.length} bytes)');
      _setMicrophone(AudioSourceStatus.capturing);
    }
  }

  @override
  Future<void> startSystemAudio() async {
    if (_capabilities.systemAudio == AudioSourceStatus.unsupported) {
      await requestPermissions();
    }
    final device = _loopbackDevice;
    if (device == null) {
      return; // No loopback endpoint — honest no-op (status stays unsupported).
    }

    _sysBytes = 0;
    _sysFramesArrived = false;
    _sysHeardSound = false;
    debugPrint(
      '[SystemAudio] opening PCM stream: pcm16 from "${device.label}" (id=${device.id})',
    );
    try {
      final stream = await _sysRecorder.startStream(
        RecordConfig(encoder: AudioEncoder.pcm16bits, device: device),
      );
      _sysSub = stream.listen(
        _onSystemChunk,
        onError: (Object e) {
          debugPrint('[SystemAudio] stream error: $e');
          _setSystem(
            AudioSourceStatus.error,
            'System-audio stream error on "${device.label}": $e',
          );
        },
        cancelOnError: false,
      );
      debugPrint('[SystemAudio] stream opened');
      // Opened, but nothing has arrived yet: keep `available` with an accurate note.
      _setSystem(
        AudioSourceStatus.available,
        'Opened "${device.label}" — waiting for audio '
        '(route system output into this device).',
      );
    } catch (e) {
      // The endpoint exists but couldn't be opened (busy, unusable format, revoked device, …).
      debugPrint(
        '[SystemAudio] failed to open "${device.label}" (id=${device.id}): $e',
      );
      _setSystem(
        AudioSourceStatus.error,
        'Could not open "${device.label}" for capture: $e',
      );
    }
  }

  void _onSystemChunk(Uint8List chunk) {
    _sysBytes += chunk.length;
    if (chunk.isEmpty) return;
    if (!_sysFramesArrived) {
      _sysFramesArrived = true;
      debugPrint(
        '[SystemAudio] first PCM frames received (${chunk.length} bytes)',
      );
      _setSystem(
        AudioSourceStatus.capturing,
        'Capturing system audio from "${_loopbackDevice?.label ?? 'loopback'}".',
      );
    }
    // Diagnostic only: distinguish "frames arriving but silent" from "frames carrying sound".
    if (!_sysHeardSound && _peakPcm16(chunk) > _silenceThreshold) {
      _sysHeardSound = true;
      debugPrint('[SystemAudio] non-silent audio detected');
    }
  }

  @override
  Future<void> start() async {
    await requestPermissions();
    // Each source is isolated: a failure in one never prevents the other (or the transcript).
    await startMicrophone();
    await startSystemAudio();
  }

  @override
  Future<void> pause() async {
    for (final r in [_micRecorder, _sysRecorder]) {
      try {
        if (await r.isRecording()) await r.pause();
      } catch (_) {
        // Not recording / already paused.
      }
    }
  }

  @override
  Future<void> resume() async {
    for (final r in [_micRecorder, _sysRecorder]) {
      try {
        if (await r.isPaused()) await r.resume();
      } catch (_) {
        // Not paused / already recording.
      }
    }
  }

  @override
  Future<void> stop() async {
    await _micSub?.cancel();
    _micSub = null;
    await _sysSub?.cancel();
    _sysSub = null;
    for (final r in [_micRecorder, _sysRecorder]) {
      try {
        if (await r.isRecording() || await r.isPaused()) await r.stop();
      } catch (_) {
        // Already stopped / never started.
      }
    }
    if (_sysBytes > 0 || _micBytes > 0) {
      debugPrint(
        '[SystemAudio] stream stopped ($_sysBytes bytes) · [Mic] ($_micBytes bytes)',
      );
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _micRecorder.dispose();
    await _sysRecorder.dispose();
  }
}
