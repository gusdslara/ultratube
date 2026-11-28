import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yte;

import 'innertube.dart';

/// Pure-Dart port of the Android `Catalog.kt` (NewPipeExtractor) for iOS and
/// other platforms without the native plugin. Every method returns the same
/// JSON shapes, so `UltratubeCatalog` and the screens stay unchanged.
///
/// Lists come from InnerTube (YouTube's own web API); playable URLs come from
/// youtube_explode_dart, which handles the player clients and ciphers.
class DartCatalog {
  DartCatalog._();
  static final instance = DartCatalog._();

  final _tube = InnerTube();
  final _http = http.Client();
  yte.YoutubeExplode? _explode;
  yte.YoutubeExplode get _yt => _explode ??= yte.YoutubeExplode();

  static const _hosts = {
    'www.youtube.com',
    'youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
  };

  /// Dispatches a call with the native channel's method names and arguments.
  Future<Object?> call(String method, Map<String, Object?> args) async {
    String s(String name) => args[name] as String? ?? '';
    switch (method) {
      case 'search':
        return search(s('query'), args['kind'] as String? ?? 'all');
      case 'suggestions':
        return suggestions(s('query'));
      case 'more':
        return more(s('token'));
      case 'kiosks':
        return kiosks();
      case 'kiosk':
        return kiosk(s('id'));
      case 'feed':
        return feed([for (final c in (args['channels'] as List? ?? const [])) '$c']);
      case 'channel':
        return channel(s('url'));
      case 'channelTab':
        return channelTab(s('url'), s('tab'));
      case 'playlist':
        return playlist(s('url'));
      case 'video':
        return video(s('url'));
      case 'comments':
        return comments(s('url'));
      case 'resolve':
        return resolve(
          s('url'),
          video: args['video'] as bool? ?? false,
          maxHeight: (args['maxHeight'] as num?)?.toInt() ?? 1080,
        );
      case 'related':
        return related(s('url'));
      case 'lyrics':
        return lyrics(s('title'), s('artist'));
    }
    throw UnsupportedError(method);
  }

  // ---------------------------------------------------------- pagination

  final _cursors = <String, _Cursor>{};

  Object? _remember(_Cursor? cursor) {
    if (cursor == null) return null;
    final id = const Uuid().v4();
    _cursors[id] = cursor;
    while (_cursors.length > 200) {
      _cursors.remove(_cursors.keys.first);
    }
    return id;
  }

  Json _page(List<Json> items, _Cursor? next) => {
    'items': items,
    'next': _remember(next),
  };

  _Cursor? _next(
    Json page,
    _Kind kind, {
    String endpoint = 'browse',
    bool music = false,
    bool Function(Json item)? accept,
    bool shelves = false,
  }) {
    final token = continuation(page);
    if (token == null) return null;
    return _Cursor(
      kind: kind,
      endpoint: endpoint,
      token: token.$1,
      legacy: token.$2,
      music: music,
      accept: accept,
      shelves: shelves,
    );
  }

  Future<Json> _continue(_Cursor cursor) => cursor.legacy
      ? _tube.post(
          cursor.endpoint,
          const {},
          music: cursor.music,
          query: {
            'ctoken': cursor.token,
            'continuation': cursor.token,
            'type': 'next',
          },
        )
      : _tube.post(cursor.endpoint, {
          'continuation': cursor.token,
        }, music: cursor.music);

  /// Continues any list returned earlier.
  Future<Json> more(String token) async {
    final cursor = _cursors[token];
    if (cursor == null) throw StateError('Lista expirada; atualize a página');
    if (cursor.kind == _Kind.comments) return _commentsPage(await _continue(cursor), cursor);
    var page = await _continue(cursor);
    var items = _items(page, cursor);
    var next = _next(
      page,
      cursor.kind,
      endpoint: cursor.endpoint,
      music: cursor.music,
      accept: cursor.accept,
      shelves: cursor.shelves,
    );
    var hops = 0;
    // Filters (Shorts/videos) can empty a page; keep reading a little.
    while (cursor.accept != null && items.length < 8 && next != null && hops++ < 3) {
      page = await _continue(next);
      items = [...items, ..._items(page, next)];
      next = _next(
        page,
        cursor.kind,
        endpoint: cursor.endpoint,
        music: cursor.music,
        accept: cursor.accept,
        shelves: cursor.shelves,
      );
    }
    return _page(items, next);
  }

  List<Json> _items(Json page, _Cursor cursor) {
    final items = cursor.music
        ? parseMusicItems(page)
        : parseItems(page, shelves: cursor.shelves);
    final accept = cursor.accept;
    return accept == null ? items : items.where(accept).toList();
  }

