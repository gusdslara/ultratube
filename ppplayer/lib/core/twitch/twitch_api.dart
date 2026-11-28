import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

// Pure Dart (no Flutter imports) so the proxy and API can be exercised from
// a plain `dart` script as well as from the app.

/// A live broadcast as listed in directories and search.
class TwitchStream {
  const TwitchStream({
    required this.login,
    required this.displayName,
    required this.title,
    required this.viewers,
    this.avatar = '',
    this.preview = '',
    this.game = '',
    this.gameBox = '',
    this.startedAt,
    this.tags = const [],
  });

  factory TwitchStream.fromNode(Map node) {
    final b = node['broadcaster'] as Map? ?? const {};
    final g = node['game'] as Map?;
    return TwitchStream(
      login: b['login'] as String? ?? '',
      displayName: b['displayName'] as String? ?? b['login'] as String? ?? '',
      avatar: b['profileImageURL'] as String? ?? '',
      title: node['title'] as String? ?? '',
      viewers: (node['viewersCount'] as num?)?.toInt() ?? 0,
      preview: node['previewImageURL'] as String? ?? '',
      game: g?['displayName'] as String? ?? '',
      gameBox: g?['boxArtURL'] as String? ?? '',
      startedAt: DateTime.tryParse(node['createdAt'] as String? ?? ''),
      tags: [for (final t in (node['freeformTags'] as List? ?? const [])) (t as Map)['name'] as String? ?? ''],
    );
  }

  final String login;
  final String displayName;
  final String title;
  final int viewers;
  final String avatar;
  final String preview;
  final String game;
  final String gameBox;
  final DateTime? startedAt;
  final List<String> tags;

  /// Preview with a cache-busting minute so thumbnails stay fresh.
  String previewAt(int width, int height) {
    final base = preview.isNotEmpty ? preview : 'https://static-cdn.jtvnw.net/previews-ttv/live_user_$login-{width}x{height}.jpg';
    final url = base.replaceAll(RegExp(r'-\d+x\d+\.jpg'), '-${width}x$height.jpg').replaceAll('{width}', '$width').replaceAll('{height}', '$height');
    return '$url?t=${DateTime.now().millisecondsSinceEpoch ~/ 300000}';
  }
}

class TwitchGame {
  const TwitchGame({
    required this.id,
    required this.name,
    required this.displayName,
    this.boxArt = '',
    this.viewers = -1,
    this.followers = -1,
    this.tags = const [],
  });
  factory TwitchGame.fromNode(Map n) => TwitchGame(
    id: n['id'] as String? ?? '',
    name: n['name'] as String? ?? '',
    displayName: n['displayName'] as String? ?? n['name'] as String? ?? '',
    boxArt: n['boxArtURL'] as String? ?? '',
    viewers: (n['viewersCount'] as num?)?.toInt() ?? -1,
    followers: (n['followersCount'] as num?)?.toInt() ?? -1,
    tags: [
      for (final t in (n['tags'] as List? ?? const []))
        if (t is Map && (t['localizedName'] as String? ?? '').isNotEmpty) t['localizedName'] as String,
    ],
  );
  final String id;
  final String name;
  final String displayName;
  final String boxArt;
  final int viewers;
  final int followers;

  /// Genre tags ("FPS", "RPG", "IRL"…).
  final List<String> tags;
}

/// Order of a category's live channels.
enum TwitchSort {
  viewers('VIEWER_COUNT', 'Mais vistos'),
  recent('RECENT', 'Começaram agora'),
  fewest('VIEWER_COUNT_ASC', 'Menos vistos');

  const TwitchSort(this.gql, this.label);
  final String gql;
  final String label;
}

/// Everything one search returns.
class TwitchSearchResults {
  const TwitchSearchResults({this.channels = const [], this.games = const [], this.streams = const [], this.videos = const []});
  final List<TwitchChannel> channels;
  final List<TwitchGame> games;
  final List<TwitchStream> streams;
  final List<TwitchVideo> videos;
  bool get isEmpty => channels.isEmpty && games.isEmpty && streams.isEmpty && videos.isEmpty;
}

