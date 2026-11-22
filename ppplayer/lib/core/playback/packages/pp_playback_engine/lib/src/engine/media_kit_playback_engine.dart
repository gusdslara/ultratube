import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:media_kit_video/media_kit_video.dart';

import '../models/playback_status.dart';
import '../models/playback_event.dart';
import '../models/playback_track.dart';
import 'playback_controller.dart';
import 'background_playback_experiment.dart';

/// Returns an ISO-8601-like timestamp for diagnostic log lines.
String _ts() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}.'
      '${now.millisecond.toString().padLeft(3, '0')}';
}

/// Tagged diagnostic print — always present regardless of experiment flag.
void _diag(String msg) =>
    debugPrint('${_ts()} ${BackgroundPlaybackExperiment.tag} $msg');

// ---------------------------------------------------------------------------
// INativePlayerAdapter — injectable for production and tests
// ---------------------------------------------------------------------------

/// Abstraction over a single native media_kit player instance.
///
/// The production implementation ([MediaKitPlayerAdapter]) wraps the real
/// [Player]. Tests inject a fake that exposes the same event streams so the
/// engine's lifecycle logic can be exercised without a real media_kit player.
abstract class INativePlayerAdapter {
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<String> get errorStream;
  Stream<bool> get completedStream;
  Stream<VideoParams> get videoParamsStream;

  /// The [VideoController] associated with this player, or null for adapters
  /// that do not render video (e.g. audio-only test fakes).
  VideoController? get videoController;

  /// [video]: false for audio-only network media (no video track is
  /// decoded or read, and the read-ahead cache is sized for audio).
  Future<void> open(
    String uri, {
    bool play = false,
    Map<String, String>? httpHeaders,
    String? audioUri,
    bool video = true,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume100);
  Future<void> setRate(double rate);
  Future<void> setSubtitleTrack(SubtitleTrack track);
  Future<void> setSubtitleDelay(Duration delay);
  Future<void> setSubtitleAppearance({double? textSize, int? backgroundColor});

  bool get supportsTrackSelection;
  bool get supportsExternalSubtitles;
  bool get supportsSubtitleDelay;
  bool get supportsSubtitleTextSize;
  bool get supportsSubtitleBackgroundStyling;

  /// Dispose this adapter and its underlying player. Must be idempotent.
  Future<void> dispose();
}

/// Production adapter wrapping a real [media_kit] [Player].
class MediaKitPlayerAdapter implements INativePlayerAdapter {
  static Player? _sharedPlayer;
  static VideoController? _sharedVideoController;

  MediaKitPlayerAdapter() {
    // mpv's debug log is hundreds of lines per second while a video plays;
    // formatting and printing each one keeps a CPU core busy for nothing.
    // Release builds only hear about warnings and errors.
    _sharedPlayer ??= Player(
      configuration: const PlayerConfiguration(
        logLevel: kDebugMode ? MPVLogLevel.debug : MPVLogLevel.warn,
      ),
    );
    _sharedVideoController ??= VideoController(
      _sharedPlayer!,
      configuration: _directSurface
          ? const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec')
          : const VideoControllerConfiguration(),
    );
    _player = _sharedPlayer!;
    _videoController = _sharedVideoController!;
    _logSubscription = _player.stream.log.listen(
      (event) =>
          debugPrint('MPV_LOG: ${event.level} - ${event.prefix}: ${event.text}'),
    );
    try {
      // Enable ffmpeg HTTPS reconnects to prevent EOF/partial file when seeking
      (_player.platform as dynamic).setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,reconnect_on_network_error=1,reconnect_on_http_error=5xx',
      );
      // Read-ahead; resized per item in open() (audio vs video).
      (_player.platform as dynamic).setProperty('cache-secs', '100');
      (_player.platform as dynamic).setProperty(
        'demuxer-max-bytes',
        '64000000',
      );
      (_player.platform as dynamic).setProperty(
        'demuxer-max-back-bytes',
        '16000000',
      );
    } catch (e) {
      debugPrint('MediaKitPlaybackEngine: Failed to set mpv properties: $e');
    }
  }

  /// Android: let the hardware decoder draw straight onto the video surface.
  /// media_kit's default (`vo=gpu`) cannot hand the decoder a surface, so mpv
  /// falls back to `mediacodec-copy`: every decoded frame is copied to main
  /// memory and uploaded to the GPU again, which on a 1080p60 Short keeps
  /// most of a CPU core busy and is what heats the phone.
  static bool get _directSurface => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool _renderPathReported = false;

  /// One line per app run with how mpv decodes and draws (hardware decoder,
  /// scalers, frame timing): what decides the phone's CPU/GPU load.
  void _reportRenderPath() {
    if (_renderPathReported || kIsWeb) return;
    _renderPathReported = true;
    Future<void>.delayed(const Duration(seconds: 6), () async {
      try {
        final mpv = _player.platform as dynamic;
        final values = <String>[];
        for (final name in const [
          'mpv-version', 'hwdec', 'hwdec-current', 'current-vo', 'gpu-api', 'video-codec',
          'video-params/pixelformat', 'video-params/w', 'video-params/h', 'container-fps',
          'display-fps', 'video-sync', 'scale', 'dscale', 'cscale', 'dither-depth', 'deband',
          'interpolation', 'frame-drop-count', 'vo-delayed-frame-count',
        ]) {
          String value;
          try {
            value = await mpv.getProperty(name) as String;
          } catch (_) {
            value = '?';
          }
          values.add('$name=$value');
        }
        debugPrint('MediaKitPlaybackEngine: render path: ${values.join(' ')}');
      } catch (error) {
        debugPrint('MediaKitPlaybackEngine: render path unavailable: $error');
      }
    });
  }

  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<PlayerLog>? _logSubscription;
  bool _disposed = false;