  // -------------------------------------------------------------- search

  static const _musicParams = {
    'music': 'EgWKAQIIAWoKEAkQBRAKEAMQBA==',
    'music_videos': 'EgWKAQIQAWoKEAkQChAFEAMQBA==',
    'music_albums': 'EgWKAQIYAWoKEAkQChAFEAMQBA==',
    'music_playlists': 'EgeKAQQoAEABagoQAxAEEAoQCRAF',
    'music_artists': 'EgWKAQIgAWoKEAkQChAFEAMQBA==',
  };

  static const _webParams = {
    'videos': 'EgIQAQ==',
    'shorts': 'EgIQCQ==',
    'channels': 'EgIQAg==',
    'playlists': 'EgIQAw==',
  };

  /// [kind]: all | videos | shorts | channels | playlists | music (songs) |
  /// music_videos | music_albums | music_playlists | music_artists.
  Future<Json> search(String query, String kind) async {
    final q = query.trim();
    if (q.isEmpty) throw ArgumentError('Digite uma busca');
    final text = q.length > 200 ? q.substring(0, 200) : q;
    final musicParams = _musicParams[kind];
    if (musicParams != null) {
      final page = await _tube.post('search', {
        'query': text,
        'params': musicParams,
      }, music: true);
      final cursor = _next(page, _Kind.list, endpoint: 'search', music: true);
      return {
        ..._page(parseMusicItems(page), cursor),
        'suggestion': '',
        'corrected': false,
      };
    }

    bool Function(Json)? accept = switch (kind) {
      'shorts' => (item) => item['shorts'] == true,
      'videos' => (item) => item['type'] == 'video' && item['shorts'] != true,
      'channels' => (item) => item['type'] == 'channel',
      'playlists' => (item) => item['type'] == 'playlist',
      _ => null,
    };
    final shelves = kind == 'shorts';
    Json page;
    try {
      page = await _tube.post('search', {
        'query': text,
        if (_webParams[kind] != null) 'params': _webParams[kind],
      });
    } on InnerTubeException {
      if (kind != 'shorts') rethrow;
      // Older regions reject the Shorts type filter; search "#shorts" instead.
      page = await _tube.post('search', {'query': '$text #shorts'});
    }
    final first = _Cursor(
      kind: _Kind.list,
      endpoint: 'search',
      token: '',
      accept: accept,
      shelves: shelves,
    );
    var items = _items(page, first);
    var next = _next(page, _Kind.list, endpoint: 'search', accept: accept, shelves: shelves);
    final want = kind == 'shorts' ? 12 : 8;
    final maxHops = kind == 'shorts' ? 5 : 3;
    var hops = 0;
    while (items.length < want && next != null && hops++ < maxHops) {
      final more = await _continue(next);
      items = [...items, ..._items(more, next)];
      next = _next(more, _Kind.list, endpoint: 'search', accept: accept, shelves: shelves);
    }
    final showing = find(page, 'showingResultsForRenderer');
    final didYouMean = find(page, 'didYouMeanRenderer');
    return {
      ..._page(items, next),
      'suggestion': showing != null
          ? textOf(showing['correctedQuery'])
          : textOf(didYouMean?['correctedQuery']),
      'corrected': showing != null,
    };
  }

  static String textOf(Object? node) => text(node);

  Future<List<String>> suggestions(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final list = await _yt.search.getQuerySuggestions(
      q.length > 100 ? q.substring(0, 100) : q,
    );
    return list.take(8).toList();
  }

  // --------------------------------------------------------------- feeds

  /// NewPipe kiosk ids mapped to YouTube's own topic pages. The global
  /// Trending page was retired in 2025 and the Gaming/Podcasts destinations
  /// no longer answer, so those are not offered.
  static const _kiosks = {
    'trending_music': 'UC-9-kyTW8ZkZNDHQJ6FgpwQ',
    'live': 'UC4R8DWoMoI7CAwX8_LjQHig',
    'news': 'UCYfdidRxbB8Qhf0Nx7ioOYw',
    'sports': 'UCEgdi0XIXXZ-qJOFPf4JSKw',
  };

  List<String> kiosks() => _kiosks.keys.toList();

  Future<Json> kiosk(String id) async {
    final browseId = _kiosks[id];
    if (browseId == null) throw ArgumentError('Categoria indisponível: $id');
    final page = await _tube.post('browse', {'browseId': browseId});
    final items = parseItems(page).where((i) => i['type'] == 'video').toList();
    return _page(
      items,
      _next(page, _Kind.list, accept: (i) => i['type'] == 'video'),
    );
  }

