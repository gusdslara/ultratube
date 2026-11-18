import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'twitch_api.dart';

// Pure Dart (dart:io only) so it can be tested with a plain `dart` script.

/// What the ad filter is doing right now for one channel.
enum TwitchAdState {
  /// Plain live segments.
  none,

  /// Twitch stitched an ad into the main stream; segments are coming from an
  /// ad-free backup stream (usually lower quality) until it ends.
  backup,

  /// Ad segments are being dropped and no clean backup was found: the
  /// picture holds until the break ends.
  blocking,
}

class TwitchAdEvent {
  const TwitchAdEvent(this.login, this.state);
  final String login;
  final TwitchAdState state;
}

/// Local HLS proxy for Twitch lives. The player opens
/// `http://127.0.0.1:<port>/live/<login>.m3u8?q=<quality>`; each poll fetches
/// Twitch's media playlist and serves a rewritten one:
///
/// * Server-side ad segments (EXTINF title without "live", the way Twitch
///   marks stitched ads) are never passed to the player.
/// * During a break, the same moment is taken from a backup access token
///   (embed/popout/autoplay player types), which Twitch usually serves
///   without ads. Segments are merged by PROGRAM-DATE-TIME, so there are no
///   repeats or gaps when switching, and a discontinuity tag marks the jump.
/// * Our own media sequence numbers keep the playlist monotonic for the
///   player even though the upstream sources are numbered differently.
///
/// Segment bytes go straight from Twitch's CDN to the player; only the small
/// playlist text passes through here.
class TwitchProxy {
  TwitchProxy({TwitchApi? api}) : _api = api ?? TwitchApi.instance;
  static final instance = TwitchProxy();

  final TwitchApi _api;
  HttpServer? _server;
  Future<HttpServer>? _starting;
  final _sessions = <String, _ProxySession>{};
  final _events = StreamController<TwitchAdEvent>.broadcast();

  /// Ad filter changes (for the "intervalo bloqueado" badge).
  Stream<TwitchAdEvent> get events => _events.stream;

  static const preferredPort = 47615;

  /// Test hook: pretend every Nth playlist of the main stream has an ad.
  int debugFakeAdEvery = 0;

  Future<HttpServer> _ensureServer() {
    final running = _server;
    if (running != null) return Future.value(running);
    // A fixed port keeps URLs saved by the player (restored after an app
    // restart) valid; any free port if it is taken.
    return _starting ??= HttpServer.bind(InternetAddress.loopbackIPv4, preferredPort)
        .catchError((Object _) => HttpServer.bind(InternetAddress.loopbackIPv4, 0))
        .then((server) {
      _server = server;
      server.listen(_handle, onError: (Object _) {});
      return server;
    });
  }

  /// Opens (or reuses) a channel session and returns the URL to play.
  /// Throws [TwitchException] when the channel is offline.
  Future<Uri> liveUrl(String login, {String quality = 'best'}) async {
    if (!TwitchApi.validLogin(login)) throw const TwitchException('Canal inválido');
    final server = await _ensureServer();
    final key = login.toLowerCase();
    final session = _sessions[key] ?? _ProxySession(key, _api, (s) => _events.add(TwitchAdEvent(key, s)), () => debugFakeAdEvery);
    _sessions[key] = session;
    // Fail fast (offline, banned…) before handing the URL to the player.
    await session.prime();
    session.reset();
    return Uri.parse('http://127.0.0.1:${server.port}/live/$key.m3u8?q=${Uri.encodeQueryComponent(quality)}&n=${session.epoch}');
  }

  /// Qualities offered by the channel's main stream.
  List<TwitchVariant> variants(String login) => _sessions[login.toLowerCase()]?.primary.variants ?? const [];

  TwitchAdState adState(String login) => _sessions[login.toLowerCase()]?.adState ?? TwitchAdState.none;

  /// Forgets a channel (closing the watch page).
  void release(String login) => _sessions.remove(login.toLowerCase())?.dispose();

