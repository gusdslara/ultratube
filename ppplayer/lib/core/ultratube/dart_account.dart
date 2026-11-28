import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../api/innertube.dart';
import '../api/reels.dart';

/// Dart port of the Android `YoutubeAccount.kt` for iOS. The Google sign-in
/// page runs natively (WKWebView, `app.ultratube/ios_login`) and hands back
/// the youtube.com cookies; everything else is InnerTube from Dart.
///
/// Cookies live in the Keychain (flutter_secure_storage), never in Hive.
class DartYoutubeAccount {
  DartYoutubeAccount._();
  static final instance = DartYoutubeAccount._();

  static const _login = MethodChannel('app.ultratube/ios_login');
  static const _storage = FlutterSecureStorage();
  static const _key = 'ultratube_youtube_cookies';
  static const _origin = InnerTube.origin;

  final _tube = InnerTube();
  Map<String, String>? _cache;

  // ------------------------------------------------------------- cookies

  static Map<String, String> parseCookies(String header) {
    final out = <String, String>{};
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) out[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
    }
    return out;
  }

  static String _header(Map<String, String> map) =>
      map.entries.map((e) => '${e.key}=${e.value}').join('; ');

  static bool hasSession(Map<String, String> map) =>
      map.containsKey('SAPISID') || map.containsKey('__Secure-3PAPISID');

  Future<Map<String, String>> _cookies() async =>
      _cache ??= parseCookies(await _storage.read(key: _key) ?? '');

  Future<void> _save(Map<String, String> map) async {
    _cache = Map.of(map);
    await _storage.write(key: _key, value: _header(map));
  }

  Future<bool> isSignedIn() async => hasSession(await _cookies());

  /// Opens the Google page. True once youtube.com holds a signed-in session.
  Future<bool> signIn() async {
    final header = await _login.invokeMethod<String>('signIn');
    if (header == null || header.isEmpty) return false;
    final map = parseCookies(header);
    if (!hasSession(map)) return false;
    await _save(map);
    return true;
  }

  Future<void> signOut() async {
    _cache = const {};
    await _storage.delete(key: _key);
    try {
      await _login.invokeMethod<void>('clear');
    } catch (_) {
      // The login page keeps no persistent data; nothing else to clear.
    }
  }

  // ----------------------------------------------------------- InnerTube

  static String _sha1(String text) => sha1.convert(utf8.encode(text)).toString();

  static String _authorization(Map<String, String> map) {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String? hash(String scheme, String? value) =>
        value == null ? null : '$scheme ${ts}_${_sha1('$ts $value $_origin')}';
    return [
      hash('SAPISIDHASH', map['SAPISID'] ?? map['__Secure-3PAPISID']),
      hash('SAPISID1PHASH', map['__Secure-1PAPISID']),
      hash('SAPISID3PHASH', map['__Secure-3PAPISID']),
    ].whereType<String>().join(' ');
  }

  /// `Set-Cookie` lines; the http package joins repeated headers with ",",
  /// which also appears inside `Expires=Wed, 21 Oct…`.
  static Map<String, String> _setCookies(http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return const {};
    final out = <String, String>{};
    for (final line in raw.split(RegExp(r',(?=\s*[A-Za-z0-9_\-.]+=)'))) {
      final pair = line.split(';').first;
      final eq = pair.indexOf('=');
      if (eq > 0) out[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
    }
    return out;
  }

  Future<Json> _call(String endpoint, Json body) async {
    final map = await _cookies();
    if (!hasSession(map)) throw StateError('Entre com sua conta do YouTube');
    Map<String, String> fresh = const {};
    try {
      return await _tube.post(
        endpoint,
        body,
        headers: {
          'Cookie': _header(map),
          'Authorization': _authorization(map),
          'X-Goog-AuthUser': '0',
        },
        onResponse: (response) => fresh = _setCookies(response),
      );
    } on InnerTubeException catch (error) {
      if (error.status == 401 || error.status == 403) {
        throw StateError('Sessão do YouTube expirou; entre de novo');
      }
      rethrow;
    } finally {
      // Google rotates some session cookies; keep the fresh values.
      if (fresh.isNotEmpty) {
        final current = await _cookies();
        if (hasSession(current)) await _save({...current, ...fresh});
      }
    }
  }

  /// `{signedIn, name, handle, avatar}`; signedIn=false when the session is gone.
  Future<Json> info() async {
    if (!await isSignedIn()) return {'signedIn': false};
    final menu = await _call('account/account_menu', {});
    final header = find(menu, 'activeAccountHeaderRenderer');
    if (header == null) return {'signedIn': false, 'expired': true};
    return {
      'signedIn': true,
      'name': text(header['accountName']),
      'handle': text(header['channelHandle']),
      'avatar': thumb(header['accountPhoto']),
    };
  }

  /// Every channel the account follows: `[{url, title, avatar}]`.
  Future<List<Json>> subscriptions() async {
    final out = <String, Json>{};
    var page = await _call('browse', {'browseId': 'FEchannels'});
    var pages = 0;
    while (true) {
      walk(page, (key, node) {
        if (key != 'channelRenderer' && key != 'gridChannelRenderer') return false;
        final id = str(node, ['channelId']);
        if (id.startsWith('UC') && !out.containsKey(id)) {
          out[id] = {
            'url': channelUrl(id),
            'title': text(node['title']),
            'avatar': thumb(node['thumbnail']),
          };
        }
        return true;
      });
      final token = continuation(page);
      if (token == null || ++pages >= 40) break;
      page = await _call('browse', {'continuation': token.$1});
    }
    return out.values.toList();
  }

  /// InnerTube call that also works signed out; the session is sent when
  /// there is one, which personalises the answer.
  Future<Json> _open(String endpoint, Json body) async =>
      hasSession(await _cookies()) ? _call(endpoint, body) : _tube.post(endpoint, body);

  /// YouTube's own Shorts feed (the account's when signed in).
  Future<Json> shorts(String? token) => Reels(_open).feed(token);

  /// Title, channel and counters of one Short.
  Future<Json> shortInfo(String videoId) => Reels(_open).info(videoId);

  /// The account's own YouTube home ("recommended for you").
  Future<Json> home(String? token) async {
    final page = await _call(
      'browse',
      token == null || token.isEmpty
          ? {'browseId': 'FEwhat_to_watch'}
          : {'continuation': token},
    );
    return {
      // Shorts shelves included: the home shows them on their own shelf.
      'items': parseItems(page, shelves: true).where((i) => i['type'] == 'video').toList(),
      'next': continuation(page)?.$1,
    };
  }
}