  /// Latest uploads of many channels through YouTube's RSS feeds, fetched in
  /// parallel and merged newest first.
  Future<Json> feed(List<String> channels, {int perChannel = 15}) async {
    final urls = channels.toSet().take(300).toList();
    var failed = 0;
    final items = <Json>[];
    const batch = 8;
    for (var i = 0; i < urls.length; i += batch) {
      final chunk = urls.sublist(i, i + batch > urls.length ? urls.length : i + batch);
      final results = await Future.wait(
        chunk.map(
          (url) => _rss(url, perChannel)
              .timeout(const Duration(seconds: 30))
              .then<List<Json>?>((v) => v)
              .catchError((Object _) => null),
        ),
      );
      for (final result in results) {
        if (result == null) {
          failed++;
        } else {
          items.addAll(result);
        }
      }
    }
    items.sort(
      (a, b) => (b['uploadedAt'] as int).compareTo(a['uploadedAt'] as int),
    );
    return {..._page(items, null), 'failed': failed};
  }

  Future<List<Json>> _rss(String url, int limit) async {
    final id = await _channelId(url);
    final response = await _tube.get(
      Uri.parse('https://www.youtube.com/feeds/videos.xml?channel_id=$id'),
    );
    if (response.statusCode != 200) {
      throw StateError('RSS ${response.statusCode}');
    }
    final doc = XmlDocument.parse(utf8.decode(response.bodyBytes));
    final author = doc.rootElement
        .findElements('author')
        .firstOrNull
        ?.getElement('name')
        ?.innerText;
    final out = <Json>[];
    for (final entry in doc.findAllElements('entry').take(limit)) {
      final videoId = entry.getElement('yt:videoId')?.innerText ?? '';
      if (videoId.length != 11) continue;
      final group = entry.getElement('media:group');
      final link = entry.getElement('link')?.getAttribute('href') ?? '';
      final published = DateTime.tryParse(
        entry.getElement('published')?.innerText ?? '',
      );
      final views = int.tryParse(
        group
                ?.getElement('media:community')
                ?.getElement('media:statistics')
                ?.getAttribute('views') ??
            '',
      );
      final cover =
          group?.getElement('media:thumbnail')?.getAttribute('url') ?? '';
      out.add(
        videoItem(
          id: videoId,
          title: entry.getElement('title')?.innerText ?? '',
          channel: author ?? entry.getElement('author')?.getElement('name')?.innerText ?? '',
          channelId: id,
          cover: cover,
          coverHd: cover,
          views: views ?? -1,
          uploaded: published == null ? '' : _ago(published),
          uploadedAt: published?.millisecondsSinceEpoch ?? 0,
          shorts: link.contains('/shorts/'),
        ),
      );
    }
    return out;
  }

  static String _ago(DateTime date) {
    final diff = DateTime.now().difference(date);
    String plural(int n, String one, String many) => 'há $n ${n == 1 ? one : many}';
    if (diff.inMinutes < 60) return plural(diff.inMinutes.clamp(1, 59), 'minuto', 'minutos');
    if (diff.inHours < 24) return plural(diff.inHours, 'hora', 'horas');
    if (diff.inDays < 7) return plural(diff.inDays, 'dia', 'dias');
    if (diff.inDays < 30) return plural(diff.inDays ~/ 7, 'semana', 'semanas');
    if (diff.inDays < 365) return plural(diff.inDays ~/ 30, 'mês', 'meses');
    return plural(diff.inDays ~/ 365, 'ano', 'anos');
  }

  // ------------------------------------------------------------- channel

  final _channelIds = <String, String>{};

  /// UC… id of any channel URL (/channel/UC…, /@handle, /c/name, /user/x).
  Future<String> _channelId(String url) async {
    final match = RegExp(r'/channel/(UC[\w-]{22})').firstMatch(url);
    if (match != null) return match.group(1)!;
    if (RegExp(r'^UC[\w-]{22}$').hasMatch(url)) return url;
    final cached = _channelIds[url];
    if (cached != null) return cached;
    final full = url.startsWith('http') ? url : 'https://www.youtube.com/$url';
    final resolved = await _tube.post('navigation/resolve_url', {'url': full});
    final id = str(resolved, ['endpoint', 'browseEndpoint', 'browseId']);
    if (!id.startsWith('UC')) throw StateError('Canal não encontrado');
    return _channelIds[url] = id;
  }

