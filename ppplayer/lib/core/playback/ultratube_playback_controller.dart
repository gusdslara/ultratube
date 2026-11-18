import 'dart:async';
import 'package:pp_playback_engine/pp_playback_engine.dart';

import '../api/sponsorblock.dart';
import '../api/ultratube_catalog.dart';

typedef ResolveUltratubeMedia =
    Future<Map<String, dynamic>> Function(String id, {required bool video});
typedef LoadSkipSegments = Future<List<SkipSegment>> Function(String id);

/// Short-lived cache of resolved stream URLs so the next queue item can be
/// extracted while the current one plays (YouTube URLs live ~6 h).
class UltratubeResolveCache {
  static const _ttl = Duration(minutes: 45);
  static final _entries = <String, (DateTime, Future<Map<String, dynamic>>)>{};

  static String _key(String id, bool video, int maxHeight) =>
      '$id|${video ? maxHeight : 0}';

  static Future<Map<String, dynamic>> get(
    String id, {
    required bool video,
    required int maxHeight,
    required Future<Map<String, dynamic>> Function() resolve,
  }) {
    final key = _key(id, video, maxHeight);
    final hit = _entries[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _ttl) return hit.$2;
    final future = resolve();
    _entries[key] = (DateTime.now(), future);
    // Failures must not be cached.
    future.catchError((Object _) {
      _entries.remove(key);
      return <String, dynamic>{};
    });
    if (_entries.length > 40) _entries.remove(_entries.keys.first);
    return future;
  }

  /// Starts resolving [id] in the background.
  static void warm(String id, {required bool video, required int maxHeight}) {
    unawaited(
      get(
        id,
        video: video,
        maxHeight: maxHeight,
        resolve: () => const UltratubeCatalog().resolve(
          id,
          video: video,
          maxHeight: maxHeight,
        ),
      ).then((_) {}, onError: (Object _) {}),
    );
  }

  static void forget(String id) =>
      _entries.removeWhere((key, _) => key.startsWith('$id|'));
}

/// Resolves expiring URLs at playback time while retaining durable queue identity.
/// Generation guards prevent a slow extraction from replacing a later selection.
/// When [segments] is set, community-reported sponsor ranges are skipped.
class UltratubePlaybackController implements PlaybackController {
  UltratubePlaybackController(
    this._engine, {
    required this.resolve,
    required this.video,
    this.segments,
    this.skipEnabled,
    this.onSkip,
    this.maxHeight,
  });

  /// When set, resolutions go through [UltratubeResolveCache] (prefetch).
  final int Function()? maxHeight;
  final PlaybackController _engine;
  final ResolveUltratubeMedia resolve;
  final bool Function() video;
  final LoadSkipSegments? segments;
  final bool Function()? skipEnabled;
  final void Function(SkipSegment segment)? onSkip;
  PlaybackTrack? _original;
  int _generation = 0;
  bool _disposed = false;
  bool _playWhenReady = false;
  List<SkipSegment> _segments = const [];
  final Set<SkipSegment> _skipped = {};

  void _checkSkip(PlaybackStatus status) {
    final track = _original;
    if (_segments.isEmpty || track == null || status.track?.id != track.id) {
      return;
    }
    if (skipEnabled != null && !skipEnabled!()) return;
    final position = status.position;
    for (final segment in _segments) {
      if (position >= segment.start &&
          position < segment.end - const Duration(milliseconds: 500) &&
          _skipped.add(segment)) {
        unawaited(_engine.seekTo(segment.end));
        onSkip?.call(segment);
        return;
      }
    }
  }

  Future<void> _loadSegments(String id, int generation) async {
    final loader = segments;
    if (loader == null) return;
    try {
      final result = await loader(id);
      if (!_disposed && generation == _generation) _segments = result;
    } catch (_) {
      // Skipping is best effort; playback never depends on it.
    }
  }
  PlaybackStatus _restore(PlaybackStatus status) =>
      _original != null && status.track?.id == _original!.id
      ? status.copyWith(
          track: _original,
          activeVideoId: _original!.sourceType == PlaybackSourceType.online
              ? _original!.id
              : status.activeVideoId,
        )
      : status;
  @override
  Stream<PlaybackStatus> get statusStream => _engine.statusStream.map((s) {
    // A failed stream URL must be re-extracted on retry, never reused.
    if (s.state == PlaybackState.error && s.track != null) {
      UltratubeResolveCache.forget(s.track!.id);
    }
    _checkSkip(s);
    return _restore(s);
  });
  @override
  Stream<PlaybackEvent> get eventStream => _engine.eventStream;
  @override
  PlaybackStatus get currentStatus => _restore(_engine.currentStatus);