/// Autocomplete entry: a channel ([login] set), a category ([game] set) or
/// plain text.
class TwitchSuggestion {
  const TwitchSuggestion({required this.text, this.login = '', this.game = '', this.image = '', this.live = false});
  final String text;
  final String login;
  final String game;
  final String image;
  final bool live;
}

class TwitchVideo {
  const TwitchVideo({
    required this.id,
    required this.title,
    required this.lengthSeconds,
    this.views = 0,
    this.thumbnail = '',
    this.publishedAt,
    this.game = '',
    this.login = '',
    this.displayName = '',
  });
  factory TwitchVideo.fromNode(Map n, {String login = '', String displayName = ''}) => TwitchVideo(
    id: n['id'] as String? ?? '',
    title: n['title'] as String? ?? '',
    lengthSeconds: (n['lengthSeconds'] as num?)?.toInt() ?? 0,
    views: (n['viewCount'] as num?)?.toInt() ?? 0,
    thumbnail: n['previewThumbnailURL'] as String? ?? '',
    publishedAt: DateTime.tryParse(n['publishedAt'] as String? ?? ''),
    game: (n['game'] as Map?)?['displayName'] as String? ?? '',
    login: login.isNotEmpty ? login : (n['owner'] as Map?)?['login'] as String? ?? '',
    displayName: displayName.isNotEmpty ? displayName : (n['owner'] as Map?)?['displayName'] as String? ?? '',
  );
  final String id;
  final String title;
  final int lengthSeconds;
  final int views;
  final String thumbnail;
  final DateTime? publishedAt;
  final String game;
  final String login;
  final String displayName;

  /// Twitch serves a placeholder while a VOD is still processing.
  bool get processing => thumbnail.contains('404_processing');
}

class TwitchChannel {
  const TwitchChannel({
    required this.id,
    required this.login,
    required this.displayName,
    this.description = '',
    this.avatar = '',
    this.banner = '',
    this.followers = -1,
    this.stream,
    this.lastTitle = '',
    this.lastStartedAt,
    this.videos = const [],
  });
  final String id;
  final String login;
  final String displayName;
  final String description;
  final String avatar;
  final String banner;
  final int followers;
  final TwitchStream? stream;
  final String lastTitle;
  final DateTime? lastStartedAt;
  final List<TwitchVideo> videos;
  bool get isLive => stream != null;
}

/// Paged result with the GraphQL cursor for the next page.
class TwitchPage<T> {
  const TwitchPage(this.items, this.cursor);
  final List<T> items;
  final String? cursor;
}

class TwitchException implements Exception {
  const TwitchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Signed playback access for a channel or VOD.
class TwitchAccess {
  const TwitchAccess(this.value, this.signature);
  final String value;
  final String signature;
}

/// Read-only Twitch client over the public web GraphQL endpoint (the same
/// one twitch.tv uses anonymously). No login, no API key.
class TwitchApi {
  TwitchApi({http.Client? client}) : _http = client ?? http.Client();
  static final instance = TwitchApi();

  /// Twitch's public web client id.
  static const clientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36';
  static final _deviceId = List.generate(32, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[Random().nextInt(36)]).join();
  static final _login = RegExp(r'^[a-zA-Z0-9_]{2,25}$');

  final http.Client _http;

  static bool validLogin(String login) => _login.hasMatch(login);

