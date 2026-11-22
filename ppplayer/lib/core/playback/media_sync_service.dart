import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audio_service/audio_service.dart';
import '../cache/image_cache_manager.dart';
import 'playback_providers.dart';
import 'package:pp_playback_engine/pp_playback_engine.dart' as engine;
import 'media_handler.dart';
import '../player/player_provider.dart';

/// A service that synchronizes the [PlaybackStatus] with the system media controls.
class MediaSyncService {
  MediaSyncService(this.ref) {
    _init();
  }

  final Ref ref;
  ProviderSubscription? _subscription;
  String? _lastTrackId;
  Duration? _lastDuration;
  String? _lastArtCacheFile;
  bool _isDisposed = false;

  void _init() {
    // Listen to playback status and update system media controls
    _subscription = ref.listen(playbackStatusProvider, (previous, next) {
      switch (next) {
        case AsyncData(:final value):
          _handleStatusUpdate(value);
        default:
          break;
      }
    }, fireImmediately: true);
    // The queue as the system sees it (watch "faixas em fila", car screens).
    _queueSubscription = ref.listen(
      playerProvider.select((s) => (s.playbackQueue.tracks, s.playbackQueue.currentIndex)),
      (previous, next) {
        if (_isDisposed) return;
        Timer.run(() {
          if (_isDisposed) return;
          ref.read(audioHandlerProvider).publishQueue(next.$1, next.$2);
        });
      },
      fireImmediately: true,
    );
  }

  ProviderSubscription? _queueSubscription;

  engine.PlaybackStatus? _lastStatus;
  DateTime _lastUpdateTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// What we last told the OS about "playing". Kept true through
  /// buffering/reloads (see [_osPlaying]).
  bool? _publishedPlaying;

  /// Whether playback was wanted the last time the engine settled
  /// (playing → true; paused/ended → false).
  bool _wantsPlay = false;

  /// When the current transitional stretch (buffering, reload, error
  /// recovery) began while playback was wanted.
  DateTime? _transitionSince;
  Timer? _graceTimer;

  /// How long a stall/reload may last before the OS hears "not playing".
  static const _transitionGrace = Duration(seconds: 45);

  /// Android only keeps the media foreground service while audio_service
  /// is told `playing=true` (androidStopForegroundOnPause). If a live
  /// stream buffers — or the engine reloads after a network hiccup — while
  /// the app is in the background or PiP, publishing `playing=false` drops
  /// the service, and Android 12+ forbids starting it again from the
  /// background (ForegroundServiceStartNotAllowedException). Without it the
  /// process loses network access and the stream dies with "Falha ao
  /// reproduzir". So transitional states keep reporting "playing" (with a
  /// buffering/loading processing state) while playback is still wanted.
  bool _osPlaying(engine.PlaybackState state) {
    switch (state) {
      case engine.PlaybackState.playing:
        _wantsPlay = true;
        _transitionSince = null;
        return true;
      case engine.PlaybackState.paused:
      case engine.PlaybackState.ended:
        _wantsPlay = false;
        _transitionSince = null;
        return false;
      case engine.PlaybackState.ready:
        // Loaded but not started: keep whatever we were doing.
        return _wantsPlay;
      case engine.PlaybackState.idle:
      case engine.PlaybackState.preparing:
      case engine.PlaybackState.buffering:
      case engine.PlaybackState.error:
        if (!_wantsPlay) return false;
        final since = _transitionSince ??= DateTime.now();
        if (DateTime.now().difference(since) >= _transitionGrace) {
          _wantsPlay = false;
          _transitionSince = null;
          return false;
        }
        return true;
    }
  }

  void _handleStatusUpdate(engine.PlaybackStatus currentStatus) {
    final handler = ref.read(audioHandlerProvider);
    final track = currentStatus.track;

    final trackChanged = track != null && track.id != _lastTrackId;
    final durationChanged =
        track != null && currentStatus.duration != _lastDuration;
    final liveChanged = _lastStatus != null && _lastStatus!.isLive != currentStatus.isLive;

    if (trackChanged) {
      _lastArtCacheFile = null;
    }

    if (trackChanged || durationChanged) {
      _lastTrackId = track.id;
      _lastDuration = currentStatus.duration;

      _pushMetadata(track, currentStatus.duration);

      if (trackChanged) {
        final artUrl = track.artworkUrl;
        if (artUrl != null && artUrl.isNotEmpty) {
          _resolveArtwork(track.id, artUrl);
        }
      }
    }

    // 2. Throttle playback state updates to avoid unnecessary COM message loop pumping
    final now = DateTime.now();
    final stateChanged = _lastStatus?.state != currentStatus.state;
    final osPlaying = _osPlaying(currentStatus.state);
    final playingChanged = _publishedPlaying != osPlaying;

    // Calculate expected position to detect seeks
    final expectedPosition = _lastStatus != null && _publishedPlaying == true
        ? _lastStatus!.position + now.difference(_lastUpdateTime)
        : _lastStatus?.position ?? Duration.zero;

    // Only update OS if state/playing changed OR if position jumped significantly (seek)
    final positionJumped =
        (currentStatus.position - expectedPosition).inMilliseconds.abs() > 2000;

    _scheduleGraceCheck();

    if (stateChanged || playingChanged || positionJumped || liveChanged) {
      _lastUpdateTime = now;
      _lastStatus = currentStatus;
      _publishedPlaying = osPlaying;

      // Run asynchronously to avoid Win32 COM message loop pumping during Flutter's internal phases
      Timer.run(() {
        if (_isDisposed) return;
        handler.updatePlaybackState(
          playing: osPlaying,
          position: currentStatus.position,
          bufferedPosition: currentStatus.buffered,
          isIFrameMode: currentStatus.isIFrameMode,
          speed: currentStatus.speed,
          processingState: _mapToAudioProcessingState(currentStatus.state),
          live: currentStatus.isLive,
        );
      });
    }
  }