  /// Direct playlist for a past broadcast (VODs carry no live ad stitching).
  Future<(Uri, List<TwitchVariant>)> vodUrl(String id, {String quality = 'best'}) async {
    if (!RegExp(r'^\d{3,15}$').hasMatch(id)) throw const TwitchException('Vídeo inválido');
    final access = await _api.vodAccess(id);
    final master = await _api.fetchText(TwitchApi.vodMasterUrl(id, access));
    final variants = TwitchApi.parseMaster(master);
    if (variants.isEmpty) throw const TwitchException('Vídeo indisponível');
    final pick = pickVariant(variants, quality);
    return (Uri.parse(pick.url), variants);
  }

  static TwitchVariant pickVariant(List<TwitchVariant> variants, String quality) {
    final video = variants.where((v) => !v.audioOnly).toList()..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    if (quality == 'audio_only') {
      return variants.firstWhere((v) => v.audioOnly, orElse: () => video.last);
    }
    if (video.isEmpty) return variants.first;
    if (quality == 'best' || quality.isEmpty) return video.first;
    final exact = video.where((v) => v.name.startsWith(quality));
    if (exact.isNotEmpty) return exact.first;
    final want = int.tryParse(RegExp(r'^(\d+)').firstMatch(quality)?.group(1) ?? '') ?? 1080;
    // Highest rendition not above the request, else the lowest available.
    return video.firstWhere((v) => v.height <= want, orElse: () => video.last);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final m = RegExp(r'^/live/([a-z0-9_]{2,25})\.m3u8$').firstMatch(req.uri.path);
      var session = m == null ? null : _sessions[m.group(1)!];
      if (session == null && m != null) {
        // A URL from before an app restart: open the channel on demand.
        final key = m.group(1)!;
        final fresh = _ProxySession(key, _api, (st) => _events.add(TwitchAdEvent(key, st)), () => debugFakeAdEvery);
        await fresh.prime();
        session = _sessions[key] ??= fresh;
      }
      if (session == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final body = utf8.encode(await session.playlist(req.uri.queryParameters['q'] ?? 'best'));
      // Explicit length + "Connection: close": ffmpeg otherwise tries to
      // reuse the socket, reads EOF and backs off 1–3 s before each reload.
      res
        ..persistentConnection = false
        ..contentLength = body.length;
      res.headers
        ..contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache, no-store');
      res.add(body);
    } on TwitchException catch (e) {
      res.statusCode = e.message.contains('offline') ? HttpStatus.notFound : HttpStatus.badGateway;
    } catch (_) {
      res.statusCode = HttpStatus.badGateway;
    }
    await res.close();
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _starting = null;
    for (final s in _sessions.values) {
      s.dispose();
    }
    _sessions.clear();
  }
}

class _Segment {
  _Segment({required this.uri, required this.duration, required this.title, this.pdt, this.map});
  final String uri;
  final double duration;
  final String title;
  final DateTime? pdt;
  final String? map;
  bool discontinuity = false;
  String source = '';

  /// Twitch titles real content segments "live"; stitched ads get other
  /// titles (e.g. "Amazon|…").
  bool get isAd => !title.contains('live');
}

class _MediaPlaylist {
  const _MediaPlaylist(this.segments, this.targetDuration, this.hasAdMarkers);
  final List<_Segment> segments;
  final int targetDuration;
  final bool hasAdMarkers;
  bool get hasAds => hasAdMarkers || segments.any((s) => s.isAd);
}

/// One access token / master playlist (main or backup player type).
class _Source {
  _Source(this.login, this.api, this.playerType, {this.platform = 'web'});
  final String login;
  final TwitchApi api;
  final String playerType;
  final String platform;
  List<TwitchVariant> variants = const [];
  DateTime _fetched = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _failedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get coolingDown => DateTime.now().difference(_failedAt) < const Duration(seconds: 30);

  Future<void> master({bool force = false}) async {
    if (!force && variants.isNotEmpty && DateTime.now().difference(_fetched) < const Duration(minutes: 8)) return;
    final access = await api.liveAccess(login, playerType: playerType, platform: platform);
    final text = await api.fetchText(TwitchApi.liveMasterUrl(login, access));
    final parsed = TwitchApi.parseMaster(text);
    if (parsed.isEmpty) throw const TwitchException('Transmissão offline');
    variants = parsed;
    _fetched = DateTime.now();
  }