  @override
  VideoController? get videoController => _videoController;

  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;
  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<Duration> get bufferStream => _player.stream.buffer;
  @override
  Stream<String> get errorStream => _player.stream.error;
  @override
  Stream<bool> get completedStream => _player.stream.completed;
  @override
  Stream<VideoParams> get videoParamsStream => _player.stream.videoParams;

  Media? _currentMedia;
  Future<void>? _cacheReady;

  Future<void> _configureCacheDirectory() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      // Android has no desktop home/cache directory for mpv's disk-cache default.
      final directory = await Directory(
        '${Directory.systemTemp.path}/ppplayer-mpv-cache',
      ).create(recursive: true);
      await (_player.platform as dynamic).setProperty(
        'demuxer-cache-dir',
        directory.path,
      );
    } on FileSystemException catch (error) {
      // An unavailable temporary directory must not prevent memory-cached playback.
      await (_player.platform as dynamic).setProperty('cache-on-disk', 'no');
      debugPrint('MediaKitPlaybackEngine: Disk cache unavailable: $error');
    }
  }

  /// The current item is a network video whose picture may be dropped
  /// while the app is in the background (see [suspendVideo]).
  static bool _networkVideo = false;
  static bool _videoSuspended = false;

  /// Nothing of the app on screen: stopped activity, or the engine was
  /// started by the media service with no activity at all. (A floating
  /// window keeps the activity resumed/inactive, so PiP is not "no screen".)
  static bool _noScreen() {
    if (MediaKitPlaybackEngine.isActivityStopped) return true;
    if (kIsWeb || !Platform.isAndroid) return false;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null ||
        lifecycle == AppLifecycleState.detached ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused;
  }

  /// Background without a floating window: nobody sees the picture, so mpv
  /// stops decoding the video track — and, with no track selected on the
  /// video-only stream, stops downloading it. Audio keeps playing; the
  /// picture comes back (from the current position) when [suspend] is false.
  static Future<void> suspendVideo(bool suspend) async {
    final player = _sharedPlayer;
    if (kIsWeb || player == null || _videoSuspended == suspend) return;
    if (suspend && !_networkVideo) return;
    _videoSuspended = suspend;
    try {
      await (player.platform as dynamic).setProperty('vid', suspend ? 'no' : 'auto');
    } catch (e) {
      debugPrint('MediaKitPlaybackEngine: vid toggle failed: $e');
    }
  }

  @override
  Future<void> open(
    String uri, {
    bool play = false,
    Map<String, String>? httpHeaders,
    String? audioUri,
    bool video = true,
  }) async {
    await (_cacheReady ??= _configureCacheDirectory());
    if (!kIsWeb) {
      // Separate audio track (YouTube serves >360p as video-only + audio).
      // change-list/append takes the URL verbatim; property strings would be
      // split on ':' as a path list. The list persists, so always clear it.
      final mpv = _player.platform as dynamic;
      await mpv.command(['change-list', 'audio-files', 'clr', '']);
      if (audioUri != null && audioUri.isNotEmpty) {
        await mpv.command(['change-list', 'audio-files', 'append', audioUri]);
      }
    }
    final scheme =
        kIsWeb ? '' : (Uri.tryParse(uri)?.scheme.toLowerCase() ?? '');
    final local =
        !kIsWeb &&
        (scheme.isEmpty ||
            const {'asset', 'file', 'content'}.contains(scheme) ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(uri));
    if (!kIsWeb) {
      // Local files need precise seeks even when the target is between keyframes.
      // Keep keyframe seeking for network streams to avoid expensive HLS decoding.
      await (_player.platform as dynamic).setProperty(
        'hr-seek',
        local ? 'yes' : 'no',
      );
      // HLS segments often come without a length (chunked; Twitch's CDN
      // also advertises Accept-Ranges). The ffmpeg in libmpv treats such a
      // segment's normal end as a premature EOF whenever `reconnect` is on:
      // it logs "Will reconnect at <size> … End of file", backs off 0/1/3 s
      // and gets 416 for the Range request, so a live with 2 s segments
      // stalls every few seconds. The HLS demuxer already retries segments
      // and playlists by itself, so plain HTTP reconnects stay off here;
      // reconnect_on_network_error still covers failed connects.
      final hls = uri.contains('.m3u8') ||
          uri.contains('/api/manifest/hls_') ||
          uri.startsWith('http://127.0.0.1:');
      await (_player.platform as dynamic).setProperty(
        'stream-lavf-o',
        hls
            ? 'reconnect=0,reconnect_on_network_error=1,reconnect_delay_max=2'
            : 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,reconnect_on_network_error=1,reconnect_on_http_error=5xx',
      );
      // Audio-only network media: no video track at all (a stray cover-art
      // or video stream is neither read nor decoded) and a cache sized for
      // ~128 kbps — two minutes of read-ahead is about 2 MB. Video keeps a
      // minute ahead: enough to ride out a weak signal without downloading
      // (and paying for) minutes that a skip throws away.
      final audioOnly = !local && !video;
      _networkVideo = !local && video;
      // Opened with nothing on screen (locked phone, app in the
      // background without PiP — e.g. "next" from a watch): no surface to
      // draw on, and asking mpv for a picture there made the open hang
      // until its timeout. Start without it; it returns with the screen.
      if (_networkVideo && _noScreen()) _videoSuspended = true;
      final mpv = _player.platform as dynamic;
      await mpv.setProperty('vid', audioOnly || (_videoSuspended && _networkVideo) ? 'no' : 'auto');
      if (!_networkVideo) _videoSuspended = false;
      if (!local) {
        await mpv.setProperty('cache-secs', audioOnly ? '120' : '60');
        await mpv.setProperty('demuxer-max-bytes', audioOnly ? '16000000' : '64000000');
        await mpv.setProperty('demuxer-max-back-bytes', audioOnly ? '8000000' : '16000000');
      } else {
        await mpv.setProperty('cache-secs', '100');
      }
    }
    // Bug fix: do NOT inject HTTP headers for local-scheme URIs (file://, content://,
    // asset://). libmpv ignores them for local sources, but on Android passing a header
    // map with a content:// URI can trigger an HTTP-resource code path and cause
    // access-denied failures.
    Map<String, String> headers;
    if (local) {
      headers = httpHeaders ?? const {};
    } else {
      headers = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
            ' (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': '*/*',
      };
      if (httpHeaders != null) {
        headers.addAll(httpHeaders);
      }
    }
    _currentMedia = Media(uri, httpHeaders: headers.isEmpty ? null : headers);
    _reportRenderPath();
    return _player.open(_currentMedia!, play: play);
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setVolume(double volume100) => _player.setVolume(volume100);
  @override
  Future<void> setRate(double rate) => _player.setRate(rate);
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _player.setSubtitleTrack(track);

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    if (_player.platform != null) {
      try {
        await (_player.platform as dynamic).setProperty(
          'sub-delay',
          (delay.inMilliseconds / 1000.0).toString(),
        );
      } catch (e) {
        debugPrint('Failed to set subtitle delay: $e');
      }
    }
  }

  @override
  Future<void> setSubtitleAppearance({
    double? textSize,
    int? backgroundColor,
  }) async {
    if (_player.platform != null) {
      try {
        if (textSize != null) {
          await (_player.platform as dynamic).setProperty(
            'sub-font-size',
            textSize.toString(),
          );
        }
        if (backgroundColor != null) {
          final hexColor =
              '#${backgroundColor.toRadixString(16).padLeft(8, '0')}';
          await (_player.platform as dynamic).setProperty(
            'sub-back-color',
            hexColor,
          );
        }
      } catch (e) {
        debugPrint('Failed to set subtitle appearance: $e');
      }
    }
  }

  @override
  bool get supportsTrackSelection => true;
  @override
  bool get supportsExternalSubtitles => true;
  @override
  bool get supportsSubtitleDelay => true;
  @override
  bool get supportsSubtitleTextSize => true;
  @override
  bool get supportsSubtitleBackgroundStyling => true;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _logSubscription?.cancel();
    _logSubscription = null;
    // We do NOT dispose the shared player to avoid native FFI crashes.
  }
}

