import 'dart:async';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:pp_playback_engine/pp_playback_engine.dart';
import 'package:ppplayer/core/playback/ultratube_playback_controller.dart';

class RecordingEngine extends Fake implements PlaybackController {
  final opened = <PlaybackTrack>[];
  final starts = <Duration>[];
  final intents = <bool>[];
  final _status = StreamController<PlaybackStatus>.broadcast(sync: true);
  PlaybackStatus status = const PlaybackStatus();
  @override
  PlaybackStatus get currentStatus => status;
  @override
  Stream<PlaybackStatus> get statusStream => _status.stream;

  /// Simulates the native player reporting [next].
  void emit(PlaybackStatus next) => _status.add(status = next);
  @override
  Future<void> stop() async {}
  @override
  Future<void> pause({
    String caller = 'user',
    bool failOnTimeout = false,
  }) async {}
  @override
  Future<void> play(
    PlaybackTrack track, {
    Duration startAt = Duration.zero,
    bool play = true,
  }) async {
    opened.add(track);
    starts.add(startAt);
    intents.add(play);
    status = PlaybackStatus(
      track: track,
      position: startAt,
      state: play ? PlaybackState.playing : PlaybackState.paused,
    );
  }

  @override
  Future<void> dispose() async {}
}

const first = PlaybackTrack(id: 'abcdefghijk', title: 'First');
const second = PlaybackTrack(id: '12345678901', title: 'Second');
void main() {
  test('failed video resolution leaves existing audio playing', () async {
    final engine = RecordingEngine();
    var videoMode = false;
    final controller = UltratubePlaybackController(
      engine,
      video: () => videoMode,
      resolve: (_, {required video}) async {
        if (video) throw StateError('No video stream');
        return {'stream': 'https://example.com/audio'};
      },
    );
    await controller.play(first, startAt: const Duration(seconds: 12));
    videoMode = true;
    await expectLater(controller.refreshVideoMode(), throwsStateError);
    expect(engine.opened.length, 1);
    expect(controller.currentStatus.isPlaying, true);
    expect(controller.currentStatus.position, const Duration(seconds: 12));
  });
  test('late extraction cannot replace the newer selection', () async {
    final engine = RecordingEngine();
    final pending = <String, Completer<Map<String, dynamic>>>{};
    final controller = UltratubePlaybackController(
      engine,
      video: () => false,
      resolve: (id, {required video}) => (pending[id] = Completer()).future,
    );
    final a = controller.play(first);
    await Future<void>.delayed(Duration.zero);
    final b = controller.play(second);
    await Future<void>.delayed(Duration.zero);
    pending[second.id]!.complete({'stream': 'https://example.com/second'});
    await b;
    pending[first.id]!.complete({'stream': 'https://example.com/first'});
    await a;
    expect(engine.opened.map((t) => t.id), [second.id]);
    expect(controller.currentStatus.track, same(second));
    expect(controller.currentStatus.activeVideoId, second.id);
  });
  test(
    'pause during extraction survives when the stream becomes ready',
    () async {
      final engine = RecordingEngine();
      final pending = Completer<Map<String, dynamic>>();
      final controller = UltratubePlaybackController(
        engine,
        video: () => false,
        resolve: (_, {required video}) => pending.future,
      );
      final playing = controller.play(first);
      await Future<void>.delayed(Duration.zero);
      await controller.pause();
      pending.complete({'stream': 'https://example.com/audio'});
      await playing;
      expect(engine.intents, [false]);
    },
  );
  test('stop invalidates in-flight extraction', () async {
    final engine = RecordingEngine();
    final pending = Completer<Map<String, dynamic>>();
    final controller = UltratubePlaybackController(
      engine,
      video: () => false,
      resolve: (_, {required video}) => pending.future,
    );
    final playing = controller.play(first);
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    pending.complete({'stream': 'https://example.com/audio'});
    await playing;
    expect(engine.opened, isEmpty);
  });
  test(
    'switching cover to video retains the position and paused intent',
    () async {
      final engine = RecordingEngine();
      var videoMode = false;
      final modes = <bool>[];
      final controller = UltratubePlaybackController(
        engine,
        video: () => videoMode,
        resolve: (_, {required video}) async {
          modes.add(video);
          return {'stream': 'https://example.com/media'};
        },
      );
      await controller.play(
        first,
        startAt: const Duration(seconds: 42),
        play: false,
      );
      videoMode = true;
      await controller.refreshVideoMode();
      expect(modes, [false, true]);
      expect(engine.starts.last, const Duration(seconds: 42));
      expect(engine.intents.last, false);
      expect(engine.opened.last.sourceType, PlaybackSourceType.networkStream);
      expect(engine.opened.last.isVideo, true);
    },
  );

  group('connection recovery', () {
    test('a stream error is re-extracted and resumed where it stopped', () async {
      final engine = RecordingEngine();
      var resolves = 0;
      final controller = UltratubePlaybackController(
        engine,
        video: () => false,
        resolve: (_, {required video}) async {
          resolves++;
          return {'stream': 'https://example.com/audio$resolves'};
        },
      );
      final seen = <PlaybackStatus>[];
      controller.statusStream.listen(seen.add);
      await controller.play(first);
      engine.emit(engine.status.copyWith(position: const Duration(seconds: 95)));
      engine.emit(
        engine.status.copyWith(
          state: PlaybackState.error,
          error: 'error:connection_lost',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      // The UI never sees the error: it is shown as buffering.
      expect(seen.last.state, PlaybackState.buffering);
      expect(seen.last.error, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(resolves, 2);
      expect(engine.opened.length, 2);
      expect(engine.opened.last.networkMediaUri, 'https://example.com/audio2');
      expect(engine.starts.last, const Duration(seconds: 95));
      expect(engine.intents.last, true);
    });

    test('transient extraction failures are retried on play', () async {
      final engine = RecordingEngine();
      var calls = 0;
      final controller = UltratubePlaybackController(
        engine,
        video: () => false,
        resolve: (_, {required video}) async {
          if (++calls == 1) {
            throw PlatformException(code: 'ultratube_error', message: 'timeout');
          }
          return {'stream': 'https://example.com/audio'};
        },
      );
      await controller.play(first);
      expect(calls, 2);
      expect(engine.opened.single.networkMediaUri, 'https://example.com/audio');
    });

    test('unavailable content is not retried', () async {
      final engine = RecordingEngine();
      var calls = 0;
      final controller = UltratubePlaybackController(
        engine,
        video: () => false,
        resolve: (_, {required video}) async {
          calls++;
          throw PlatformException(code: 'unavailable', message: 'Private video');
        },
      );
      await expectLater(controller.play(first), throwsA(isA<PlatformException>()));
      expect(calls, 1);
      expect(engine.opened, isEmpty);
    });

    test('an error is surfaced once recovery cannot succeed', () async {
      final engine = RecordingEngine();
      var calls = 0;
      final controller = UltratubePlaybackController(
        engine,
        video: () => false,
        resolve: (_, {required video}) async {
          if (++calls > 1) {
            throw PlatformException(code: 'unavailable', message: 'Removed');
          }
          return {'stream': 'https://example.com/audio'};
        },
      );
      final seen = <PlaybackStatus>[];
      controller.statusStream.listen(seen.add);
      await controller.play(first);
      engine.emit(engine.status.copyWith(state: PlaybackState.error, error: 'error:forbidden'));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(seen.last.state, PlaybackState.error);
      expect(seen.last.error, 'error:unavailable');
      expect(engine.opened.length, 1);
    });
  });
}
