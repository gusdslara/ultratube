import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:pp_playback_engine/pp_playback_engine.dart';

import '../api/sponsorblock.dart';
import '../api/ultratube_catalog.dart';

typedef ResolveUltratubeMedia =
    Future<Map<String, dynamic>> Function(
      String id, {
      required bool video,
      required int maxHeight,
      required String audio,
    });
typedef LoadSkipSegments = Future<List<SkipSegment>> Function(String id);

/// Short-lived cache of resolved stream URLs so the next queue item can be
/// extracted while the current one plays (YouTube URLs live ~6 h).
class UltratubeResolveCache {
  static const _ttl = Duration(minutes: 45);
  static final _entries = <String, (DateTime, Future<Map<String, dynamic>>)>{};

  static String _key(String id, bool video, int maxHeight, String audio) =>
      '$id|${video ? maxHeight : 0}|$audio';

  static Future<Map<String, dynamic>> get(
    String id, {
    required bool video,
    required int maxHeight,
    required String audio,
    required Future<Map<String, dynamic>> Function() resolve,
  }) {
    final key = _key(id, video, maxHeight, audio);
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
  static void warm(
    String id, {
    required bool video,
    required int maxHeight,
    String audio = 'normal',
  }) {
    unawaited(
      get(
        id,
        video: video,
        maxHeight: maxHeight,
        audio: audio,
        resolve: () => const UltratubeCatalog().resolve(
          id,
          video: video,
          maxHeight: maxHeight,
          audio: audio,
        ),
      ).then((_) {}, onError: (Object _) {}),
    );
  }

  static void forget(String id) =>
      _entries.removeWhere((key, _) => key.startsWith('$id|'));
}

/// True when a resolve failure may succeed on a later try (network, YouTube
/// hiccup, timeout). "unavailable" (private/removed/age/region) never will.
bool isTransientResolveError(Object error) {
  if (error is ArgumentError) return false;
  if (error is PlatformException) return error.code != 'unavailable';
  return true;
}

/// Resolves expiring URLs at playback time while retaining durable queue identity.
/// Generation guards prevent a slow extraction from replacing a later selection.
/// When [segments] is set, community-reported sponsor ranges are skipped.
///
/// Connection failures are handled here, below the UI: extraction is retried,
/// and a stream that errors (dead socket after the screen was locked, expired
/// or refused URL, early EOF) is re-extracted and resumed where it stopped.
/// Listeners only see an error once those [_maxRecoveries] attempts fail.
class UltratubePlaybackController implements PlaybackController {
  UltratubePlaybackController(
    this._engine, {
    required this.resolve,
    required this.video,
    this.segments,
    this.skipEnabled,
    this.onSkip,
    this.profile,
  }) {
    _engineSubscription = _engine.statusStream.listen(_onEngineStatus);
  }

  static const _maxRecoveries = 3;
  final _statusOut = StreamController<PlaybackStatus>.broadcast();
  late final StreamSubscription<PlaybackStatus> _engineSubscription;
  int _recoveries = 0;
  bool _recovering = false;
  Duration _lastPosition = Duration.zero;
  Duration? _recoveredAt;

  /// Video height cap and audio quality to stream right now (they follow
  /// the settings and the mobile data saver). When set, resolutions also go
  /// through [UltratubeResolveCache] (prefetch).
  final ({int maxHeight, String audio}) Function()? profile;

  ({int maxHeight, String audio}) _profile() =>
      profile?.call() ?? (maxHeight: 1080, audio: 'normal');
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
  bool _isCurrentOnline(PlaybackStatus s) =>
      _original != null &&
      _original!.sourceType == PlaybackSourceType.online &&
      s.track?.id == _original!.id;

  /// While a recovery is pending the error is shown as buffering.
  PlaybackStatus _mask(PlaybackStatus s) =>
      _recovering && (s.state == PlaybackState.error || s.state == PlaybackState.idle)
      ? s.copyWith(state: PlaybackState.buffering, clearError: true)
      : s;

