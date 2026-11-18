import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

/// Decoded InnerTube JSON object.
typedef Json = Map<String, dynamic>;

class InnerTubeException implements Exception {
  const InnerTubeException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// Minimal client for YouTube's own web API (`/youtubei/v1`), the same one
/// youtube.com and NewPipe use. No API key, account or ads.
class InnerTube {
  InnerTube({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const origin = 'https://www.youtube.com';
  static const musicOrigin = 'https://music.youtube.com';
  static const webVersion = '2.20251114.01.00';
  static const musicVersion = '1.20251110.03.00';
  static const desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// `(hl, gl)` from the device locale, Brazilian Portuguese as fallback.
  static (String, String) get locale {
    final match = RegExp(
      r'^([a-zA-Z]{2,3})(?:[_-]([a-zA-Z]{2}))?',
    ).firstMatch(Platform.localeName);
    final hl = (match?.group(1) ?? 'pt').toLowerCase();
    final gl = (match?.group(2) ?? 'BR').toUpperCase();
    return (hl, gl);
  }

  static Json context({bool music = false}) {
    final (hl, gl) = locale;
    return {
      'client': {
        'clientName': music ? 'WEB_REMIX' : 'WEB',
        'clientVersion': music ? musicVersion : webVersion,
        'hl': hl,
        'gl': gl,
        'userAgent': desktopUa,
      },
    };
  }

  /// POSTs to `/youtubei/v1/[endpoint]`. [onResponse] sees the raw reply
  /// first (used by the account to keep rotated cookies).
  Future<Json> post(
    String endpoint,
    Json body, {
    bool music = false,
    Map<String, String> headers = const {},
    Map<String, String> query = const {},
    void Function(http.Response response)? onResponse,
  }) async {
    final host = music ? musicOrigin : origin;
    final uri = Uri.parse(
      '$host/youtubei/v1/$endpoint',
    ).replace(queryParameters: {'prettyPrint': 'false', ...query});
    final response = await _http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': desktopUa,
            'Origin': host,
            'X-Origin': host,
            'Referer': '$host/',
            'X-Youtube-Client-Name': music ? '67' : '1',
            'X-Youtube-Client-Version': music ? musicVersion : webVersion,
            ...headers,
          },
          body: jsonEncode({...body, 'context': context(music: music)}),
        )
        .timeout(const Duration(seconds: 30));
    onResponse?.call(response);
    if (response.statusCode != 200) {
      throw InnerTubeException(
        'YouTube respondeu ${response.statusCode}',
        status: response.statusCode,
      );
    }
    return decodeJson(response.bodyBytes);
  }

  Future<http.Response> get(Uri uri, {Map<String, String> headers = const {}}) =>
      _http
          .get(uri, headers: {'User-Agent': desktopUa, ...headers})
          .timeout(const Duration(seconds: 30));