  Future<_MediaPlaylist> media(String quality) async {
    try {
      await master();
      return await _fetchMedia(quality);
    } on TwitchException {
      // Expired token/node: one fresh master, then give up for a while.
      try {
        await master(force: true);
        return await _fetchMedia(quality);
      } catch (_) {
        _failedAt = DateTime.now();
        rethrow;
      }
    }
  }

  Future<_MediaPlaylist> _fetchMedia(String quality) async {
    final variant = TwitchProxy.pickVariant(variants, quality);
    final base = Uri.parse(variant.url);
    final text = await api.fetchText(base);
    return _parse(text, base);
  }

  static _MediaPlaylist _parse(String text, Uri base) {
    final segments = <_Segment>[];
    var target = 6;
    var adMarkers = false;
    DateTime? pdt;
    String? map;
    double? duration;
    var title = '';
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        target = int.tryParse(line.substring(22)) ?? target;
      } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
        pdt = DateTime.tryParse(line.substring(25));
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final uri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
        if (uri != null) map = base.resolve(uri).toString();
      } else if (line.startsWith('#EXT-X-DATERANGE:')) {
        if (line.contains('stitched-ad') || line.contains('twitch-ad-quartile') || line.contains('X-TV-TWITCH-AD')) adMarkers = true;
      } else if (line.startsWith('#EXTINF:')) {
        final body = line.substring(8);
        final comma = body.indexOf(',');
        duration = double.tryParse(comma < 0 ? body : body.substring(0, comma));
        title = comma < 0 ? '' : body.substring(comma + 1);
      } else if (!line.startsWith('#') && duration != null) {
        segments.add(_Segment(uri: base.resolve(line).toString(), duration: duration, title: title, pdt: pdt, map: map));
        duration = null;
        pdt = null;
        title = '';
      }
    }
    return _MediaPlaylist(segments, target, adMarkers);
  }
}

class _ProxySession {
  _ProxySession(this.login, this.api, this._notify, this._fakeAdEvery)
    : primary = _Source(login, api, 'site'),
      backups = [
        _Source(login, api, 'embed'),
        _Source(login, api, 'popout'),
        _Source(login, api, 'autoplay', platform: 'android'),
      ];

  final String login;
  final TwitchApi api;
  final void Function(TwitchAdState) _notify;
  final int Function() _fakeAdEvery;
  final _Source primary;
  final List<_Source> backups;

  static const _window = 24;
  final _segments = <_Segment>[];
  int _mediaSeq = 0;
  int _discSeq = 0;
  DateTime? _lastPdt;
  final _seenUris = <String>{};
  String? _lastSource;
  int _target = 6;
  int _polls = 0;
  int epoch = 0;
  TwitchAdState adState = TwitchAdState.none;
  Future<void>? _inFlight;

  Future<void> prime() => primary.master(force: primary.variants.isEmpty);

  /// New player connection: start from a fresh window at the live edge.
  void reset() {
    epoch++;
    _segments.clear();
    _seenUris.clear();
    _lastPdt = null;
    _lastSource = null;
    _mediaSeq = 0;
    _discSeq = 0;
  }

  void _setState(TwitchAdState next) {
    if (next == adState) return;
    adState = next;
    _notify(next);
  }

