import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ppplayer/core/api/spotify_repository.dart';
import 'package:ppplayer/core/models/track.dart';
import 'package:ppplayer/core/playback/playback_providers.dart';
import 'package:ppplayer/core/player/player_provider.dart';
import 'package:ppplayer/core/services/settings_provider.dart';
import 'package:ppplayer/core/ultratube/ultratube_store.dart';

import 'autoplay_test.dart' as fakes;

class _Autoplay extends AutoplayNotifier {
  _Autoplay(this.value);
  final bool value;
  @override
  bool build() => value;
}

Track _track(String id, {QueueItemOrigin origin = QueueItemOrigin.context}) =>
    Track(
      spotifyId: id,
      name: 'Track $id',
      artistId: 'artist',
      artistName: 'Artist',
      queueOrigin: origin,
    );

void main() {
  late Directory hiveDirectory;
  late fakes.FakePlaybackController controller;

  setUp(() async {
    hiveDirectory = await Directory.systemTemp.createTemp('ppplayer-hive-');
    Hive.init(hiveDirectory.path);
    await Hive.openBox('player_state');
    controller = fakes.FakePlaybackController();
  });
  tearDown(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  ProviderContainer build({bool autoplay = true}) {
    final container = ProviderContainer(
      overrides: [
        playbackControllerProvider.overrideWithValue(controller),
        playbackServiceProvider.overrideWithValue(fakes.FakePlaybackService()),
        spotifyRepositoryProvider.overrideWithValue(
          fakes.FakeSpotifyRepository(),
        ),
        settingsProvider.overrideWith(fakes.FakeSettingsNotifier.new),
        ultratubeAutoplayProvider.overrideWith(() => _Autoplay(autoplay)),
      ],
    );
    addTearDown(() async {
      final notifier = container.read(playerProvider.notifier);
      container.dispose();
      await notifier.persistenceSettled;
    });
    return container;
  }

  List<String> ids(ProviderContainer c) => [
    for (final t in c.read(playerProvider).queue) t.spotifyId,
  ];

  test('playNow goes after the current item and keeps what was queued', () async {
    final container = build();
    final notifier = container.read(playerProvider.notifier);
    await notifier.playTrack(
      _track('a'),
      queue: [_track('a'), _track('b'), _track('c')],
    );
    notifier.addToQueue(_track('mine'));
    notifier.addAutoplayTracks([_track('auto')]);
    expect(ids(container), ['a', 'b', 'c', 'mine', 'auto']);

    // Opened from elsewhere: the playlist and the suggestions go away, the
    // viewer's own queue stays next.
    await notifier.playNow(_track('new'));
    expect(ids(container), ['a', 'new', 'mine']);
    expect(container.read(playerProvider).currentTrack?.spotifyId, 'new');
  });

  test('playNow from the watch page continues the playlist afterwards', () async {
    final container = build();
    final notifier = container.read(playerProvider.notifier);
    await notifier.playTrack(
      _track('a'),
      queue: [_track('a'), _track('b'), _track('c')],
    );
    notifier.addAutoplayTracks([_track('auto')]);

    await notifier.playNow(_track('related'), keepContext: true);
    expect(ids(container), ['a', 'related', 'b', 'c']);
    expect(container.read(playerProvider).currentIndex, 1);

    // A queued video picked directly is moved, not duplicated.
    await notifier.playNow(_track('c'), keepContext: true);
    expect(ids(container), ['a', 'related', 'c', 'b']);
    expect(container.read(playerProvider).currentTrack?.spotifyId, 'c');
  });

  test('"tocar em seguida" and "adicionar à fila" stay ahead of suggestions', () async {
    final container = build();
    final notifier = container.read(playerProvider.notifier);
    await notifier.playTrack(_track('a'), queue: [_track('a')]);
    notifier.addAutoplayTracks([_track('s1'), _track('s2'), _track('s1')]);
    notifier.addToQueue(_track('queued'));
    notifier.playNext(_track('next'));
    expect(ids(container), ['a', 'next', 'queued', 's1', 's2']);
  });

  test('suggestions are not queued with autoplay off', () async {
    final container = build(autoplay: false);
    final notifier = container.read(playerProvider.notifier);
    await notifier.playTrack(_track('a'), queue: [_track('a')]);
    notifier.addAutoplayTracks([_track('s1')]);
    expect(ids(container), ['a']);
  });

  test('continuesAfterEnded tells a track change from the end of the queue', () async {
    final container = build();
    final notifier = container.read(playerProvider.notifier);
    await notifier.playTrack(_track('a'), queue: [_track('a'), _track('b')]);
    const status = PlaybackStatus(state: PlaybackState.ended, generation: 7);
    expect(notifier.continuesAfterEnded(status), isTrue);
    notifier.skipTo(1);
    await Future<void>.delayed(Duration.zero);
    expect(notifier.continuesAfterEnded(status), isFalse);
  });
}