  /// Large pages (1–2 MB) are decoded off the UI isolate.
  static Future<Json> decodeJson(List<int> bytes) async {
    final Object? decoded = bytes.length > 150 * 1024
        ? await Isolate.run(() => jsonDecode(utf8.decode(bytes)))
        : jsonDecode(utf8.decode(bytes));
    return decoded is Json ? decoded : <String, dynamic>{};
  }
}

// ----------------------------------------------------------------- walking

/// Depth-first walk; [visit] returns true to skip the node's children.
void walk(Object? node, bool Function(String key, Json node) visit) {
  if (node is Json) {
    for (final entry in node.entries) {
      final child = entry.value;
      if (child is Json && visit(entry.key, child)) continue;
      walk(child, visit);
    }
  } else if (node is List) {
    for (final child in node) {
      walk(child, visit);
    }
  }
}

/// First object stored under [name], anywhere below [node].
Json? find(Object? node, String name) {
  Json? found;
  walk(node, (key, child) {
    if (found != null) return true;
    if (key == name) {
      found = child;
      return true;
    }
    return false;
  });
  return found;
}

/// Every object stored under [name] (not nested in one another).
List<Json> findAll(Object? node, String name) {
  final out = <Json>[];
  walk(node, (key, child) {
    if (key == name) {
      out.add(child);
      return true;
    }
    return false;
  });
  return out;
}

/// Follows a path of keys (String) and indexes (int).
Object? at(Object? node, List<Object> path) {
  var current = node;
  for (final step in path) {
    if (step is String && current is Map) {
      current = current[step];
    } else if (step is int && current is List && step < current.length) {
      current = current[step];
    } else {
      return null;
    }
  }
  return current;
}

Json? obj(Object? node, [List<Object> path = const []]) {
  final value = at(node, path);
  return value is Json ? value : null;
}

String str(Object? node, [List<Object> path = const []]) {
  final value = at(node, path);
  return value is String ? value : (value is num ? '$value' : '');
}

/// The continuation token of a list page: `(token, legacy)`. Legacy tokens
/// (YouTube Music) go in the query string instead of the body.
(String, bool)? continuation(Object? page) {
  final command = find(page, 'continuationCommand');
  final token = str(command, ['token']);
  if (token.isNotEmpty) return (token, false);
  final legacy = str(find(page, 'nextContinuationData'), ['continuation']);
  if (legacy.isNotEmpty) return (legacy, true);
  return null;
}

// ------------------------------------------------------------------ values

/// Plain text of `{simpleText}`, `{content}` or `{runs: [...]}`.
String text(Object? node) {
  if (node is String) return node;
  if (node is! Json) return '';
  final simple = node['simpleText'];
  if (simple is String && simple.isNotEmpty) return simple;
  final content = node['content'];
  if (content is String && content.isNotEmpty) return content;
  final runs = node['runs'];
  if (runs is! List) return '';
  return runs.map((r) => r is Json ? str(r, ['text']) : '').join();
}

String https(String url) => url.startsWith('//') ? 'https:$url' : url;

List<Json> _images(Object? node) {
  if (node is! Json) return const [];
  final list = node['thumbnails'] ?? node['sources'];
  if (list is! List) {
    // `{thumbnail: {thumbnails: [...]}}` and `{image: {sources: [...]}}`.
    final inner = node['thumbnail'] ?? node['image'];
    return inner is Json ? _images(inner) : const [];
  }
  return [for (final t in list) if (t is Json && str(t, ['url']).isNotEmpty) t];
}

int _width(Json image) => (image['width'] as num?)?.toInt() ?? 0;

/// Largest image of a thumbnails/sources node.
String thumb(Object? node) {
  final images = _images(node);
  if (images.isEmpty) return '';
  var best = images.first;
  for (final image in images) {
    if (_width(image) >= _width(best)) best = image;
  }
  return https(str(best, ['url']));
}

/// Smallest image at least [width] wide, else the largest one.
String thumbAtLeast(Object? node, int width) {
  final images = _images(node);
  if (images.isEmpty) return '';
  Json? fit;
  for (final image in images) {
    final w = _width(image);
    if (w >= width && (fit == null || w < _width(fit))) fit = image;
  }
  return fit == null ? thumb(node) : https(str(fit, ['url']));
}

/// First `{sources|thumbnails}` image found anywhere below [node].
String firstImage(Object? node, {int? width}) {
  String found = '';
  walk(node, (key, child) {
    if (found.isNotEmpty) return true;
    if (child['sources'] is List || child['thumbnails'] is List) {
      found = width == null ? thumb(child) : thumbAtLeast(child, width);
      return found.isNotEmpty;
    }
    return false;
  });
  return found;
}

/// Full-resolution variant: YouTube Music art (googleusercontent/ggpht) is
/// served at whatever size the URL asks for, usually 60–120 px.
String hd(String url, [int size = 1080]) {
  if (url.isEmpty) return url;
  if (!url.contains('googleusercontent.com') && !url.contains('ggpht.com')) {
    return url;
  }
  return url
      .replaceAll(RegExp(r'=w\d+-h\d+[^/]*$'), '=w$size-h$size-l90-rj')
      .replaceAll(RegExp(r'=s\d+[^/]*$'), '=s$size');
}

/// "3:45" / "1:02:03" → seconds; anything else → 0.
int seconds(String label) {
  final value = label.trim();
  if (!RegExp(r'^\d+(:\d{1,2}){1,2}$').hasMatch(value)) return 0;
  return value.split(':').fold(0, (acc, part) => acc * 60 + int.parse(part));
}

/// "1.234.567 visualizações", "1,2 mi de inscritos", "12K views" → number.
/// -1 when the text has no number.
int parseCount(String label) {
  final value = label.replaceAll(' ', ' ').replaceAll(' ', ' ');
  final lower = value.toLowerCase();
  if (RegExp(r'^\s*(nenhum|no |sem )').hasMatch(lower)) return 0;
  final match = RegExp(
    r'(\d[\d.,]*)\s*(milh(?:ão|ões|ao|oes)|bilh(?:ão|ões|ao|oes)|mil|mi|bi|mn|k|m|b|thousand|millions?|billions?)?(?![a-zA-Zà-ú])',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return -1;
  final number = match.group(1)!;
  final unit = match.group(2)?.toLowerCase();
  if (unit == null) {
    return int.tryParse(number.replaceAll(RegExp(r'[.,]'), '')) ?? -1;
  }
  final decimal = double.tryParse(number.replaceAll(',', '.')) ?? 0;
  final double factor;
  if (unit == 'mil' || unit == 'k' || unit == 'thousand') {
    factor = 1e3;
  } else if (unit.startsWith('milh') ||
      unit.startsWith('million') ||
      unit == 'mi' ||
      unit == 'mn' ||
      unit == 'm') {
    factor = 1e6;
  } else {
    factor = 1e9;
  }
  return (decimal * factor).round();
}

/// "há 3 dias" / "3 days ago" → approximate epoch millis; 0 when unknown.
int relativeTime(String label) {
  final match = RegExp(
    r'(\d+)\s*(segundo|second|minuto|minute|hora|hour|dia|day|semana|week|m[eê]s|meses|month|ano|year)',
    caseSensitive: false,
  ).firstMatch(label);
  if (match == null) return 0;
  final n = int.parse(match.group(1)!);
  final unit = match.group(2)!.toLowerCase();
  final Duration span;
  if (unit.startsWith('seg') || unit.startsWith('sec')) {
    span = Duration(seconds: n);
  } else if (unit.startsWith('min')) {
    span = Duration(minutes: n);
  } else if (unit.startsWith('hor') || unit.startsWith('hour')) {
    span = Duration(hours: n);
  } else if (unit.startsWith('dia') || unit.startsWith('day')) {
    span = Duration(days: n);
  } else if (unit.startsWith('sem') || unit.startsWith('week')) {
    span = Duration(days: 7 * n);
  } else if (unit.startsWith('m')) {
    span = Duration(days: 30 * n);
  } else {
    span = Duration(days: 365 * n);
  }
  return DateTime.now().subtract(span).millisecondsSinceEpoch;
}

/// YouTube's auto-generated music channels are named "`<Artist> - Topic`".
String artistName(String uploader) =>
    uploader.replaceAll(RegExp(r'\s+-\s+(Topic|Tópico)$'), '').trim();

/// First channel id (UC…) linked below [node].
String channelIdIn(Object? node) {
  var id = '';
  walk(node, (key, child) {
    if (id.isNotEmpty) return true;
    if (key == 'browseEndpoint') {
      final browseId = str(child, ['browseId']);
      if (browseId.startsWith('UC')) id = browseId;
    }
    return false;
  });
  return id;
}

String channelUrl(String id) =>
    id.isEmpty ? '' : 'https://www.youtube.com/channel/$id';

bool verifiedBadge(Object? badges) {
  if (badges == null) return false;
  final raw = jsonEncode(badges);
  // Official artist channels carry a music-note badge instead of the check.
  return raw.contains('VERIFIED') ||
      raw.contains('CHECK_CIRCLE') ||
      raw.contains('AUDIO_BADGE') ||
      raw.contains('OFFICIAL_ARTIST');
}

// ------------------------------------------------------------------- items

Json videoItem({
  required String id,
  required String title,
  String channel = '',
  String channelId = '',
  String avatar = '',
  String cover = '',
  String coverHd = '',
  int duration = 0,
  int views = -1,
  String uploaded = '',
  int uploadedAt = 0,
  bool shorts = false,
  bool verified = false,
  bool live = false,
  String? artist,
}) {
  final fallback = 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
  final isShort =
      shorts ||
      (duration > 0 &&
          duration <= 180 &&
          title.toLowerCase().contains('#short'));
  return {
    'type': 'video',
    'url': 'https://www.youtube.com/watch?v=$id',
    'title': title,
    'artist': artist ?? artistName(channel),
    'channel': channel,
    'channelUrl': channelUrl(channelId),
    'channelAvatar': avatar,
    'cover': cover.isEmpty ? fallback : cover,
    'coverHd': coverHd.isNotEmpty ? coverHd : (cover.isEmpty ? fallback : cover),
    'duration': duration,
    'views': views,
    'uploaded': uploaded,
    'uploadedAt': uploadedAt != 0 ? uploadedAt : relativeTime(uploaded),
    'shorts': isShort,
    'verified': verified,
    'live': live,
  };
}

Json _fromVideoRenderer(Json n) {
  final id = str(n, ['videoId']);
  final owner =
      obj(n, ['ownerText']) ??
      obj(n, ['longBylineText']) ??
      obj(n, ['shortBylineText']);
  final overlays = n['thumbnailOverlays'];
  final overlayRaw = overlays == null ? '' : jsonEncode(overlays);
  var duration = seconds(text(n['lengthText']));
  if (duration == 0) duration = int.tryParse(str(n, ['lengthSeconds'])) ?? 0;
  final shorts =
      overlayRaw.contains('"SHORTS"') ||
      jsonEncode(n['navigationEndpoint'] ?? const {}).contains('reelWatchEndpoint');
  final badgesRaw = jsonEncode(n['badges'] ?? const []);
  final live =
      badgesRaw.contains('LIVE') ||
      overlayRaw.contains('"LIVE"') ||
      text(n['viewCountText']).toLowerCase().contains('assistindo') ||
      text(n['viewCountText']).toLowerCase().contains('watching');
  final avatarNode =
      obj(n, [
        'channelThumbnailSupportedRenderers',
        'channelThumbnailWithLinkRenderer',
        'thumbnail',
      ]) ??
      obj(n, ['channelThumbnail']);
  var views = parseCount(text(n['viewCountText']));
  if (views < 0) views = parseCount(text(n['shortViewCountText']));
  var uploaded = text(n['publishedTimeText']);
  final info = n['videoInfo'];
  if (info != null) {
    // Playlist rows: "1,2 mi de visualizações • há 3 anos".
    final runs = [for (final r in (info['runs'] as List? ?? const [])) str(r, ['text'])]
        .where((t) => t.trim().isNotEmpty && t.trim() != '•')
        .toList();
    if (views < 0 && runs.isNotEmpty) views = parseCount(runs.first);
    if (uploaded.isEmpty && runs.length > 1) uploaded = runs.last;
  }
  return videoItem(
    id: id,
    title: text(n['title']),
    channel: text(owner),
    channelId: channelIdIn(owner),
    avatar: thumbAtLeast(avatarNode, 68),
    cover: thumbAtLeast(n['thumbnail'], shorts ? 400 : 480),
    coverHd: thumb(n['thumbnail']),
    duration: duration,
    views: views,
    uploaded: uploaded,
    shorts: shorts,
    verified: verifiedBadge(n['ownerBadges']),
    live: live,
  );
}

Json? _fromLockup(Json n) {
  final id = str(n, ['contentId']);
  final type = str(n, ['contentType']);
  final meta = obj(n, ['metadata', 'lockupMetadataViewModel']);
  final parts = <String>[];
  walk(meta?['metadata'], (key, child) {
    if (key == 'text' && child['content'] is String) {
      parts.add(child['content'] as String);
    }
    return false;
  });
  final title = text(meta?['title']);
  final image = n['contentImage'];
  final channelId = channelIdIn(meta);
  if (type == 'LOCKUP_CONTENT_TYPE_VIDEO' && id.length == 11) {
    var duration = 0;
    var live = false;
    walk(image, (key, child) {
      if (key == 'thumbnailBadgeViewModel') {
        final label = str(child, ['text']);
        if (seconds(label) > 0) duration = seconds(label);
        if (str(child, ['badgeStyle']).contains('LIVE')) live = true;
      }
      return false;
    });
    final viewsPattern = RegExp(
      r'visualiza|views|assistindo|watching',
      caseSensitive: false,
    );
    final viewsIndex = parts.indexWhere(viewsPattern.hasMatch);
    final uploaded = parts.lastWhere(
      (p) => relativeTime(p) != 0,
      orElse: () => '',
    );
    // Channel tabs omit the owner: the first part is then the view count.
    final owner = parts.firstWhere(
      (p) =>
          p != title &&
          p.trim() != '•' &&
          !viewsPattern.hasMatch(p) &&
          relativeTime(p) == 0,
      orElse: () => '',
    );
    final cover = obj(image, ['thumbnailViewModel', 'image']);
    return videoItem(
      id: id,
      title: title,
      channel: owner,
      channelId: channelId,
      avatar: firstImage(meta?['image'], width: 68),
      cover: thumbAtLeast(cover, 480),
      coverHd: thumb(cover),
      duration: duration,
      views: viewsIndex >= 0 ? parseCount(parts[viewsIndex]) : -1,
      uploaded: uploaded,
      verified: verifiedBadge(meta?['metadata']),
      live: live,
    );
  }
  if ((type == 'LOCKUP_CONTENT_TYPE_PLAYLIST' ||
          type == 'LOCKUP_CONTENT_TYPE_PODCAST') &&
      id.isNotEmpty) {
    var count = -1;
    walk(image, (key, child) {
      if (key == 'thumbnailBadgeViewModel' && count < 0) {
        count = parseCount(str(child, ['text']));
      }
      return false;
    });
    final cover = firstImage(image, width: 480);
    return {
      'type': 'playlist',
      'url': 'https://www.youtube.com/playlist?list=$id',
      'title': title,
      'cover': cover,
      'coverHd': hd(firstImage(image)),
      'channel': parts.isNotEmpty ? parts.first : '',
      'channelUrl': channelUrl(channelId),
      'videos': count,
    };
  }
  return null;
}

Json? _fromShortsLockup(Json n) {
  final id = str(find(n, 'reelWatchEndpoint'), ['videoId']);
  if (id.length != 11) return null;
  final overlay = obj(n, ['overlayMetadata']);
  return videoItem(
    id: id,
    title: text(overlay?['primaryText']),
    views: parseCount(text(overlay?['secondaryText'])),
    cover: thumbAtLeast(n['thumbnail'], 400),
    coverHd: thumb(n['thumbnail']),
    shorts: true,
  );
}

Json _fromReel(Json n) => videoItem(
  id: str(n, ['videoId']),
  title: text(n['headline']),
  views: parseCount(text(n['viewCountText'])),
  cover: thumbAtLeast(n['thumbnail'], 400),
  coverHd: thumb(n['thumbnail']),
  shorts: true,
);

Json _fromChannel(Json n) {
  final id = str(n, ['channelId']);
  // Since 2024 search shows the handle in subscriberCountText and the
  // subscriber count in videoCountText.
  var subscribers = -1;
  for (final field in ['subscriberCountText', 'videoCountText']) {
    final label = text(n[field]);
    if (RegExp(r'inscrit|subscriber', caseSensitive: false).hasMatch(label)) {
      subscribers = parseCount(label);
    }
  }
  return {
    'type': 'channel',
    'url': channelUrl(id),
    'title': text(n['title']),
    'cover': thumbAtLeast(n['thumbnail'], 176),
    'subscribers': subscribers,
    'videos': -1,
    'description': text(n['descriptionSnippet']),
  };
}

Json _fromPlaylist(Json n) {
  final id = str(n, ['playlistId']);
  final thumbs = n['thumbnails'] is List && (n['thumbnails'] as List).isNotEmpty
      ? (n['thumbnails'] as List).first
      : n['thumbnail'];
  final owner = obj(n, ['shortBylineText']) ?? obj(n, ['longBylineText']);
  var count = int.tryParse(str(n, ['videoCount'])) ?? -1;
  if (count < 0) count = parseCount(text(n['videoCountText']));
  if (count < 0) count = parseCount(text(n['videoCountShortText']));
  return {
    'type': 'playlist',
    'url': 'https://www.youtube.com/playlist?list=$id',
    'title': text(n['title']),
    'cover': thumbAtLeast(thumbs, 480),
    'coverHd': hd(thumb(thumbs)),
    'channel': text(owner),
    'channelUrl': channelUrl(channelIdIn(owner)),
    'videos': count,
  };
}

/// Every video/channel/playlist below [page], de-duplicated, in page order.
/// Shorts shelves are included only with [shelves]; ads are always skipped.
List<Json> parseItems(Object? page, {bool shelves = false}) {
  final out = <String, Json>{};
  void add(Json? item) {
    if (item == null) return;
    final url = item['url'] as String? ?? '';
    if (url.isEmpty || url.endsWith('v=') || url.endsWith('list=')) return;
    out.putIfAbsent(url, () => item);
  }

  walk(page, (key, node) {
    switch (key) {
      case 'videoRenderer':
      case 'gridVideoRenderer':
      case 'compactVideoRenderer':
      case 'playlistVideoRenderer':
      case 'playlistPanelVideoRenderer':
        if (str(node, ['videoId']).length == 11) add(_fromVideoRenderer(node));
        return true;
      case 'lockupViewModel':
        add(_fromLockup(node));
        return true;
      case 'shortsLockupViewModel':
        add(_fromShortsLockup(node));
        return true;
      case 'reelItemRenderer':
        if (str(node, ['videoId']).length == 11) add(_fromReel(node));
        return true;
      case 'channelRenderer':
      case 'gridChannelRenderer':
        if (str(node, ['channelId']).startsWith('UC')) add(_fromChannel(node));
        return true;
      case 'playlistRenderer':
      case 'gridPlaylistRenderer':
        if (str(node, ['playlistId']).isNotEmpty) add(_fromPlaylist(node));
        return true;
      case 'reelShelfRenderer':
        return !shelves;
      case 'richShelfRenderer':
        return !shelves && jsonEncode(node).contains('reelWatchEndpoint');
      case 'adSlotRenderer':
      case 'promotedSparklesWebRenderer':
      case 'searchPyvRenderer':
      case 'promotedVideoRenderer':
      case 'movieRenderer':
        return true;
      default:
        return false;
    }
  });
  return out.values.toList();
}

// -------------------------------------------------------------- music items

/// Songs, videos, albums, playlists and artists of a YouTube Music page.
List<Json> parseMusicItems(Object? page) {
  final out = <String, Json>{};
  walk(page, (key, node) {
    if (key != 'musicResponsiveListItemRenderer' &&
        key != 'musicTwoRowItemRenderer') {
      return false;
    }
    final item = _fromMusic(node);
    if (item != null) out.putIfAbsent(item['url'] as String, () => item);
    return true;
  });
  return out.values.toList();
}

Json? _fromMusic(Json n) {
  final columns = [
    for (final c in (n['flexColumns'] as List? ?? const []))
      obj(c, ['musicResponsiveListItemFlexColumnRenderer', 'text']),
  ];
  final title = columns.isNotEmpty ? text(columns.first) : text(n['title']);
  final subtitleNode = columns.length > 1 ? columns[1] : obj(n, ['subtitle']);
  final runs = [
    for (final r in (subtitleNode?['runs'] as List? ?? const []))
      if (r is Json) r,
  ];
  final parts = [
    for (final r in runs)
      if (str(r, ['text']).trim().isNotEmpty && str(r, ['text']).trim() != '•') r,
  ];
  final artists = [
    for (final r in parts)
      if (str(r, ['navigationEndpoint', 'browseEndpoint', 'browseId']).startsWith('UC'))
        r,
  ];
  final artist = artists.isNotEmpty
      ? artists.map((r) => str(r, ['text'])).join(', ')
      : (parts.isNotEmpty ? str(parts.first, ['text']) : '');
  final artistId = artists.isNotEmpty
      ? str(artists.first, ['navigationEndpoint', 'browseEndpoint', 'browseId'])
      : '';
  final art = thumb(n['thumbnail'] ?? n['thumbnailRenderer']);
  final cover = hd(art, 544);
  final coverHd = hd(art);

  final videoId = str(find(n, 'watchEndpoint'), ['videoId']).isNotEmpty
      ? str(find(n, 'watchEndpoint'), ['videoId'])
      : str(n, ['playlistItemData', 'videoId']);
  final browseId = str(n, ['navigationEndpoint', 'browseEndpoint', 'browseId']);

  if (browseId.startsWith('UC')) {
    final subs = parts
        .map((r) => str(r, ['text']))
        .firstWhere(
          (t) => RegExp(r'inscrit|subscriber', caseSensitive: false).hasMatch(t),
          orElse: () => '',
        );
    return {
      'type': 'channel',
      'url': channelUrl(browseId),
      'title': title,
      'cover': hd(art, 176),
      'subscribers': parseCount(subs),
      'videos': -1,
      'description': '',
    };
  }
  if (browseId.startsWith('MPRE') || browseId.startsWith('VL')) {
    // Albums open as their OLAK5uy_ playlist; community playlists as VL….
    var listId = browseId.startsWith('VL') ? browseId.substring(2) : '';
    if (listId.isEmpty) {
      walk(n, (key, child) {
        final id = str(child, ['playlistId']);
        if (listId.isEmpty && id.startsWith('OLAK5uy_')) listId = id;
        return listId.isNotEmpty;
      });
    }
    if (listId.isEmpty) return null;
    return {
      'type': 'playlist',
      'url': 'https://www.youtube.com/playlist?list=$listId',
      'title': title,
      'cover': cover,
      'coverHd': coverHd,
      'channel': artist,
      'channelUrl': channelUrl(artistId),
      'videos': -1,
    };
  }
  if (videoId.length != 11) return null;
  final texts = parts.map((r) => str(r, ['text'])).toList();
  final duration = texts.map(seconds).lastWhere((s) => s > 0, orElse: () => 0);
  final views = texts.firstWhere(
    (t) => RegExp(r'visualiza|views|reprodu|plays', caseSensitive: false).hasMatch(t),
    orElse: () => '',
  );
  return videoItem(
    id: videoId,
    title: title,
    channel: artist,
    channelId: artistId,
    artist: artist,
    cover: cover,
    coverHd: coverHd,
    duration: duration,
    views: parseCount(views),
  );
}