  static const _tabParams = {
    'videos': 'EgZ2aWRlb3PyBgQKAjoA',
    'shorts': 'EgZzaG9ydHPyBgUKA5oBAA==',
    'livestreams': 'EgdzdHJlYW1z8gYECgJ6AA==',
    'playlists': 'EglwbGF5bGlzdHPyBgQKAkIA',
  };

  static const _tabPaths = {
    '/videos': 'videos',
    '/shorts': 'shorts',
    '/streams': 'livestreams',
    '/playlists': 'playlists',
  };

  Future<Json> channel(String url) async {
    final id = await _channelId(url);
    final page = await _tube.post('browse', {'browseId': id});
    final meta = obj(page, ['metadata', 'channelMetadataRenderer']);
    final header = obj(page, ['header']);
    final c4 = obj(header, ['c4TabbedHeaderRenderer']);
    final view = find(header, 'pageHeaderViewModel');

    var title = str(meta, ['title']);
    if (title.isEmpty) title = text(c4?['title']);
    if (title.isEmpty) title = text(obj(view, ['title', 'dynamicTextViewModel', 'text']));

    var avatar = c4 != null ? thumbAtLeast(c4['avatar'], 176) : '';
    if (avatar.isEmpty) avatar = firstImage(obj(view, ['image']), width: 176);
    if (avatar.isEmpty) avatar = thumbAtLeast(meta?['avatar'], 176);

    var banner = c4 != null ? thumbAtLeast(c4['banner'], 1080) : '';
    if (banner.isEmpty) banner = firstImage(obj(view, ['banner']), width: 1080);

    var subscribers = parseCount(text(c4?['subscriberCountText']));
    if (subscribers < 0 && view != null) {
      walk(view['metadata'], (key, child) {
        if (key == 'text' && subscribers < 0) {
          final label = str(child, ['content']);
          if (RegExp(r'inscrit|subscriber', caseSensitive: false).hasMatch(label)) {
            subscribers = parseCount(label);
          }
        }
        return false;
      });
    }

    final tabs = <String>[];
    for (final tab in findAll(page, 'tabRenderer')) {
      final path = str(tab, [
        'endpoint',
        'commandMetadata',
        'webCommandMetadata',
        'url',
      ]);
      for (final entry in _tabPaths.entries) {
        if (path.endsWith(entry.key) && !tabs.contains(entry.value)) {
          tabs.add(entry.value);
        }
      }
    }

    Json videos;
    try {
      final first = tabs.contains('videos') ? 'videos' : (tabs.isNotEmpty ? tabs.first : 'videos');
      videos = await _tab(id, first, channelName: title);
    } catch (_) {
      videos = _page(const [], null);
    }
    return {
      'url': channelUrl(id),
      'id': id,
      'title': title,
      'avatar': avatar,
      'banner': banner,
      'subscribers': subscribers,
      'description': str(meta, ['description']),
      'verified': verifiedBadge(c4?['badges']) ||
          verifiedBadge(obj(view, ['title'])),
      'tabs': tabs,
      'videos': videos,
    };
  }

  Future<Json> channelTab(String url, String tab) async =>
      _tab(await _channelId(url), tab);

  Future<Json> _tab(String id, String tab, {String channelName = ''}) async {
    final params = _tabParams[tab];
    if (params == null) return _page(const [], null);
    final page = await _tube.post('browse', {'browseId': id, 'params': params});
    // Tab rows omit the owner: fill it so cards and the player show it.
    final items = [
      for (final item in parseItems(page, shelves: tab == 'shorts'))
        if (item['type'] == 'video' &&
            (channelName.isNotEmpty || (item['channel'] as String).isEmpty))
          {
            ...item,
            'channel': channelName,
            'artist': artistName(channelName),
            'channelUrl': channelUrl(id),
            if (tab == 'shorts') 'shorts': true,
          }
        else
          item,
    ];
    return _page(items, _next(page, _Kind.list, shelves: tab == 'shorts'));
  }

  // ------------------------------------------------------------ playlist