// ---------------------------------------------------------------------------
// NativePlaybackSession — one per play/prepare attempt
// ---------------------------------------------------------------------------

/// Owns one native player instance and all its event subscriptions.
///
/// Event callbacks capture this object directly. When the engine replaces
/// [_activeSession] the old session reference no longer matches, so any
/// late-arriving event from the old player is trivially discarded without
/// inspecting URIs, extras, or readiness flags.
class NativePlaybackSession {
  NativePlaybackSession({
    required this.generation,
    required this.adapter,
    Duration startPosition = Duration.zero,
  }) : progressBaseline = startPosition;

  final int generation;
  final INativePlayerAdapter adapter;
  Duration progressBaseline;
  bool hasPlaybackProgress = false;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  bool _torn = false;

  /// Pending check for a non-fatal mpv error line (see `_softError`).
  Timer? softErrorTimer;

  VideoController? get videoController => adapter.videoController;

  /// Cancel subscriptions and dispose the adapter exactly once (idempotent).
  Future<void> tear() async {
    if (_torn) return;
    _torn = true;
    softErrorTimer?.cancel();
    for (final sub in subscriptions) {
      sub.cancel();
    }
    subscriptions.clear();
    await adapter.dispose();
  }
}

// ---------------------------------------------------------------------------
// MediaKitPlaybackEngine
// ---------------------------------------------------------------------------

class MediaKitPlaybackEngine implements PlaybackController {
  /// Factory for native player adapters.
  ///
  /// Defaults to creating a [MediaKitPlayerAdapter] (production).
  /// Inject a controlled fake in tests to exercise the production engine's
  /// lifecycle logic without a real media_kit player.
  final INativePlayerAdapter Function()? nativeAdapterFactory;

  MediaKitPlaybackEngine({this.nativeAdapterFactory}) {
    _initMediaKit();
  }

  void _initMediaKit() {
    try {
      MediaKit.ensureInitialized();
    } catch (e) {
      debugPrint(
        'MediaKitPlaybackEngine: MediaKit.ensureInitialized skipped (test env?): $e',
      );
    }
  }