  @override
  Future<void> play(
    PlaybackTrack track, {
    Duration startAt = Duration.zero,
    bool play = true,
  }) async {
    final generation = ++_generation;
    _playWhenReady = play;
    _segments = const [];
    _skipped.clear();
    if (_disposed) throw StateError('Player encerrado');
    // Stop the old track while extraction is pending; never overlap selections.
    await _engine.stop();
    if (_disposed || generation != _generation) return;
    var resolved = track;
    if (track.sourceType == PlaybackSourceType.online) {
      unawaited(_loadSegments(track.id, generation));
      final wantsVideo = video();
      final height = maxHeight;
      final media = height == null
          ? await resolve(track.id, video: wantsVideo)
          : await UltratubeResolveCache.get(
              track.id,
              video: wantsVideo,
              maxHeight: height(),
              resolve: () => resolve(track.id, video: wantsVideo),
            );
      if (_disposed || generation != _generation) return;
      resolved = _resolved(track, media, wantsVideo);
    }
    _original = track;
    await _engine.play(resolved, startAt: startAt, play: _playWhenReady);
  }

  PlaybackTrack _resolved(
    PlaybackTrack track,
    Map<String, dynamic> media,
    bool wantsVideo,
  ) {
    // The resolver is the authority on liveness: a queued item may have been
    // saved before the broadcast started (or after it ended).
    final live = media['live'] == true;
    return PlaybackTrack(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      artworkUrl: track.artworkUrl,
      // A live HLS window has no fixed length; leaving it null keeps the
      // engine from treating the stream as seekable/finite.
      duration: live ? null : track.duration,
      sourceType: PlaybackSourceType.networkStream,
      networkMediaUri: media['stream'] as String,
      // Lives also come as one video rendition + its HLS audio group.
      externalAudioUri: media['audio'] as String?,
      isVideo: wantsVideo,
      liveStatus: live ? PlaybackLiveStatus.live : track.liveStatus,
    );
  }

  /// Re-resolves the current item (video/audio switch or quality change)
  /// and resumes at the same position.
  Future<void> refreshVideoMode() async {
    final track = _original;
    if (track == null || track.sourceType != PlaybackSourceType.online) return;
    final generation = ++_generation;
    final wantsVideo = video();
    // Resolve first. A failed video request must not stop working audio.
    final media = await resolve(track.id, video: wantsVideo);
    if (_disposed || generation != _generation) return;
    final position = currentStatus.position;
    await _engine.play(
      _resolved(track, media, wantsVideo),
      startAt: position,
      play: _playWhenReady,
    );
  }

  // Do not let speculative prefetch replace the currently playing media.
  @override
  Future<void> prepare(PlaybackTrack track, {Duration? position}) async {}
  @override
  Future<void> stop() async {
    ++_generation;
    _original = null;
    await _engine.stop();
  }

  @override
  Future<void> pause({String caller = 'user', bool failOnTimeout = false}) {
    _playWhenReady = false;
    return _engine.pause(caller: caller, failOnTimeout: failOnTimeout);
  }

  @override
  Future<void> resume() {
    _playWhenReady = true;
    return _engine.resume();
  }

  @override
  Future<void> seekTo(Duration position) => _engine.seekTo(position);
  @override
  Future<void> setVolume(double volume) => _engine.setVolume(volume);
  @override
  Future<void> setSpeed(double speed) => _engine.setSpeed(speed);
  @override
  Future<void> setSubtitleTrack(String? uri) => _engine.setSubtitleTrack(uri);
  @override
  Future<void> setSubtitleDelay(Duration delay) =>
      _engine.setSubtitleDelay(delay);
  @override
  Future<void> setSubtitleAppearance({
    double? textSize,
    int? backgroundColor,
  }) => _engine.setSubtitleAppearance(
    textSize: textSize,
    backgroundColor: backgroundColor,
  );
  @override
  bool get supportsSpeed => _engine.supportsSpeed;
  @override
  bool get supportsTrackSelection => _engine.supportsTrackSelection;
  @override
  bool get supportsExternalSubtitles => _engine.supportsExternalSubtitles;
  @override
  bool get supportsSubtitleDelay => _engine.supportsSubtitleDelay;
  @override
  bool get supportsSubtitleTextSize => _engine.supportsSubtitleTextSize;
  @override
  bool get supportsSubtitleBackgroundStyling =>
      _engine.supportsSubtitleBackgroundStyling;
  @override
  bool get supportsVideoFitMode => _engine.supportsVideoFitMode;
  @override
  dynamic get renderer => _engine.renderer;
  @override
  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    await _engine.dispose();
  }
}