  /// A play request from outside the app (watch, headset, notification),
  /// possibly with the phone locked and the process just woken up. Android
  /// only keeps the media foreground service — and with it network access
  /// in the background — while the session says "playing". Saying so right
  /// away (as "loading") lets the stream be resolved and fetched; before,
  /// the app stayed without network ("Unable to resolve host") and the
  /// request never started. The grace period still ends it if nothing plays.
  void playRequested() {
    if (_isDisposed) return;
    _wantsPlay = true;
    _transitionSince ??= DateTime.now();
    _publishedPlaying = true;
    final last = _lastStatus;
    ref.read(audioHandlerProvider).updatePlaybackState(
      playing: true,
      position: last?.position ?? Duration.zero,
      bufferedPosition: last?.buffered ?? Duration.zero,
      processingState: AudioProcessingState.loading,
      live: last?.isLive ?? false,
    );
    _scheduleGraceCheck();
  }

  /// A stall that never recovers must still end as "not playing" (so the
  /// notification can be dismissed), even if the engine emits nothing more.
  void _scheduleGraceCheck() {
    _graceTimer?.cancel();
    final since = _transitionSince;
    if (since == null) return;
    final left = _transitionGrace - DateTime.now().difference(since);
    _graceTimer = Timer(left.isNegative ? Duration.zero : left, () {
      if (_isDisposed) return;
      final last = _lastStatus;
      if (last != null) _handleStatusUpdate(last.copyWith());
    });
  }

  AudioProcessingState _mapToAudioProcessingState(engine.PlaybackState state) {
    switch (state) {
      case engine.PlaybackState.idle:
        return AudioProcessingState.idle;
      case engine.PlaybackState.preparing:
        return AudioProcessingState.loading;
      case engine.PlaybackState.buffering:
        return AudioProcessingState.buffering;
      case engine.PlaybackState.ready:
      case engine.PlaybackState.playing:
      case engine.PlaybackState.paused:
        return AudioProcessingState.ready;
      case engine.PlaybackState.ended:
        return AudioProcessingState.completed;
      case engine.PlaybackState.error:
        return AudioProcessingState.error;
    }
  }

  void _pushMetadata(engine.PlaybackTrack track, Duration duration) {
    final handler = ref.read(audioHandlerProvider);
    Timer.run(() {
      if (_isDisposed) return;
      handler.updateMetadata(
        id: track.id,
        title: track.title,
        artist: track.artist ?? '',
        artUri: track.artworkUrl,
        artCacheFile: _lastArtCacheFile,
        // No length (live, or not known yet): no bar on the lock screen or
        // the watch instead of one stuck at 0:00.
        duration: duration > Duration.zero ? duration : null,
      );
    });
  }

  Future<void> _resolveArtwork(String trackId, String artworkUrl) async {
    try {
      if (artworkUrl.startsWith('/') || artworkUrl.startsWith('file://')) {
        if (_lastTrackId == trackId && !_isDisposed) {
          _lastArtCacheFile = artworkUrl.startsWith('file://')
              ? artworkUrl.substring(7)
              : artworkUrl;
          if (_lastStatus?.track != null) {
            _pushMetadata(_lastStatus!.track!, _lastDuration ?? Duration.zero);
          }
        }
        return;
      }

      if (!artworkUrl.startsWith('http')) {
        return;
      }

      // 1. Check if already cached locally
      final fileInfo = await PPImageCacheManager.instance.getFileFromCache(
        artworkUrl,
      );
      if (fileInfo != null) {
        if (_lastTrackId == trackId && !_isDisposed) {
          _lastArtCacheFile = fileInfo.file.path;
          if (_lastStatus?.track != null) {
            _pushMetadata(_lastStatus!.track!, _lastDuration ?? Duration.zero);
          }
        }
        return;
      }

      // 2. If not yet cached, fetch and save to cache
      final file = await PPImageCacheManager.instance.getSingleFile(artworkUrl);

      if (file.existsSync() && _lastTrackId == trackId && !_isDisposed) {
        _lastArtCacheFile = file.path;
        if (_lastStatus?.track != null) {
          _pushMetadata(_lastStatus!.track!, _lastDuration ?? Duration.zero);
        }
      }
    } catch (_) {
      // Graceful fallback: text metadata and artUri are already active
    }
  }

  void dispose() {
    _isDisposed = true;
    _graceTimer?.cancel();
    _subscription?.close();
    _queueSubscription?.close();
  }
}

/// Provider for [MediaSyncService].
final mediaSyncServiceProvider = Provider<MediaSyncService>((ref) {
  final service = MediaSyncService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});