  /// Informs the engine that the host activity is stopped (e.g. screen locked).
  /// Used to block IFrame playback dispatches when the WebView is frozen.
  static bool isActivityStopped = false;

  // ── Native session ─────────────────────────────────────────────────────────
  NativePlaybackSession? _activeSession;

  // ── Engine counters ────────────────────────────────────────────────────────
  int _playGeneration = 0;
  int _lastPlayedGeneration = 0;
  int _intentRevision = 0;
  bool _disposed = false;
  bool _attemptActive = false;
  Future<void>? _invalidationFuture;
  bool _recoveryUsed = false;
  bool _ready = false;
  int? _latePauseGeneration;
  int? _pauseIntentGeneration;
  bool _valid(int generation) =>
      !_disposed && _attemptActive && generation == _playGeneration;

  double? _currentStartSeconds;
  Duration? _confirmedPlaybackPosition;
  int _confirmedPositionGeneration = -1;

  Timer? _watchdogTimer;
  final _statusController = StreamController<PlaybackStatus>.broadcast();
  final _eventController = StreamController<PlaybackEvent>.broadcast();

  PlaybackStatus _currentStatus = const PlaybackStatus(supportsSpeed: true);
  PlaybackState? _intendedState;

  // ---------------------------------------------------------------------------
  // Session management
  // ---------------------------------------------------------------------------

  INativePlayerAdapter _makeAdapter() =>
      nativeAdapterFactory != null
          ? nativeAdapterFactory!()
          : MediaKitPlayerAdapter();

  /// Immediately detach [_activeSession] (so its callbacks are rejected), then
  /// stop + dispose it asynchronously. Must be called *before* any await so
  /// a superseded open() cannot race with cleanup.
  Future<void> _invalidateActiveSession() async {
    final old = _activeSession;
    _activeSession =
        null; // detach synchronously — callbacks rejected immediately

    if (old == null) {
      await _invalidationFuture;
      return;
    }

    Future<void> doInvalidate() async {
      try {
        await old.adapter.stop().timeout(const Duration(seconds: 1));
      } catch (_) {}
      await old.tear();
    }

    final previous = _invalidationFuture;
    final current =
        (previous == null)
            ? doInvalidate()
            : previous.whenComplete(doInvalidate);

    _invalidationFuture = current;
    // The production adapters share one native player. Finish each queued
    // teardown once before opening a replacement on that player.
    await current;
  }

  /// Bind session-owned adapter streams to engine update handlers.
  ///
  /// Each closure captures [session] by reference. If [session] is no longer
  /// [_activeSession] when the event fires the update is dropped with a single
  /// identity check — no URI comparison, no extras, no readiness flag.
  static const _positionInterval = Duration(milliseconds: 200);
  DateTime _lastPositionEmit = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastEmittedPosition = Duration.zero;

