// On-device audio-capture probe (run with `flutter test integration_test/... -d macos`).
//
// Unlike unit tests, this runs with the real `record` plugin registered, so it exercises the actual
// CoreAudio path. It prints EVIDENCE lines for each verification point. It cannot produce sound, so
// it verifies "frames arrive" (inputs are live even when silent), not "non-silent from known audio".

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart';
import 'package:notely_desktop/services/audio/audio_ingestion.dart';
import 'package:notely_desktop/services/audio/meeting_audio_service.dart';
import 'package:notely_desktop/services/audio/speech_segmenter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures real PCM from microphone and system-audio loopback', (
    tester,
  ) async {
    final svc = RecordMeetingAudioService(onCapabilitiesChanged: () {});

    // Wire capture → ingestion so we can prove PCM reaches the new boundary (not just the counters).
    final ingestion = AudioIngestion(startedAt: DateTime.now());
    var ingestedMic = 0;
    var ingestedSystem = 0;
    // Run frames through VAD + segmentation exactly as ListeningController does — this is the path
    // that reads AudioFrame.samples and previously crashed on real (odd-byteOffset) recorder chunks.
    final segmenters = {
      AudioSource.microphone: SpeechSegmenter(source: AudioSource.microphone),
      AudioSource.system: SpeechSegmenter(source: AudioSource.system),
    };
    final ingestSub = ingestion.frames.listen((f) {
      if (f.source == AudioSource.microphone) {
        ingestedMic++;
      } else {
        ingestedSystem++;
      }
      segmenters[f.source]?.add(
        f,
      ); // exercises EnergyVad → AudioFrame.samples on live PCM
    });
    final framesSub = svc.frames.listen(ingestion.add);

    final caps = await svc.requestPermissions();
    debugPrint('EVIDENCE mic.permission=${caps.microphone}');
    debugPrint('EVIDENCE systemAudio.detect=${caps.systemAudio}');
    debugPrint('EVIDENCE systemAudio.note=${caps.systemAudioNote}');

    // Start both sources.
    await svc.startMicrophone();
    await svc.startSystemAudio();

    // Let real frames flow. pump() keeps the embedder alive while CoreAudio delivers buffers.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    debugPrint('EVIDENCE mic.status=${svc.capabilities.microphone}');
    debugPrint('EVIDENCE mic.bytes=${svc.bytesCaptured}');
    debugPrint('EVIDENCE systemAudio.status=${svc.capabilities.systemAudio}');
    debugPrint('EVIDENCE systemAudio.bytes=${svc.systemBytesCaptured}');
    debugPrint('EVIDENCE systemAudio.note=${svc.capabilities.systemAudioNote}');

    // Lifecycle: pause/resume/stop must not throw and must settle both streams.
    await svc.pause();
    await tester.pump(const Duration(milliseconds: 100));
    await svc.resume();
    await tester.pump(const Duration(milliseconds: 200));
    await svc.stop();
    debugPrint(
      'EVIDENCE afterStop mic.bytes=${svc.bytesCaptured} sys.bytes=${svc.systemBytesCaptured}',
    );

    // Second session: counters must reset and capture must resume cleanly.
    await svc.startSystemAudio();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint(
      'EVIDENCE session2 systemAudio.bytes=${svc.systemBytesCaptured}',
    );
    await svc.stop();

    debugPrint('EVIDENCE ingestion.micFrames=$ingestedMic');
    debugPrint('EVIDENCE ingestion.systemFrames=$ingestedSystem');
    debugPrint('EVIDENCE ingestion.dropped=${ingestion.dropped}');

    await framesSub.cancel();
    await ingestSub.cancel();
    await ingestion.dispose();
    await svc.dispose();

    // The only hard assertion: a loopback endpoint was detected on this machine. Frame-arrival at
    // the ingestion boundary is reported as evidence rather than asserted, since it depends on OS
    // routing/permission state.
    expect(
      caps.systemAudio,
      isNot(AudioSourceStatus.unsupported),
      reason: 'expected a loopback input device to be detected',
    );
  });
}
