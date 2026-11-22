import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/track.dart';
import 'dart_catalog.dart';
import 'yt_models.dart';

export 'yt_models.dart';

/// Catalog client: native NewPipe on Android (`UltratubeCatalogPlugin`),
/// [DartCatalog] (same methods and JSON shapes) on iOS and elsewhere.
class UltratubeCatalog {
  const UltratubeCatalog();
  static const _channel = MethodChannel('app.ultratube/catalog');
  static const _timeout = Duration(seconds: 60);

  static bool get _native =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<dynamic> _call(String method, [Map<String, Object?>? args]) async {
    if (!_native) {
      return DartCatalog.instance
          .call(method, args ?? const {})
          .timeout(_timeout);
    }
    final json = await _channel
        .invokeMethod<String>(method, args)
        .timeout(_timeout);
    return jsonDecode(json!);
  }

  Future<YtPage> _page(String method, [Map<String, Object?>? args]) async =>
      YtPage.fromJson(
        Map<String, dynamic>.from(await _call(method, args) as Map),
      );

  /// Video ids known to be Shorts. They resolve through the quicker app
  /// client first (one request instead of a full watch-page extraction).
  static final fastIds = <String>{};

  /// Playable URLs. Video mode may return a separate `audio` track.
  Future<Map<String, dynamic>> resolve(
    String videoId, {
    required bool video,
    int maxHeight = 1080,
    String audio = 'normal',
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) {
      throw ArgumentError('ID de vídeo inválido');
    }
    final result = Map<String, dynamic>.from(
      await _call('resolve', {
            'url': 'https://www.youtube.com/watch?v=$videoId',
            'video': video,
            'maxHeight': maxHeight,
            'fast': fastIds.contains(videoId),
            'audio': audio,
          })
          as Map,
    );
    final uri = Uri.tryParse(result['stream'] as String? ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError('O provedor não retornou uma mídia HTTPS válida');
    }
    return result;
  }

  /// [kind]: all | music | videos | shorts | channels.
  Future<YtPage> searchItems(String query, {String kind = 'all'}) =>
      _page('search', {'query': query, 'kind': kind});

  Future<YtPage> more(String token) => _page('more', {'token': token});

  Future<List<String>> suggestions(String query) async => [
    for (final s in (await _call('suggestions', {'query': query}) as List))
      s as String,
  ];

  Future<List<String>> kiosks() async => [
    for (final s in (await _call('kiosks') as List)) s as String,
  ];

  Future<YtPage> kiosk(String id) => _page('kiosk', {'id': id});

  /// LRCLIB lyrics (`syncedLyrics`/`plainLyrics`/`instrumental`), with the
  /// same title clean-up on the phone, the watch and iOS.
  Future<Map<String, dynamic>> lyrics(String title, String artist) async =>
      Map<String, dynamic>.from(
        await _call('lyrics', {'title': title, 'artist': artist}) as Map,
      );

  /// Newest uploads of [channels] (channel URLs), merged newest first.
  Future<YtPage> feed(List<String> channels) =>
      _page('feed', {'channels': channels});

  Future<YtChannel> channel(String url) async => YtChannel.fromJson(
    Map<String, dynamic>.from(await _call('channel', {'url': url}) as Map),
  );

  Future<YtPage> channelTab(String url, String tab) =>
      _page('channelTab', {'url': url, 'tab': tab});

  Future<YtPlaylist> playlist(String url) async => YtPlaylist.fromJson(
    url,
    Map<String, dynamic>.from(await _call('playlist', {'url': url}) as Map),
  );

  Future<YtVideo> video(String url) async => YtVideo.fromJson(
    Map<String, dynamic>.from(await _call('video', {'url': url}) as Map),
  );

  Future<(List<YtComment>, String?, bool)> comments(String url) async {
    final j = Map<String, dynamic>.from(
      await _call('comments', {'url': url}) as Map,
    );
    return (
      [
        for (final e in (j['items'] as List? ?? const []))
          YtComment.fromJson(Map<String, dynamic>.from(e as Map)),
      ],
      j['next'] as String?,
      j['disabled'] as bool? ?? false,
    );
  }

  Future<(List<YtComment>, String?)> moreComments(String token) async {
    final j = Map<String, dynamic>.from(
      await _call('more', {'token': token}) as Map,
    );
    return (
      [
        for (final e in (j['items'] as List? ?? const []))
          YtComment.fromJson(Map<String, dynamic>.from(e as Map)),
      ],
      j['next'] as String?,
    );
  }

  /// Flat music/video search kept for the Shorts picker and older callers.
  Future<List<Track>> search(
    String query, {
    bool music = true,
    bool shorts = false,
  }) async {
    final page = await searchItems(
      query,
      kind: shorts ? 'shorts' : (music ? 'music' : 'videos'),
    );
    return [
      for (final item in page.items)
        if (item.videoId != null) item.toTrack(),
    ];
  }

  /// YouTube's "up next" items for [videoId], used for endless autoplay.
  Future<List<Track>> related(String videoId) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) return const [];
    final list = await _call('related', {
      'url': 'https://www.youtube.com/watch?v=$videoId',
    });
    return [
      for (final e in list as List)
        if (YtItem.fromJson(Map<String, dynamic>.from(e as Map))
            case final item when item.videoId != null)
          item.toTrack(),
    ];
  }
}