  /// Answers the player at once with the latest assembled playlist. Twitch
  /// is polled in the background (about every second while the player keeps
  /// asking), so slow mobile round trips never sit in the player's reload
  /// path; only the very first request waits for real content.
  Future<String> playlist(String quality) async {
    _lastRequest = DateTime.now();
    if (quality != _quality) {
      _quality = quality;
      _segments.clear();
      _seenUris.clear();
      _lastPdt = null;
    }
    if (_segments.isEmpty) await _refresh();
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      // Player gone (closed, paused for long, other track): stop polling.
      if (DateTime.now().difference(_lastRequest) > const Duration(seconds: 20)) {
        _ticker?.cancel();
        _ticker = null;
        return;
      }
      _refresh().catchError((Object _) {});
    });
    return _render();
  }

  Timer? _ticker;
  DateTime _lastRequest = DateTime.now();
  String _quality = 'best';

  /// Serialised: never two upstream polls at once.
  Future<void> _refresh() => _inFlight ??= _update(_quality).whenComplete(() => _inFlight = null);

  void dispose() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _update(String quality) async {
    _polls++;
    final main = await primary.media(quality);
    _target = main.targetDuration;
    final fakeEvery = _fakeAdEvery();
    final fakeAd = fakeEvery > 0 && (_polls ~/ fakeEvery).isOdd;
    if (!main.hasAds && !fakeAd) {
      _setState(TwitchAdState.none);
      _append(main.segments, 'site');
    } else {
      _MediaPlaylist? clean;
      String? name;
      for (final b in backups) {
        if (b.coolingDown) continue;
        try {
          final p = await b.media(quality);
          if (!p.hasAds && p.segments.isNotEmpty) {
            clean = p;
            name = b.playerType;
            break;
          }
        } catch (_) {
          // Try the next player type.
        }
      }
      if (clean != null) {
        _setState(TwitchAdState.backup);
        _append(clean.segments, name!);
      } else {
        _setState(TwitchAdState.blocking);
        // Keep whatever real content the main stream still has; ads never
        // reach the player. A fake ad (test hook) still serves real segments.
        _append(main.segments.where((s) => !s.isAd).toList(), 'site');
      }
    }
    // First connection during a pre-roll: wait briefly for real content
    // instead of handing the player an empty (invalid) playlist.
    if (_segments.isEmpty) {
      for (var i = 0; i < 4 && _segments.isEmpty; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final again = await primary.media(quality);
        _append(again.segments.where((s) => !s.isAd).toList(), 'site');
      }
    }
  }

  void _append(List<_Segment> incoming, String source) {
    var appended = false;
    // On a fresh window only keep the newest few segments (live edge).
    final list = _segments.isEmpty && incoming.length > 6 ? incoming.sublist(incoming.length - 6) : incoming;
    for (final s in list) {
      if (s.isAd) continue;
      final newer = s.pdt == null
          ? !_seenUris.contains(s.uri)
          : _lastPdt == null || s.pdt!.isAfter(_lastPdt!.add(const Duration(milliseconds: 250)));
      if (!newer) continue;
      s.source = source;
      if (_lastSource != null && _lastSource != source) s.discontinuity = true;
      _lastSource = source;
      if (s.pdt != null) _lastPdt = s.pdt;
      _seenUris.add(s.uri);
      _segments.add(s);
      appended = true;
    }
    if (!appended) return;
    while (_segments.length > _window) {
      final removed = _segments.removeAt(0);
      _mediaSeq++;
      if (removed.discontinuity) _discSeq++;
    }
    if (_seenUris.length > 400) {
      _seenUris
        ..clear()
        ..addAll(_segments.map((s) => s.uri));
    }
  }

  String _render() {
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:6')
      ..writeln('#EXT-X-TARGETDURATION:${_targetDuration()}')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:$_mediaSeq')
      ..writeln('#EXT-X-DISCONTINUITY-SEQUENCE:$_discSeq');
    String? map;
    for (var i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      if (s.discontinuity && i > 0) b.writeln('#EXT-X-DISCONTINUITY');
      if (s.map != null && (s.map != map || i == 0)) {
        b.writeln('#EXT-X-MAP:URI="${s.map}"');
        map = s.map;
      }
      if (s.pdt != null) b.writeln('#EXT-X-PROGRAM-DATE-TIME:${s.pdt!.toUtc().toIso8601String()}');
      b
        ..writeln('#EXTINF:${s.duration.toStringAsFixed(3)},live')
        ..writeln(s.uri);
    }
    return b.toString();
  }

  int _targetDuration() {
    var t = _target;
    for (final s in _segments) {
      final d = s.duration.ceil();
      if (d > t) t = d;
    }
    return t;
  }
}