  /// Playlist header plus its first page of videos.
  Future<Json> playlist(String url) async {
    final listId = Uri.tryParse(url)?.queryParameters['list'] ?? '';
    if (listId.isEmpty) throw ArgumentError('Playlist inválida');
    final page = await _tube.post('browse', {'browseId': 'VL$listId'});
    final items = parseItems(page).where((i) => i['type'] == 'video').toList();
    final micro = obj(page, ['microformat', 'microformatDataRenderer']);
    final header = obj(page, ['header', 'playlistHeaderRenderer']);
    final view = find(obj(page, ['header']), 'pageHeaderViewModel');
    final sidebar = find(page, 'playlistSidebarPrimaryInfoRenderer');
    final owner = find(page, 'videoOwnerRenderer');

    var title = str(micro, ['title']);
    if (title.isEmpty) title = text(header?['title']);
    if (title.isEmpty) title = text(obj(view, ['title', 'dynamicTextViewModel', 'text']));
    if (title.isEmpty) title = text(sidebar?['title']);

    var channel = owner != null ? text(owner['title']) : '';
    if (channel.isEmpty) channel = text(header?['ownerText']);
    var channelId = channelIdIn(owner ?? header?['ownerText']);
    if (channel.isEmpty && view != null) {
      final parts = <String>[];
      walk(view['metadata'], (key, child) {
        if (key == 'text' && child['content'] is String) parts.add(child['content'] as String);
        return false;
      });
      if (parts.isNotEmpty) channel = parts.first.replaceFirst(RegExp(r'^(de|by)\s+', caseSensitive: false), '');
      if (channelId.isEmpty) channelId = channelIdIn(view['metadata']);
    }

    var count = parseCount(text(header?['numVideosText']));
    if (count < 0 && sidebar != null) {
      final stats = sidebar['stats'];
      if (stats is List && stats.isNotEmpty) count = parseCount(text(stats.first));
    }
    if (count < 0) count = items.length;

    var cover = thumb(micro?['thumbnail']);
    if (cover.isEmpty && items.isNotEmpty) cover = items.first['coverHd'] as String;

    return {
      ..._page(
        items,
        _next(page, _Kind.list, accept: (i) => i['type'] == 'video'),
      ),
      'title': title,
      'channel': artistName(channel),
      'channelUrl': channelUrl(channelId),
      'cover': hd(cover),
      'count': count,
    };
  }

  // --------------------------------------------------------------- video