  /// [auth]: `(client id, user token)` of a signed-in account; a token only
  /// works with the client id it was issued to.
  Future<Map<String, dynamic>> _gql(String query, [Map<String, Object?>? variables, (String, String)? auth]) async {
    final res = await _http
        .post(
          Uri.parse('https://gql.twitch.tv/gql'),
          headers: {
            'Client-ID': auth?.$1 ?? clientId,
            if (auth != null) 'Authorization': 'OAuth ${auth.$2}',
            'X-Device-Id': _deviceId,
            'Content-Type': 'application/json',
            'User-Agent': _ua,
          },
          body: jsonEncode({'query': query, 'variables': ?variables}),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw TwitchException('Twitch respondeu ${res.statusCode}');
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final errors = json['errors'] as List?;
    if (errors != null && errors.isNotEmpty && json['data'] == null) {
      throw TwitchException('Twitch: ${(errors.first as Map)['message']}');
    }
    return Map<String, dynamic>.from(json['data'] as Map? ?? const {});
  }

  static const _streamFields =
      'id title viewersCount createdAt previewImageURL(width: 640, height: 360) '
      'broadcaster { login displayName profileImageURL(width: 70) } '
      'game { id name displayName boxArtURL(width: 144, height: 192) } freeformTags { name }';

  static List<String>? _langs(String? language) => language == null || language.isEmpty ? null : [language];

  /// Most watched live channels, optionally in one language ("pt", "en"…).
  /// Twitch caps this directory at 30 and its cursors need a browser
  /// integrity token, so there is a single page.
  Future<TwitchPage<TwitchStream>> topStreams({String? language, int first = 30}) async {
    final data = await _gql(
      // The root directory takes the Language enum ("PT"); category
      // directories take plain codes ("pt").
      'query(\$first: Int, \$langs: [Language!]) { streams(first: \$first, options: {languages: \$langs}) '
      '{ edges { cursor node { $_streamFields } } pageInfo { hasNextPage } } }',
      {'first': first.clamp(1, 30), 'langs': _langs(language?.toUpperCase())},
    );
    return _streamPage(data['streams']);
  }

  /// Most watched categories (up to 100 in one request; no cursors).
  Future<TwitchPage<TwitchGame>> topGames({int first = 60}) async {
    final data = await _gql(
      'query(\$first: Int) { games(first: \$first) '
      '{ edges { cursor node { id name displayName viewersCount boxArtURL(width: 285, height: 380) tags(tagType: CONTENT) { localizedName } } } } }',
      {'first': first.clamp(1, 100)},
    );
    final edges = data['games']?['edges'] as List? ?? const [];
    return TwitchPage([for (final e in edges) TwitchGame.fromNode((e as Map)['node'] as Map)], null);
  }

  /// Live channels of one category (by its name, e.g. "Just Chatting"),
  /// up to 100 at once.
  Future<(TwitchGame?, TwitchPage<TwitchStream>)> gameStreams(
    String name, {
    String? language,
    int first = 60,
    TwitchSort sort = TwitchSort.viewers,
  }) async {
    final data = await _gql(
      'query(\$name: String!, \$first: Int, \$langs: [String!], \$sort: StreamSort) { game(name: \$name) { id name displayName viewersCount followersCount '
      'boxArtURL(width: 285, height: 380) tags(tagType: CONTENT) { localizedName } '
      'streams(first: \$first, options: {languages: \$langs, sort: \$sort}) { edges { cursor node { $_streamFields } } } } }',
      {'name': name, 'first': first.clamp(1, 100), 'langs': _langs(language), 'sort': sort.gql},
    );
    final game = data['game'] as Map?;
    if (game == null) return (null, const TwitchPage<TwitchStream>([], null));
    return (TwitchGame.fromNode(game), _streamPage(game['streams']));
  }

  TwitchPage<TwitchStream> _streamPage(Object? conn) {
    final c = conn as Map?;
    final edges = c?['edges'] as List? ?? const [];
    return TwitchPage(
      [
        for (final e in edges)
          if ((e as Map)['node'] is Map && ((e['node'] as Map)['broadcaster'] is Map)) TwitchStream.fromNode(e['node'] as Map),
      ],
      null,
    );
  }

  static const _videoFields =
      'id title lengthSeconds viewCount previewThumbnailURL(width: 640, height: 360) publishedAt game { displayName } owner { login displayName }';

  /// Most viewed past broadcasts of a category.
  Future<List<TwitchVideo>> gameVideos(String name, {int first = 30}) async {
    final data = await _gql(
      'query(\$name: String!, \$first: Int) { game(name: \$name) { videos(first: \$first, sort: VIEWS) { edges { node { $_videoFields } } } } }',
      {'name': name, 'first': first.clamp(1, 100)},
    );
    return [
      for (final e in (data['game']?['videos']?['edges'] as List? ?? const []))
        if ((e as Map)['node'] is Map) TwitchVideo.fromNode(e['node'] as Map),
    ];
  }

  /// One search across channels, categories, live channels and videos.
  Future<TwitchSearchResults> searchAll(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const TwitchSearchResults();
    final data = await _gql(
      'query(\$q: String!) { '
      'searchFor(userQuery: \$q, platform: "web") { '
      'channels { edges { item { ... on User { id login displayName profileImageURL(width: 150) followers { totalCount } stream { $_streamFields } } } } } '
      'games { edges { item { ... on Game { id name displayName viewersCount boxArtURL(width: 285, height: 380) } } } } '
      'videos { edges { item { ... on Video { $_videoFields } } } } } '
      'searchStreams(userQuery: \$q, first: 20) { edges { node { $_streamFields } } } }',
      {'q': q.length > 100 ? q.substring(0, 100) : q},
    );
    List<Map> items(String key) => [
      for (final e in (data['searchFor']?[key]?['edges'] as List? ?? const []))
        if (e is Map && e['item'] is Map && (e['item'] as Map).isNotEmpty) e['item'] as Map,
    ];
    final channels = [for (final u in items('channels')) if ((u['login'] as String? ?? '').isNotEmpty) _channelFrom(u)];
    // Twitch ranks by relevance; within that, live channels come first.
    final live = channels.where((c) => c.isLive).toList();
    final offline = channels.where((c) => !c.isLive).toList();
    final seen = <String>{};
    return TwitchSearchResults(
      channels: [...live, ...offline],
      games: [for (final g in items('games')) if ((g['name'] as String? ?? '').isNotEmpty) TwitchGame.fromNode(g)],
      videos: [for (final v in items('videos')) if ((v['id'] as String? ?? '').isNotEmpty) TwitchVideo.fromNode(v)],
      streams: [
        for (final s in _streamPage(data['searchStreams']).items)
          if (seen.add(s.login)) s,
      ],
    );
  }

  /// Autocomplete for the search box.
  Future<List<TwitchSuggestion>> suggestions(String fragment) async {
    final q = fragment.trim();
    if (q.length < 2) return const [];
    final data = await _gql(
      'query(\$q: String!) { searchSuggestions(queryFragment: \$q, requestID: "ultratube") { edges { node { text content { __typename '
      '... on SearchSuggestionChannel { login isLive profileImageURL(width: 50) } '
      '... on SearchSuggestionCategory { boxArtURL(width: 52, height: 72) game { name } } } } } } }',
      {'q': q.length > 60 ? q.substring(0, 60) : q},
    );
    return [
      for (final e in (data['searchSuggestions']?['edges'] as List? ?? const []))
        if (e is Map && e['node'] is Map && ((e['node'] as Map)['text'] as String? ?? '').isNotEmpty)
          switch ((e['node'] as Map)['content']) {
            {'__typename': 'SearchSuggestionChannel', 'login': final String login} && final Map c => TwitchSuggestion(
              text: (e['node'] as Map)['text'] as String,
              login: login,
              image: c['profileImageURL'] as String? ?? '',
              live: c['isLive'] == true,
            ),
            {'__typename': 'SearchSuggestionCategory'} && final Map c => TwitchSuggestion(
              text: (e['node'] as Map)['text'] as String,
              game: (c['game'] as Map?)?['name'] as String? ?? (e['node'] as Map)['text'] as String,
              image: c['boxArtURL'] as String? ?? '',
            ),
            _ => TwitchSuggestion(text: (e['node'] as Map)['text'] as String),
          },
    ];
  }

  // ------------------------------------------------------------- account

  /// Twitch's own TV app client: the only public one with the device-code
  /// sign-in (type a code at twitch.tv/activate), so the password is never
  /// typed into this app.
  static const tvClientId = 'ue6666qo983tsx6so1t0vnawi233wa';

  Future<Map<String, dynamic>> _oauth(String path, Map<String, String> form) async {
    final res = await _http
        .post(Uri.parse('https://id.twitch.tv/oauth2/$path'), headers: {'User-Agent': _ua}, body: form)
        .timeout(const Duration(seconds: 20));
    final body = res.body.isEmpty ? const <String, dynamic>{} : jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return {...body, 'http': res.statusCode};
  }

  /// Starts a sign-in: `{device_code, user_code, verification_uri, interval, expires_in}`.
  Future<Map<String, dynamic>> deviceCode() async {
    final j = await _oauth('device', {'client_id': tvClientId, 'scopes': 'user:read:follows chat:read chat:edit'});
    if (j['http'] != 200 || j['device_code'] is! String) throw TwitchException('Twitch respondeu ${j['http']}');
    return j;
  }

  /// One poll of a pending sign-in. Tokens once the user approved; null
  /// while still waiting; throws when the code expired or was refused.
  Future<Map<String, dynamic>?> deviceToken(String deviceCode) async {
    final j = await _oauth('token', {
      'client_id': tvClientId,
      'device_code': deviceCode,
      'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
    });
    if (j['http'] == 200 && j['access_token'] is String) return j;
    final message = '${j['message'] ?? ''}'.toLowerCase();
    if (message.contains('pending') || message.contains('slow')) return null;
    throw TwitchException(message.contains('expired') || message.contains('invalid device') ? 'O código expirou. Gere outro.' : 'A Twitch recusou o acesso.');
  }

  /// New tokens from a refresh token; null when it is no longer valid.
  Future<Map<String, dynamic>?> refreshToken(String refresh) async {
    final j = await _oauth('token', {'client_id': tvClientId, 'refresh_token': refresh, 'grant_type': 'refresh_token'});
    return j['http'] == 200 && j['access_token'] is String ? j : null;
  }

  /// `{login, user_id}` of a valid token; null when expired or revoked.
  Future<Map<String, dynamic>?> validate(String token) async {
    final res = await _http
        .get(Uri.parse('https://id.twitch.tv/oauth2/validate'), headers: {'Authorization': 'OAuth $token', 'User-Agent': _ua})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) return null;
    if (res.statusCode != 200) throw TwitchException('Twitch respondeu ${res.statusCode}');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> revoke(String token) async {
    await _oauth('revoke', {'client_id': tvClientId, 'token': token});
  }

  /// Every channel the account follows: `(login, display name, avatar)`.
  Future<List<(String, String, String)>> followed(String token, String userId) async {
    try {
      return await _followedGql(token);
    } on Exception {
      // The private API changed or refused the token: the public one lists
      // the same channels (no avatars; they are filled on the next refresh).
      return _followedHelix(token, userId);
    }
  }

  Future<List<(String, String, String)>> _followedGql(String token) async {
    final out = <(String, String, String)>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final data = await _gql(
        'query(\$after: Cursor) { currentUser { follows(first: 100, after: \$after) { '
        'edges { cursor node { login displayName profileImageURL(width: 150) } } pageInfo { hasNextPage } } } }',
        {'after': cursor},
        (tvClientId, token),
      );
      final follows = data['currentUser']?['follows'] as Map?;
      if (follows == null) throw const TwitchException('Sessão da Twitch inválida');
      final edges = follows['edges'] as List? ?? const [];
      for (final e in edges) {
        final n = (e as Map)['node'] as Map?;
        final login = n?['login'] as String? ?? '';
        if (login.isNotEmpty) out.add((login, n?['displayName'] as String? ?? login, n?['profileImageURL'] as String? ?? ''));
        cursor = e['cursor'] as String? ?? cursor;
      }
      if (edges.isEmpty || follows['pageInfo']?['hasNextPage'] != true) break;
    }
    return out;
  }