  void _bindSession(NativePlaybackSession session) {
    final a = session.adapter;
    session.subscriptions.addAll([
      a.positionStream.listen((pos) {
        if (session != _activeSession || _disposed) return;
        // A playing acknowledgement can precede a failed native output.
        // Only position beyond the requested seek point proves playback started.
        if (_intendedState == PlaybackState.playing &&
            pos > session.progressBaseline) {
          session.hasPlaybackProgress = true;
          _watchdogTimer?.cancel();
        }
        final next = _currentStatus.copyWith(
          position: pos,
          isLive: _currentStatus.track?.liveStatus == PlaybackLiveStatus.live,
        );
        // mpv reports the position on every frame (up to 60 times a second
        // with video); each report rebuilt the player state and everything
        // listening to it. ~5 a second is plenty for any timeline; a seek
        // or the first report after a (re)start still goes out at once.
        // Skipped reports still land in _currentStatus, so the next status
        // (pause, end, …) carries the exact position.
        final now = DateTime.now();
        final jumped = (pos - _lastEmittedPosition).abs() >= const Duration(seconds: 1);
        if (jumped || now.difference(_lastPositionEmit) >= _positionInterval) {
          _lastPositionEmit = now;
          _lastEmittedPosition = pos;
          _updateStatus(next);
        } else {
          _currentStatus = next.copyWith(generation: _playGeneration);
        }
      }),
      a.durationStream.listen((dur) {
        if (session != _activeSession || _disposed) return;
        final track = _currentStatus.track;
        bool isSeekable =
            dur > Duration.zero ||
            (track?.duration != null && track!.duration! > Duration.zero);
        // Conservatively disable seeking for explicitly live streams.
        if (track?.liveStatus == PlaybackLiveStatus.live) {
          isSeekable = false;
        }
        _updateStatus(
          _currentStatus.copyWith(
            duration: dur,
            isSeekable: isSeekable,
            isLive: track?.liveStatus == PlaybackLiveStatus.live,
          ),
        );
      }),
      a.bufferStream.listen((buf) {
        if (session != _activeSession || _disposed) return;
        _updateStatus(_currentStatus.copyWith(buffered: buf));
      }),
      a.playingStream.listen((playing) {
        if (session != _activeSession || _disposed) return;
        // Don't overwrite preparing — wait for buffering/playing stream events.
        if (_currentStatus.state == PlaybackState.preparing) return;
        _updateStatus(
          _currentStatus.copyWith(
            state: playing ? PlaybackState.playing : PlaybackState.paused,
          ),
        );
      }),
      a.errorStream.listen((err) {
        print('MediaKitPlaybackEngine: [ERROR] $err');
        if (session != _activeSession || _disposed) return;
        final errStr = err.toLowerCase();
        // A rejected seek (live/non-seekable stream; media_kit also seeks to
        // refresh the picture when the surface is re-created) leaves the
        // media playing. It is never a playback failure.
        if (errStr.contains('cannot seek') || errStr.contains('force-seekable')) return;
        // media_kit reports every mpv error-level log line here (prefixes
        // tcp/vd/ad/cplayer/stream), most of which mpv survives on its own:
        // a dropped socket after the screen was locked ("tcp: ffurl_read
        // returned …", then ffmpeg reconnects), one address of a dual-stack
        // host refusing, the hardware decoder failing before the video
        // surface exists and mpv falling back to software. Only a clear
        // HTTP/open failure ends the attempt at once; anything else fails it
        // only if playback then stops making progress.
        final hard = RegExp(r'\b(403|404|410)\b|forbidden|not found|failed to open|failed to recognize').hasMatch(errStr);
        if (!hard) {
          _softError(session, err);
          return;
        }
        String errorCode = 'error:playback_failed';
        if (errStr.contains('403') || errStr.contains('forbidden')) {
          errorCode = 'error:forbidden';
        } else if (errStr.contains('404') || errStr.contains('not found')) {
          errorCode = 'error:not_found';
        } else if (errStr.contains('timeout') ||
            errStr.contains('unreachable') ||
            errStr.contains('connection refused') ||
            errStr.contains('no route')) {
          errorCode = 'error:playback_timeout';
        } else if (errStr.contains('format') ||
            errStr.contains('codec') ||
            errStr.contains('corrupt')) {
          errorCode = 'error:unsupported_format';
        } else if (errStr.contains('access') || errStr.contains('permission')) {
          errorCode = 'error:file_inaccessible';
        }
        _watchdogTimer?.cancel();
        _updateStatus(
          _currentStatus.copyWith(state: PlaybackState.error, error: errorCode),
        );
      }),
      a.completedStream.listen((completed) {
        if (!completed) return;
        if (session != _activeSession || _disposed) return;
        _watchdogTimer?.cancel();
        // When ffmpeg gives up on a dropped connection mpv reports EOF at the
        // point the download stopped. A network VOD "ending" well before its
        // length is a failure the owner can resume, not the end of the track.
        final track = _currentStatus.track;
        final length = _currentStatus.duration > Duration.zero
            ? _currentStatus.duration
            : (track?.duration ?? Duration.zero);
        if (track != null &&
            !track.isLocal &&
            track.liveStatus != PlaybackLiveStatus.live &&
            length > Duration.zero &&
            _currentStatus.position < length - const Duration(seconds: 5)) {
          print('MediaKitPlaybackEngine: early EOF at ${_currentStatus.position} of $length');
          _updateStatus(
            _currentStatus.copyWith(state: PlaybackState.error, error: 'error:connection_lost'),
          );
          return;
        }
        _updateStatus(_currentStatus.copyWith(state: PlaybackState.ended));
      }),
      a.bufferingStream.listen((buffering) {
        if (session != _activeSession || _disposed) return;
        // Don't regress from a valid non-preparing state to "not-buffering"
        // unless we're already in buffering/playing.
        if (_currentStatus.state == PlaybackState.preparing && !buffering) {
          return;
        }
        // A socket that died silently (screen locked, Wi-Fi handover) shows
        // up only as endless buffering; give the network time, then fail so
        // the owner can re-open the stream where it stopped.
        if (buffering) _softError(session, 'buffering', wait: const Duration(seconds: 25));
        _updateStatus(
          _currentStatus.copyWith(
            state:
                buffering
                    ? PlaybackState.buffering
                    : (_intendedState ?? PlaybackState.paused),
          ),
        );
      }),
      a.videoParamsStream.listen((params) {
        if (session != _activeSession || _disposed) return;
        final w = params.w ?? 0;
        final h = params.h ?? 0;
        final hasDimensions = w > 0 && h > 0;

        // If the track is statically known to be a video, don't let a transient 0x0
        // size param hide the view, which breaks native macOS texture binding.
        // Local audio with embedded cover art reports video dimensions too, so a
        // local track only shows video when it was classified isVideo at import.
        final hasVideo =
            (_currentStatus.track?.isVideo == true) ||
            (_currentStatus.track?.isLocal != true && hasDimensions);

        _updateStatus(
          _currentStatus.copyWith(
            hasVideo: hasVideo,
            activeVideoId: hasVideo ? _currentStatus.track?.id : null,
            videoAspectRatio: hasDimensions ? w / h : null,
          ),
        );
      }),
    ]);
  }

  // ---------------------------------------------------------------------------
  // PlaybackController interface
  // ---------------------------------------------------------------------------

  @override
  Stream<PlaybackStatus> get statusStream => _statusController.stream;

  @override
  Stream<PlaybackEvent> get eventStream => _eventController.stream;

  @override
  PlaybackStatus get currentStatus => _currentStatus;

  /// Returns the [VideoController] for the currently active native session,
  /// or null when no native session is active (idle, IFrame mode, or disposed).
  @override
  dynamic get renderer => _activeSession?.videoController;
  // ---------------------------------------------------------------------------
  // prepare()
  // ---------------------------------------------------------------------------