  void _onEngineStatus(PlaybackStatus s) {
    if (_disposed) return;
    // A failed stream URL must be re-extracted on retry, never reused.
    if (s.state == PlaybackState.error && s.track != null) {
      UltratubeResolveCache.forget(s.track!.id);
      // The quick app-client URL was refused (YouTube answers some with
      // 403): the retry must go through the full extraction instead of
      // asking the same client again.
      UltratubeCatalog.fastIds.remove(s.track!.id);
    }
    if (_isCurrentOnline(s)) {
      if (s.position > Duration.zero) _lastPosition = s.position;
      // Stable again: give the next hiccup a full set of attempts.
      final since = _recoveredAt;
      if (since != null &&
          s.state == PlaybackState.playing &&
          s.position > since + const Duration(seconds: 20)) {
        _recoveries = 0;
        _recoveredAt = null;
      }
      if (s.state == PlaybackState.error &&
          !_recovering &&
          _recoveries < _maxRecoveries &&
          !(s.error ?? '').contains('unsupported_format')) {
        _recovering = true;
        unawaited(_recover(_original!, s.error));
      }
    }
    _checkSkip(s);
    _statusOut.add(_mask(_restore(s)));
  }

  Future<void> _recover(PlaybackTrack track, String? reason) async {
    final generation = _generation;
    final attempt = ++_recoveries;
    final live = currentStatus.isLive || track.liveStatus == PlaybackLiveStatus.live;
    final resumeAt = live ? Duration.zero : _lastPosition;
    debugPrint('Ultratube: recovering ${track.id} ($reason), attempt $attempt at $resumeAt');
    try {
      // Give the radio a moment (unlock, Wi-Fi handover) before retrying.
      await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
      if (_disposed || generation != _generation) return;
      UltratubeResolveCache.forget(track.id);
      final wantsVideo = video();
      final media = await _resolveWithRetry(track.id, wantsVideo, generation);
      if (_disposed || generation != _generation) return;
      _recoveredAt = resumeAt;
      // Keep masking until the engine has taken over the new attempt; its
      // own errors from here on start the next recovery.
      await _engine.play(
        _resolved(track, media, wantsVideo),
        startAt: resumeAt,
        play: _playWhenReady,
      );
      if (generation == _generation) _recovering = false;
    } catch (error) {
      debugPrint('Ultratube: recovery of ${track.id} failed: $error');
      if (_disposed || generation != _generation) return;
      if (_recoveries < _maxRecoveries && isTransientResolveError(error)) {
        unawaited(_recover(track, '$error')); // still masked
        return;
      }
      _recovering = false;
      _recoveries = _maxRecoveries;
      _statusOut.add(
        _restore(
          _engine.currentStatus.copyWith(
            track: track,
            state: PlaybackState.error,
            error: isTransientResolveError(error)
                ? 'error:connection_lost'
                : 'error:unavailable',
          ),
        ),
      );
    }
  }

  /// Extraction with a short retry for transient failures. The native side
  /// already retries socket errors; this covers timeouts and the moments
  /// right after unlock when the network is not up yet.
  Future<Map<String, dynamic>> _resolveWithRetry(
    String id,
    bool wantsVideo,
    int generation,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        final p = _profile();
        return await resolve(
          id,
          video: wantsVideo,
          maxHeight: p.maxHeight,
          audio: p.audio,
        );
      } catch (error) {
        if (++attempt >= 3 ||
            !isTransientResolveError(error) ||
            _disposed ||
            generation != _generation) {
          rethrow;
        }
        debugPrint('Ultratube: resolve $id failed ($error), retry $attempt');
        await Future<void>.delayed(Duration(milliseconds: 1000 * attempt));
      }
    }
  }

  @override
  Stream<PlaybackStatus> get statusStream => _statusOut.stream;
  @override
  Stream<PlaybackEvent> get eventStream => _engine.eventStream;
  @override
  PlaybackStatus get currentStatus => _mask(_restore(_engine.currentStatus));

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
    _recoveries = 0;
    _recovering = false;
    _recoveredAt = null;
    _lastPosition = startAt;
    if (_disposed) throw StateError('Player encerrado');
    // Stop the old track while extraction is pending; never overlap selections.
    await _engine.stop();
    if (_disposed || generation != _generation) return;
    var resolved = track;
    if (track.sourceType == PlaybackSourceType.online) {
      unawaited(_loadSegments(track.id, generation));
      final wantsVideo = video();
      final p = _profile();
      final media = profile == null
          ? await _resolveWithRetry(track.id, wantsVideo, generation)
          : await UltratubeResolveCache.get(
              track.id,
              video: wantsVideo,
              maxHeight: p.maxHeight,
              audio: p.audio,
              resolve: () => _resolveWithRetry(track.id, wantsVideo, generation),
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
    _recovering = false;
    final wantsVideo = video();
    // Resolve first. A failed video request must not stop working audio.
    final media = await _resolveWithRetry(track.id, wantsVideo, generation);
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
    _recovering = false;
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
    await _engineSubscription.cancel();
    await _statusOut.close();
    await _engine.dispose();
  }
}