  Future<List<(String, String, String)>> _followedHelix(String token, String userId) async {
    final out = <(String, String, String)>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final res = await _http
          .get(
            Uri.https('api.twitch.tv', '/helix/channels/followed', {'user_id': userId, 'first': '100', 'after': ?cursor}),
            headers: {'Client-Id': tvClientId, 'Authorization': 'Bearer $token', 'User-Agent': _ua},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw TwitchException('Twitch respondeu ${res.statusCode}');
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      for (final c in (j['data'] as List? ?? const [])) {
        final login = (c as Map)['broadcaster_login'] as String? ?? '';
        if (login.isNotEmpty) out.add((login, c['broadcaster_name'] as String? ?? login, ''));
      }
      cursor = j['pagination']?['cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  /// Name and photo of the signed-in user.
  Future<(String, String)> profile(String login) async {
    final data = await _gql(
      'query(\$login: String!) { user(login: \$login) { displayName profileImageURL(width: 150) } }',
      {'login': login.toLowerCase()},
    );
    final u = data['user'] as Map?;
    return (u?['displayName'] as String? ?? login, u?['profileImageURL'] as String? ?? '');
  }

  TwitchChannel _channelFrom(Map u, {List<TwitchVideo> videos = const []}) {
    final stream = u['stream'] as Map?;
    final login = u['login'] as String? ?? '';
    final name = u['displayName'] as String? ?? login;
    return TwitchChannel(
      id: u['id'] as String? ?? '',
      login: login,
      displayName: name,
      description: u['description'] as String? ?? '',
      avatar: u['profileImageURL'] as String? ?? '',
      banner: u['bannerImageURL'] as String? ?? '',
      followers: (u['followers']?['totalCount'] as num?)?.toInt() ?? -1,
      stream: stream == null
          ? null
          : TwitchStream.fromNode({
              ...stream,
              'broadcaster': {'login': login, 'displayName': name, 'profileImageURL': u['profileImageURL']},
            }),
      lastTitle: u['lastBroadcast']?['title'] as String? ?? '',
      lastStartedAt: DateTime.tryParse(u['lastBroadcast']?['startedAt'] as String? ?? ''),
      videos: videos,
    );
  }

  /// Channel page: profile, live status and latest past broadcasts.
  Future<TwitchChannel> channel(String login, {int videos = 20}) async {
    if (!validLogin(login)) throw const TwitchException('Canal inválido');
    final data = await _gql(
      'query(\$login: String!, \$n: Int) { user(login: \$login) { id login displayName description profileImageURL(width: 300) bannerImageURL '
      'followers { totalCount } stream { $_streamFields } lastBroadcast { title startedAt } '
      'videos(first: \$n, sort: TIME) { edges { node { id title lengthSeconds viewCount previewThumbnailURL(width: 640, height: 360) publishedAt game { displayName } } } } } }',
      {'login': login.toLowerCase(), 'n': videos},
    );
    final u = data['user'] as Map?;
    if (u == null) throw const TwitchException('Canal não encontrado');
    final name = u['displayName'] as String? ?? login;
    return _channelFrom(u, videos: [
      for (final e in (u['videos']?['edges'] as List? ?? const []))
        TwitchVideo.fromNode((e as Map)['node'] as Map, login: login, displayName: name),
    ]);
  }

  /// Live status of many channels at once (followed list).
  Future<Map<String, TwitchChannel>> channels(List<String> logins) async {
    final valid = logins.where(validLogin).map((l) => l.toLowerCase()).toSet().toList();
    final out = <String, TwitchChannel>{};
    for (var i = 0; i < valid.length; i += 35) {
      final chunk = valid.sublist(i, min(i + 35, valid.length));
      final data = await _gql(
        'query(\$logins: [String!]) { users(logins: \$logins) { id login displayName profileImageURL(width: 150) followers { totalCount } '
        'stream { $_streamFields } lastBroadcast { title startedAt } } }',
        {'logins': chunk},
      );
      for (final u in (data['users'] as List? ?? const [])) {
        if (u is Map) {
          final c = _channelFrom(u);
          out[c.login] = c;
        }
      }
    }
    return out;
  }

  /// Fresh title/viewers of one live (polled by the watch page).
  Future<TwitchStream?> liveInfo(String login) async {
    final data = await _gql(
      'query(\$login: String!) { user(login: \$login) { login displayName profileImageURL(width: 70) stream { $_streamFields } } }',
      {'login': login.toLowerCase()},
    );
    final u = data['user'] as Map?;
    final s = u?['stream'] as Map?;
    if (u == null || s == null) return null;
    return TwitchStream.fromNode({...s, 'broadcaster': u});
  }

  // ------------------------------------------------------------ playback

  static const _tokenQuery =
      'query PlaybackAccessToken_Template(\$login: String!, \$isLive: Boolean!, \$vodID: ID!, \$isVod: Boolean!, \$playerType: String!, \$platform: String!) { '
      'streamPlaybackAccessToken(channelName: \$login, params: {platform: \$platform, playerBackend: "mediaplayer", playerType: \$playerType}) @include(if: \$isLive) { value signature __typename } '
      'videoPlaybackAccessToken(id: \$vodID, params: {platform: \$platform, playerBackend: "mediaplayer", playerType: \$playerType}) @include(if: \$isVod) { value signature __typename } }';

  Future<TwitchAccess> liveAccess(String login, {String playerType = 'site', String platform = 'web'}) async {
    final data = await _gql(_tokenQuery, {
      'login': login.toLowerCase(),
      'isLive': true,
      'vodID': '',
      'isVod': false,
      'playerType': playerType,
      'platform': platform,
    });
    final t = data['streamPlaybackAccessToken'] as Map?;
    if (t == null) throw const TwitchException('Canal offline ou indisponível');
    return TwitchAccess(t['value'] as String, t['signature'] as String);
  }

  Future<TwitchAccess> vodAccess(String id, {String playerType = 'site'}) async {
    final data = await _gql(_tokenQuery, {
      'login': '',
      'isLive': false,
      'vodID': id,
      'isVod': true,
      'playerType': playerType,
      'platform': 'web',
    });
    final t = data['videoPlaybackAccessToken'] as Map?;
    if (t == null) throw const TwitchException('Vídeo indisponível');
    return TwitchAccess(t['value'] as String, t['signature'] as String);
  }

  static Map<String, String> _usherParams(TwitchAccess a) => {
    'sig': a.signature,
    'token': a.value,
    'allow_source': 'true',
    'allow_audio_only': 'true',
    'fast_bread': 'true',
    'p': '${Random().nextInt(9999999)}',
    'player_backend': 'mediaplayer',
    'playlist_include_framerate': 'true',
    'reassignments_supported': 'true',
    'supported_codecs': 'avc1',
    'platform': 'web',
  };

  static Uri liveMasterUrl(String login, TwitchAccess a) =>
      Uri.https('usher.ttvnw.net', '/api/channel/hls/${login.toLowerCase()}.m3u8', _usherParams(a));

  static Uri vodMasterUrl(String id, TwitchAccess a) => Uri.https('usher.ttvnw.net', '/vod/$id.m3u8', _usherParams(a));

  Future<String> fetchText(Uri url) async {
    final res = await _http.get(url, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw TwitchException(res.statusCode == 404 ? 'Transmissão offline' : 'Twitch respondeu ${res.statusCode}');
    }
    return utf8.decode(res.bodyBytes);
  }

  /// Master playlist variants ("1080p60", "720p60", "audio_only"…).
  static List<TwitchVariant> parseMaster(String m3u8) {
    final out = <TwitchVariant>[];
    final lines = const LineSplitter().convert(m3u8);
    String? name;
    var bandwidth = 0, height = 0;
    final media = <String, String>{};
    for (final line in lines) {
      if (line.startsWith('#EXT-X-MEDIA:')) {
        final group = RegExp(r'GROUP-ID="([^"]+)"').firstMatch(line)?.group(1);
        final n = RegExp(r'NAME="([^"]+)"').firstMatch(line)?.group(1);
        if (group != null && n != null) media[group] = n;
      } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
        bandwidth = int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '') ?? 0;
        height = int.tryParse(RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(line)?.group(1) ?? '') ?? 0;
        final video = RegExp(r'VIDEO="([^"]+)"').firstMatch(line)?.group(1);
        name = media[video] ?? video;
      } else if (line.isNotEmpty && !line.startsWith('#') && name != null) {
        out.add(TwitchVariant(name: name, url: line.trim(), bandwidth: bandwidth, height: height));
        name = null;
      }
    }
    return out;
  }
}

class TwitchVariant {
  const TwitchVariant({required this.name, required this.url, required this.bandwidth, required this.height});
  final String name;
  final String url;
  final int bandwidth;
  final int height;
  bool get audioOnly => name == 'audio_only' || height == 0;

  /// Friendly label: "1080p60 (fonte)" → "1080p60".
  String get label => audioOnly ? 'Só áudio' : name.replaceAll(RegExp(r'\s*\(.*\)'), '');
}