  @override
  Future<void> prepare(PlaybackTrack track, {Duration? position}) async {
    if (_disposed) return;

    if (track.isLocal || track.sourceType == PlaybackSourceType.networkStream) {
      final uri = track.isLocal ? track.localMediaUri : track.networkMediaUri;
      if (uri == null) {
        _updateStatus(
          _currentStatus.copyWith(
            track: track,
            state: PlaybackState.error,
            error: 'Media URI is missing for ${track.id}',
          ),
        );
        return;
      }

      // ── Invalidate immediately BEFORE any await ───────────────────────────
      _intentRevision++;
      _intendedState = PlaybackState.paused;
      _playGeneration++;
      final myGen = _playGeneration;

      await _invalidateActiveSession();
      if (_disposed || _playGeneration != myGen) return;

      // ── Create and activate the new session ───────────────────────────────
      final session = NativePlaybackSession(
        generation: myGen,
        adapter: _makeAdapter(),
      );
      // Assign _activeSession first so its callbacks are accepted and the
      // renderer getter immediately returns the new VideoController.
      _activeSession = session;
      _attemptActive = true;
      _recoveryUsed = false;
      _ready = false;
      _latePauseGeneration = null;

      // Bind callbacks BEFORE opening so initialization events during open()
      // are accepted.
      _bindSession(session);

      // Arm watchdog to prevent hanging on inaccessible files or broken streams
      _watchdogTimer?.cancel();
      _watchdogTimer = Timer(Duration(seconds: track.isLocal ? 5 : 20), () {
        if (_disposed || _activeSession != session) return;
        if (_currentStatus.state == PlaybackState.preparing ||
            _currentStatus.state == PlaybackState.buffering) {
          _failAttempt(
            myGen,
            track.isLocal
                ? 'error:file_inaccessible'
                : 'error:playback_timeout',
          );
        }
      });

      // Publish the new renderer and status BEFORE opening media.
      _updateStatus(
        _currentStatus.copyWith(
          track: track,
          state: PlaybackState.preparing,
          clearError: true,
          activeVideoId: track.isVideo ? track.id : null,
          hasVideo: track.isVideo,
          isIFrameMode: false,
          generation: myGen,
          isLive: track.liveStatus == PlaybackLiveStatus.live,
          isSeekable: false,
          position: Duration.zero,
          duration: Duration.zero,
          buffered: Duration.zero,
        ),
      );

      try {
        // Non-autoplay: open without starting playback.
        await session.adapter
            .open(
              uri,
              play: false,
              httpHeaders: track.httpHeaders,
              audioUri: track.externalAudioUri,
              video: track.isVideo,
            )
            .timeout(const Duration(seconds: 10));
        if (_disposed || _activeSession != session) return;

        // Apply settings AFTER open() to avoid hanging media_kit on Android.
        await session.adapter.setVolume(_currentStatus.volume * 100);
        if (_disposed || _activeSession != session) return;
        await session.adapter.setRate(_currentStatus.speed);
        if (_disposed || _activeSession != session) return;

        if (position != null && track.liveStatus != PlaybackLiveStatus.live) {
          await session.adapter.seek(position);
          if (_disposed || _activeSession != session) return;
        }

        // Do not overwrite a terminal state (error/ended) that may have arrived
        // from a stream event during open().
        if (_currentStatus.state == PlaybackState.preparing) {
          _updateStatus(_currentStatus.copyWith(state: PlaybackState.paused));
        }
      } catch (e) {
        if (_disposed || _activeSession != session) return;
        final errStr = e.toString().toLowerCase();
        String errorCode = 'error:playback_failed';
        if (errStr.contains('403') || errStr.contains('forbidden')) {
          errorCode = 'error:forbidden';
        } else if (errStr.contains('404') || errStr.contains('not found')) {
          errorCode = 'error:not_found';
        } else if (errStr.contains('timeout') ||
            errStr.contains('unreachable') ||
            errStr.contains('connection refused') ||
            errStr.contains('no route')) {
          errorCode = 'error:playback_timeout';
        } else if (errStr.contains('format') || errStr.contains('codec')) {
          errorCode = 'error:unsupported_format';
        } else if (errStr.contains('access') ||
            errStr.contains('no such file')) {
          errorCode = 'error:file_inaccessible';
        }
        _updateStatus(
          _currentStatus.copyWith(state: PlaybackState.error, error: errorCode),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // play()
  // ---------------------------------------------------------------------------

  @override
  Future<void> play(
    PlaybackTrack track, {
    Duration startAt = Duration.zero,
    bool play = true,
  }) async {
    if (_disposed) return;

    if (track.isLocal || track.sourceType == PlaybackSourceType.networkStream) {
      final uri = track.isLocal ? track.localMediaUri : track.networkMediaUri;
      if (uri == null) {
        _updateStatus(
          _currentStatus.copyWith(
            track: track,
            state: PlaybackState.error,
            error: 'Media URI is missing for ${track.id}',
          ),
        );
        return;
      }

      // ── Invalidate immediately BEFORE any await ───────────────────────────
      _attemptActive = false;
      _intentRevision++;
      _intendedState = play ? PlaybackState.playing : PlaybackState.paused;
      _playGeneration++;
      final myGen = _playGeneration;
      _watchdogTimer?.cancel();

      await _invalidateActiveSession();
      if (_disposed || _playGeneration != myGen) return;

      // ── Create and activate the new session ───────────────────────────────
      final session = NativePlaybackSession(
        generation: myGen,
        adapter: _makeAdapter(),
        startPosition: startAt,
      );
      _activeSession = session;
      _attemptActive = true;
      _recoveryUsed = false;
      _ready = false;
      _latePauseGeneration = null;

      // Bind callbacks BEFORE opening so initialization events during open()
      // are accepted.
      _bindSession(session);

      // Arm watchdog to prevent hanging on inaccessible files or broken streams
      _watchdogTimer?.cancel();
      _watchdogTimer = Timer(Duration(seconds: track.isLocal ? 5 : 20), () {
        if (_disposed || _activeSession != session) return;
        final stalledStart =
            _currentStatus.state == PlaybackState.playing &&
            _intendedState == PlaybackState.playing &&
            !session.hasPlaybackProgress;
        if (stalledStart ||
            _currentStatus.state == PlaybackState.preparing ||
            _currentStatus.state == PlaybackState.buffering) {
          _failAttempt(
            myGen,
            track.isLocal && !stalledStart
                ? 'error:file_inaccessible'
                : 'error:playback_timeout',
          );
        }
      });

      // Publish the new renderer and status BEFORE opening media.
      _updateStatus(
        _currentStatus.copyWith(
          track: track,
          state: PlaybackState.preparing,
          clearError: true,
          activeVideoId: track.isVideo ? track.id : null,
          hasVideo: track.isVideo,
          isIFrameMode: false,
          generation: myGen,
          isLive: track.liveStatus == PlaybackLiveStatus.live,
          isSeekable: false,
          position: Duration.zero,
          duration: Duration.zero,
          buffered: Duration.zero,
        ),
      );

      try {
        // Non-autoplay open: explicitly start after verifying session ownership.
        await session.adapter
            .open(
              uri,
              play: false,
              httpHeaders: track.httpHeaders,
              audioUri: track.externalAudioUri,
              video: track.isVideo,
            )
            .timeout(const Duration(seconds: 10));
        if (_disposed || _activeSession != session) return;

        // Apply user settings AFTER open() to prevent Android deadlocks.
        // Bug fix: guard each async call so a concurrent stop()/play() that
        // replaces _activeSession does not apply settings to a stale player.
        await session.adapter.setVolume(_currentStatus.volume * 100);
        if (_disposed || _activeSession != session) return;
        await session.adapter.setRate(_currentStatus.speed);
        if (_disposed || _activeSession != session) return;

        // A live always starts at its edge; seeking a live HLS window to a
        // remembered position fails ("Cannot seek in this stream").
        if (startAt > Duration.zero && track.liveStatus != PlaybackLiveStatus.live) {
          await session.adapter.seek(startAt);
          if (_disposed || _activeSession != session) return;
        }

        if (_intendedState == PlaybackState.playing) {
          await session.adapter.play();
          if (_disposed || _activeSession != session) return;
        }

        // Reconcile: move out of preparing if no terminal state arrived yet.
        final terminalStates = {PlaybackState.error, PlaybackState.ended};
        if (!terminalStates.contains(_currentStatus.state) &&
            _currentStatus.state == PlaybackState.preparing) {
          _updateStatus(
            _currentStatus.copyWith(state: PlaybackState.buffering),
          );
        }
      } catch (e) {
        if (_disposed || _activeSession != session) return;
        if (_valid(myGen)) {
          final errStr = e.toString().toLowerCase();
          String errorCode = 'error:playback_failed';
          if (errStr.contains('403') || errStr.contains('forbidden')) {
            errorCode = 'error:forbidden';
          } else if (errStr.contains('404') || errStr.contains('not found')) {
            errorCode = 'error:not_found';
          } else if (errStr.contains('timeout') ||
              errStr.contains('unreachable') ||
              errStr.contains('connection refused') ||
              errStr.contains('no route')) {
            errorCode = 'error:playback_timeout';
          } else if (errStr.contains('format') || errStr.contains('codec')) {
            errorCode = 'error:unsupported_format';
          } else if (errStr.contains('access') ||
              errStr.contains('no such file')) {
            errorCode = 'error:file_inaccessible';
          }
          _failAttempt(myGen, errorCode);
        }
      }
    }
  }

  @override
  Future<void> pause({
    String caller = 'user',
    bool failOnTimeout = false,
  }) async {
    if (_disposed) return;
    if (_currentStatus.state == PlaybackState.paused ||
        _currentStatus.state == PlaybackState.idle) {
      return;
    }
    _intendedState = PlaybackState.paused;
    _updateStatus(_currentStatus.copyWith(state: PlaybackState.paused));
    await _activeSession?.adapter.pause();
  }

  @override
  Future<void> resume() async {
    _intentRevision++;
    if (BackgroundPlaybackExperiment.enabled &&
        _currentStatus.isIFrameMode &&
        isActivityStopped) {
      _diag(
        'ENGINE resume() PASS-THROUGH [EXPERIMENT]: activity stopped but guard disabled.',
      );
    }

    _intendedState = PlaybackState.playing;
    await _activeSession?.adapter.play();
  }

  @override
  Future<void> stop() async {
    _playGeneration++;
    _intentRevision++;
    _attemptActive = false;
    _watchdogTimer?.cancel();
    _intendedState = PlaybackState.paused;

    // Optimistically update before awaiting so the UI reflects idle immediately.
    _updateStatus(
      _currentStatus.copyWith(
        state: PlaybackState.idle,
        track: null,
        activeVideoId: null,
      ),
    );

    await _invalidateActiveSession();
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (!_currentStatus.isSeekable) {
      debugPrint(
        'MediaKitPlaybackEngine: Blocked seek attempt to $position '
        '(isSeekable=false). Network capability is unknown or stream is live.',
      );
      return;
    }

    final wasPlaying = _currentStatus.state == PlaybackState.playing;

    final session = _activeSession;
    if (session == null) return;
    // A seek acknowledgement is not playback progress. Move the baseline
    // before dispatch so a backward seek during startup can still advance.
    session.progressBaseline = position;
    await session.adapter.seek(position);
    if (wasPlaying && _activeSession == session) {
      await session.adapter.play();
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    await _activeSession?.adapter.setVolume(volume * 100);
    _updateStatus(_currentStatus.copyWith(volume: volume));
  }

  @override
  bool get supportsSpeed => true;

  /// True only when MediaKit is rendering the video surface (not YouTube iframe).
  @override
  bool get supportsVideoFitMode =>
      _currentStatus.hasVideo && !_currentStatus.isIFrameMode;

  @override
  Future<void> setSpeed(double speed) async {
    await _activeSession?.adapter.setRate(speed);
  }

  @override
  Future<void> setSubtitleTrack(String? uri) async {
    if (uri == null) {
      await _activeSession?.adapter.setSubtitleTrack(SubtitleTrack.no());
    } else {
      await _activeSession?.adapter.setSubtitleTrack(SubtitleTrack.uri(uri));
    }
  }

  @override
  bool get supportsTrackSelection =>
      _activeSession?.adapter.supportsTrackSelection ?? false;

  @override
  bool get supportsExternalSubtitles =>
      _activeSession?.adapter.supportsExternalSubtitles ?? false;

  @override
  bool get supportsSubtitleDelay =>
      _activeSession?.adapter.supportsSubtitleDelay ?? false;

  @override
  bool get supportsSubtitleTextSize =>
      _activeSession?.adapter.supportsSubtitleTextSize ?? false;

  @override
  bool get supportsSubtitleBackgroundStyling =>
      _activeSession?.adapter.supportsSubtitleBackgroundStyling ?? false;

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    await _activeSession?.adapter.setSubtitleDelay(delay);
  }

  @override
  Future<void> setSubtitleAppearance({
    double? textSize,
    int? backgroundColor,
  }) async {
    await _activeSession?.adapter.setSubtitleAppearance(
      textSize: textSize,
      backgroundColor: backgroundColor,
    );
  }
  // ---------------------------------------------------------------------------
  // Status update + IFrame position polling
  // ---------------------------------------------------------------------------

  /// A non-fatal mpv error line: fail the attempt only if playback that had
  /// started stops advancing. Startup stalls stay with the play watchdog, and
  /// a paused player has nothing to verify.
  void _softError(
    NativePlaybackSession session,
    String err, {
    Duration wait = const Duration(seconds: 10),
  }) {
    if (!session.hasPlaybackProgress || session.softErrorTimer?.isActive == true) {
      return;
    }
    final generation = session.generation;
    final baseline = _currentStatus.position;
    session.softErrorTimer = Timer(wait, () {
      if (_disposed || _activeSession != session) return;
      if (_intendedState != PlaybackState.playing) return;
      if (_currentStatus.position > baseline + const Duration(milliseconds: 500)) {
        return; // mpv recovered (reconnect, software decoding, …)
      }
      print('MediaKitPlaybackEngine: stalled after "$err"');
      _failAttempt(generation, 'error:connection_lost');
    });
  }

  void _failAttempt(int generation, String error) {
    if (!_valid(generation)) return;
    _attemptActive = false;
    _watchdogTimer?.cancel();
    _updateStatus(
      _currentStatus.copyWith(state: PlaybackState.error, error: error),
    );
  }

  void _updateStatus(PlaybackStatus status) {
    if (_disposed) return;
    if (status.state != _currentStatus.state) {
      _diag(
        'STATE ${_currentStatus.state} → ${status.state} '
        'gen=$_playGeneration intended=$_intendedState '
        'activityStopped=$isActivityStopped',
      );
    }
    _currentStatus = status.copyWith(generation: _playGeneration);
    _statusController.add(_currentStatus);
  }

  // ---------------------------------------------------------------------------
  // dispose
  // ---------------------------------------------------------------------------

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _attemptActive = false;
    _playGeneration++;
    _watchdogTimer?.cancel();

    // Detach and cancel the active session's subscriptions synchronously;
    // adapter disposal is awaited to ensure native resources are freed.
    // Subscriptions must be cancelled BEFORE the native object is freed to
    // prevent a callback firing into a freed object (SIGABRT in libmpv).
    final session = _activeSession;
    _activeSession = null;
    if (session != null) {
      for (final sub in session.subscriptions) {
        sub.cancel();
      }
      session.subscriptions.clear();
      try {
        await session.adapter.dispose().timeout(const Duration(seconds: 2));
      } catch (e) {
        // Native cleanup failed or timed out, but Dart state is isolated.
      }
    }
    _statusController.close();
    _eventController.close();
  }
}