  void _checkUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || !_hosts.contains(uri.host)) {
      throw ArgumentError('Link do YouTube inválido');
    }
  }

  static String _videoId(String url) {
    final uri = Uri.tryParse(url);
    final id =
        uri?.queryParameters['v'] ??
        (uri != null && uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '');
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id)) {
      throw ArgumentError('ID de vídeo inválido');
    }
    return id;
  }

  final _videos = <String, yte.Video>{};

  Future<yte.Video> _video(String id) async {
    final cached = _videos.remove(id);
    final video = cached ?? await _yt.videos.get(id);
    _videos[id] = video;
    while (_videos.length > 30) {
      _videos.remove(_videos.keys.first);
    }
    return video;
  }

  /// Watch-page details: metadata, channel, description and "up next".
  Future<Json> video(String url) async {
    _checkUrl(url);
    final id = _videoId(url);
    final results = await Future.wait<Object?>([
      _tube.post('next', {'videoId': id}),
      _video(id).then<Object?>((v) => v).catchError((Object _) => null),
    ]);
    final next = results[0] as Json;
    final meta = results[1] as yte.Video?;

    final primary = find(next, 'videoPrimaryInfoRenderer');
    final owner = find(next, 'videoOwnerRenderer');
    final secondary = find(next, 'videoSecondaryInfoRenderer');

    final title = meta?.title ?? text(primary?['title']);
    final channel = owner != null ? text(owner['title']) : (meta?.author ?? '');
    var channelId = channelIdIn(owner);
    if (channelId.isEmpty) channelId = meta?.channelId.value ?? '';

    var views = meta?.engagement.viewCount ?? -1;
    if (views <= 0) {
      views = parseCount(text(obj(primary, ['viewCount', 'videoViewCountRenderer', 'viewCount'])));
    }
    var likes = meta?.engagement.likeCount ?? -1;
    if (likes < 0) {
      final like = find(next, 'likeButtonViewModel');
      final label = str(find(like, 'buttonViewModel'), ['accessibilityText']);
      likes = parseCount(label);
    }

    var description = meta?.description ?? '';
    if (description.isEmpty) {
      description = str(secondary, ['attributedDescription', 'content']);
    }
    final uploadedAt = (meta?.uploadDate ?? meta?.publishDate)?.millisecondsSinceEpoch ?? 0;
    var uploaded = text(primary?['relativeDateText']);
    if (uploaded.isEmpty) uploaded = text(primary?['dateText']);

    final related = parseItems(
      obj(next, ['contents', 'twoColumnWatchNextResults', 'secondaryResults']) ?? const {},
    ).where((i) => i['type'] == 'video').toList();

    return {
      'url': 'https://www.youtube.com/watch?v=$id',
      'id': id,
      'title': title,
      'channel': channel,
      'artist': artistName(channel),
      'channelUrl': channelUrl(channelId),
      'channelAvatar': thumbAtLeast(owner?['thumbnail'], 88),
      'subscribers': parseCount(text(owner?['subscriberCountText'])),
      'verified': verifiedBadge(owner?['badges']),
      'views': views,
      'likes': likes,
      'uploaded': uploaded,
      'uploadedAt': uploadedAt,
      'description': description,
      'descriptionHtml': false,
      'cover': 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      'coverHd': meta?.thumbnails.maxResUrl ?? 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      'duration': meta?.duration?.inSeconds ?? 0,
      'live': meta?.isLive ?? false,
      'shorts': false,
      'related': related,
    };
  }

  /// "Up next" items for endless autoplay; live streams and Shorts excluded.
  Future<List<Json>> related(String url) async {
    _checkUrl(url);
    final id = _videoId(url);
    final next = await _tube.post('next', {'videoId': id});
    return parseItems(
          obj(next, ['contents', 'twoColumnWatchNextResults', 'secondaryResults']) ?? const {},
        )
        .where(
          (i) =>
              i['type'] == 'video' &&
              (i['duration'] as int) > 0 &&
              i['shorts'] != true &&
              i['live'] != true,
        )
        .take(20)
        .toList();
  }

  // ------------------------------------------------------------ comments

  Future<Json> comments(String url) async {
    _checkUrl(url);
    final id = _videoId(url);
    final next = await _tube.post('next', {'videoId': id});
    String token = '';
    for (final section in findAll(next, 'itemSectionRenderer')) {
      if (str(section, ['sectionIdentifier']) != 'comment-item-section') continue;
      token = str(find(section, 'continuationCommand'), ['token']);
    }
    if (token.isEmpty) {
      // Engagement panel variant.
      for (final panel in findAll(next, 'engagementPanelSectionListRenderer')) {
        if (!str(panel, ['panelIdentifier']).contains('comment')) continue;
        token = str(find(panel, 'continuationCommand'), ['token']);
        if (token.isNotEmpty) break;
      }
    }
    if (token.isEmpty) {
      return {..._page(const [], null), 'disabled': true};
    }
    final cursor = _Cursor(kind: _Kind.comments, endpoint: 'next', token: token);
    final page = await _continue(cursor);
    final result = _commentsPage(page, cursor);
    final header = find(page, 'commentsHeaderRenderer');
    var count = parseCount(text(header?['countText']));
    if (count < 0) {
      // The total sits in the comments panel header ("2,3 mi").
      for (final panel in findAll(next, 'engagementPanelSectionListRenderer')) {
        if (!str(panel, ['panelIdentifier']).contains('comment')) continue;
        count = parseCount(text(find(panel, 'contextualInfo')));
        if (count >= 0) break;
      }
    }
    return {...result, 'count': count};
  }

  Json _commentsPage(Json page, _Cursor cursor) {
    final entities = <String, Json>{};
    final toolbars = <String, Json>{};
    for (final mutation in findAll(page, 'payload')) {
      final comment = obj(mutation, ['commentEntityPayload']);
      if (comment != null) entities[str(comment, ['key'])] = comment;
      final toolbar = obj(mutation, ['engagementToolbarStateEntityPayload']);
      if (toolbar != null) toolbars[str(toolbar, ['key'])] = toolbar;
    }
    final items = <Json>[];
    for (final thread in findAll(page, 'commentThreadRenderer')) {
      final view = obj(thread, ['commentViewModel', 'commentViewModel']);
      if (view != null) {
        final entity = entities[str(view, ['commentKey'])];
        if (entity == null) continue;
        final toolbar = toolbars[str(view, ['toolbarStateKey'])];
        final props = obj(entity, ['properties']);
        final author = obj(entity, ['author']);
        final bar = obj(entity, ['toolbar']);
        items.add({
          'author': str(author, ['displayName']),
          'avatar': str(author, ['avatarThumbnailUrl']),
          'text': str(props, ['content', 'content']),
          'html': false,
          'likes': parseCount(str(bar, ['likeCountNotliked'])).clamp(0, 1 << 50),
          'uploaded': str(props, ['publishedTime']),
          'pinned': view['pinnedText'] != null,
          'hearted': str(toolbar, ['heartState']) == 'TOOLBAR_HEART_STATE_HEARTED',
          'replies': parseCount(str(bar, ['replyCount'])).clamp(0, 1 << 30),
        });
        continue;
      }
      // Legacy renderer.
      final legacy = find(thread, 'commentRenderer');
      if (legacy == null) continue;
      items.add({
        'author': text(legacy['authorText']),
        'avatar': thumbAtLeast(legacy['authorThumbnail'], 48),
        'text': text(legacy['contentText']),
        'html': false,
        'likes': parseCount(text(legacy['voteCount'])).clamp(0, 1 << 50),
        'uploaded': text(legacy['publishedTimeText']),
        'pinned': legacy['pinnedCommentBadge'] != null,
        'hearted': legacy['creatorHeart'] != null,
        'replies': (legacy['replyCount'] as num?)?.toInt() ?? 0,
      });
    }
    // The reply-thread continuation sits inside each thread; only the list
    // continuation (outside threads) pages the comments.
    String nextToken = '';
    walk(page, (key, node) {
      if (key == 'commentThreadRenderer') return true;
      if (key == 'continuationItemRenderer' && nextToken.isEmpty) {
        nextToken = str(find(node, 'continuationCommand'), ['token']);
      }
      return false;
    });
    return _page(
      items,
      nextToken.isEmpty
          ? null
          : _Cursor(kind: _Kind.comments, endpoint: 'next', token: nextToken),
    );
  }

  // ------------------------------------------------------------- streams

  /// Playable URLs. Audio mode returns one stream; video mode prefers a
  /// separate video-only track (up to [maxHeight]) plus an `audio` track,
  /// which is how YouTube serves anything above 360p.
  /// (media playlist, audio playlist or null when muxed, height) from a live
  /// HLS master. Audio mode returns the best audio group alone.
  Future<(String, String?, int)?> _liveRendition(String master, int maxHeight, bool video) async {
    final res = await _http.get(Uri.parse(master)).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final base = Uri.parse(master);
    final audioGroups = <String, String>{};
    final variants = <({String url, int height, int bandwidth, String? audio})>[];
    String? pending;
    for (final raw in const LineSplitter().convert(res.body)) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-MEDIA:') && line.contains('TYPE=AUDIO')) {
        final uri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
        final group = RegExp(r'GROUP-ID="([^"]+)"').firstMatch(line)?.group(1);
        if (uri != null && group != null) audioGroups[group] = base.resolve(uri).toString();
      } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pending = line;
      } else if (line.isNotEmpty && !line.startsWith('#') && pending != null) {
        variants.add((
          url: base.resolve(line).toString(),
          height: int.tryParse(RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(pending)?.group(1) ?? '') ?? 0,
          bandwidth: int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(pending)?.group(1) ?? '') ?? 0,
          audio: RegExp(r'AUDIO="([^"]+)"').firstMatch(pending)?.group(1),
        ));
        pending = null;
      }
    }
    if (variants.isEmpty) return null;
    final withAudio = variants.where((v) => v.audio != null && audioGroups.containsKey(v.audio)).toList()
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    if (!video) {
      final audio = withAudio.isEmpty ? null : audioGroups[withAudio.first.audio];
      if (audio != null) return (audio, null, 0);
      final lowest = [...variants]..sort((a, b) => a.bandwidth.compareTo(b.bandwidth));
      return (lowest.first.url, null, 0);
    }
    final fitting = variants.where((v) => v.height > 0 && v.height <= maxHeight).toList()
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    final pick = fitting.isNotEmpty ? fitting.first : (([...variants]..sort((a, b) => a.height.compareTo(b.height))).first);
    return (pick.url, pick.audio == null ? null : audioGroups[pick.audio], pick.height);
  }

  Future<Json> resolve(String url, {required bool video, int maxHeight = 1080}) async {
    _checkUrl(url);
    final id = _videoId(url);
    final meta = await _video(id);
    final result = <String, dynamic>{
      'url': url,
      'title': meta.title,
      'artist': artistName(meta.author),
      'cover': meta.thumbnails.maxResUrl,
      'duration': meta.duration?.inSeconds ?? 0,
    };
    if (meta.isLive) {
      final hls = await _yt.videos.streamsClient.getHttpLiveStreamUrl(meta.id);
      // One rendition + its audio group: the master makes the player open
      // every rendition in parallel and a single refused one stops playback.
      try {
        final pick = await _liveRendition(hls, maxHeight, video);
        if (pick != null) {
          return {...result, 'stream': pick.$1, 'audio': ?pick.$2, 'height': pick.$3, 'live': true};
        }
      } catch (_) {}
      return {...result, 'stream': hls, 'height': 0, 'live': true};
    }
    final manifest = await manifestFor(id);
    final audio = bestAudio(manifest);
    if (!video) {
      if (audio == null) throw StateError('Áudio indisponível para este conteúdo.');
      return {...result, 'stream': audio.url.toString()};
    }
    final videoOnly = bestVideoOnly(manifest, maxHeight);
    final muxed = manifest.muxed.isEmpty
        ? null
        : (manifest.muxed.toList()
                ..sort((a, b) => a.videoResolution.height.compareTo(b.videoResolution.height)))
              .last;
    final muxedHeight = muxed?.videoResolution.height ?? 0;
    if (videoOnly != null && audio != null && videoOnly.videoResolution.height > muxedHeight) {
      return {
        ...result,
        'stream': videoOnly.url.toString(),
        'audio': audio.url.toString(),
        'height': videoOnly.videoResolution.height,
      };
    }
    if (muxed != null) {
      return {...result, 'stream': muxed.url.toString(), 'height': muxedHeight};
    }
    throw StateError('Vídeo indisponível; tente o modo áudio.');
  }

  /// Manifest from clients that return direct (unciphered) URLs.
  Future<yte.StreamManifest> manifestFor(String id) =>
      _yt.videos.streamsClient.getManifest(
        id,
        ytClients: [yte.YoutubeApiClient.androidVr, yte.YoutubeApiClient.ios],
      );

  /// M4A first (plays everywhere and can be muxed into MP4), then bitrate.
  static yte.AudioOnlyStreamInfo? bestAudio(yte.StreamManifest manifest) {
    final audio = manifest.audioOnly.where((s) {
      final track = s.audioTrack;
      return track == null || track.audioIsDefault;
    }).toList();
    if (audio.isEmpty) return null;
    final m4a = audio.where((s) => s.container == yte.StreamContainer.mp4).toList();
    final pool = m4a.isNotEmpty ? m4a : audio;
    pool.sort((a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));
    return pool.last;
  }

  /// Highest video-only track up to [maxHeight]; H.264/MP4 wins ties.
  /// [mp4Only] restricts to MP4 (needed to mux downloads with AVFoundation).
  static yte.VideoOnlyStreamInfo? bestVideoOnly(
    yte.StreamManifest manifest,
    int maxHeight, {
    bool mp4Only = false,
  }) {
    final candidates = manifest.videoOnly.where((s) {
      final h = s.videoResolution.height;
      if (h <= 0 || h > maxHeight) return false;
      return !mp4Only || s.container == yte.StreamContainer.mp4;
    }).toList();
    if (candidates.isEmpty) return null;
    int score(yte.VideoOnlyStreamInfo s) =>
        s.videoResolution.height * 1000 +
        (s.container == yte.StreamContainer.mp4 ? 500 : 0) +
        s.framerate.framesPerSecond.round();
    candidates.sort((a, b) => score(a).compareTo(score(b)));
    return candidates.last;
  }

  Future<yte.Video> metadata(String id) => _video(id);

  // -------------------------------------------------------------- lyrics

  /// Same rules as `Catalog.lyrics` (Kotlin, Android phone and watch):
  /// YouTube tags stripped from the title, " - Topic" from the channel, and
  /// LRCLIB's best search hit when the exact match misses.
  Future<Json> lyrics(String title, String artist) async {
    final query = {'track_name': lyricsTitle(title), 'artist_name': artistName(artist)};
    const headers = {'User-Agent': 'Ultratube/1.0'};
    final exact = await _http
        .get(Uri.https('lrclib.net', '/api/get', query), headers: headers)
        .timeout(const Duration(seconds: 30));
    if (exact.statusCode == 200) return await InnerTube.decodeJson(exact.bodyBytes);
    if (exact.statusCode != 404) {
      throw StateError('Não foi possível carregar a letra (${exact.statusCode})');
    }
    final search = await _http
        .get(Uri.https('lrclib.net', '/api/search', query), headers: headers)
        .timeout(const Duration(seconds: 30));
    if (search.statusCode == 200) {
      final hits = jsonDecode(utf8.decode(search.bodyBytes));
      if (hits is List && hits.isNotEmpty) return Map<String, dynamic>.from(hits.first as Map);
    }
    return {'plainLyrics': 'Letra não encontrada para esta faixa.'};
  }

  /// "Song (Official Music Video) [4K]" → "Song".
  static String lyricsTitle(String title) => title
      .replaceAll(
        RegExp(
          r'\s*[(\[][^)\]]*(official|video|lyric|letra|audio|áudio|clipe|visualizer|4k|hd)[^)\]]*[)\]]',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
}

enum _Kind { list, comments }

class _Cursor {
  const _Cursor({
    required this.kind,
    required this.endpoint,
    required this.token,
    this.legacy = false,
    this.music = false,
    this.accept,
    this.shelves = false,
  });
  final _Kind kind;
  final String endpoint;
  final String token;
  final bool legacy;
  final bool music;
  final bool Function(Json item)? accept;
  final bool shelves;
}
