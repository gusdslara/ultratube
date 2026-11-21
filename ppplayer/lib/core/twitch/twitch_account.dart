import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ultratube/ultratube_store.dart';
import 'twitch_api.dart';
import 'twitch_store.dart';

/// Signed-in Twitch account shown on the Twitch tab.
class TwitchAccountInfo {
  const TwitchAccountInfo({required this.login, required this.userId, this.displayName = '', this.avatar = ''});
  factory TwitchAccountInfo.fromJson(Map<String, dynamic> j) => TwitchAccountInfo(
    login: j['login'] as String? ?? '',
    userId: j['userId'] as String? ?? '',
    displayName: j['displayName'] as String? ?? '',
    avatar: j['avatar'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {'login': login, 'userId': userId, 'displayName': displayName, 'avatar': avatar};
  final String login;
  final String userId;
  final String displayName;
  final String avatar;
  String get name => displayName.isEmpty ? login : displayName;
}

/// A sign-in waiting for the user to type [code] at [url].
class TwitchSignIn {
  const TwitchSignIn({required this.code, required this.url, required this.deviceCode, required this.interval, required this.expiresAt});
  final String code;
  final String url;
  final String deviceCode;
  final Duration interval;
  final DateTime expiresAt;
}

/// The optional Twitch account. Sign-in is Twitch's device flow: the app
/// shows a code, the user approves it at twitch.tv/activate in their own
/// browser, and the app never sees the password. The account is used to
/// bring the followed channels into "Seguindo".
///
/// Tokens live in the platform keystore (flutter_secure_storage); only the
/// name and photo are kept in Hive.
class TwitchAccountNotifier extends Notifier<TwitchAccountInfo?> {
  static const _key = 'twitch_account';
  static const _tokenKey = 'ultratube_twitch_token';
  static const _refreshKey = 'ultratube_twitch_refresh';
  static const _storage = FlutterSecureStorage();
  final _api = TwitchApi.instance;

  @override
  TwitchAccountInfo? build() {
    final cached = UltratubeStore.box.get(_key);
    if (cached is! Map) return null;
    // Bring in channels followed elsewhere since the last start.
    Future.microtask(() => syncFollows().then((_) {}, onError: (Object _) {}));
    return TwitchAccountInfo.fromJson(Map<String, dynamic>.from(cached));
  }

  void _set(TwitchAccountInfo? info) {
    state = info;
    if (info == null) {
      UltratubeStore.box.delete(_key);
    } else {
      UltratubeStore.box.put(_key, info.toJson());
    }
  }

  Future<void> _saveTokens(Map<String, dynamic> tokens) async {
    await _storage.write(key: _tokenKey, value: tokens['access_token'] as String);
    final refresh = tokens['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) await _storage.write(key: _refreshKey, value: refresh);
  }

  /// A token Twitch still accepts, with its `{login, user_id}`; renews an
  /// expired one. Null (and signed out) when the session is really gone.
  Future<(String, Map<String, dynamic>)?> _session() async {
    var token = await _storage.read(key: _tokenKey);
    if (token == null || token.isEmpty) return null;
    var who = await _api.validate(token);
    if (who == null) {
      final refresh = await _storage.read(key: _refreshKey);
      final renewed = refresh == null || refresh.isEmpty ? null : await _api.refreshToken(refresh);
      if (renewed == null) {
        await _forget();
        return null;
      }
      await _saveTokens(renewed);
      token = renewed['access_token'] as String;
      who = await _api.validate(token);
      if (who == null) {
        await _forget();
        return null;
      }
    }
    return (token, who);
  }

  Future<void> _forget() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _refreshKey);
    _set(null);
  }

  /// Asks Twitch for a code to show the user.
  Future<TwitchSignIn> begin() async {
    final j = await _api.deviceCode();
    final code = j['user_code'] as String;
    final base = Uri.parse(j['verification_uri'] as String? ?? 'https://www.twitch.tv/activate');
    return TwitchSignIn(
      code: code,
      // Pre-fills the code on the activation page.
      url: base.replace(queryParameters: {...base.queryParameters, 'device-code': code}).toString(),
      deviceCode: j['device_code'] as String,
      interval: Duration(seconds: ((j['interval'] as num?)?.toInt() ?? 5).clamp(3, 30)),
      expiresAt: DateTime.now().add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 1800)),
    );
  }

  /// Waits for the user to approve [signIn]. Returns a message for the
  /// user, or null when [cancelled] says the sheet was closed.
  Future<String?> complete(TwitchSignIn signIn, {required bool Function() cancelled}) async {
    Map<String, dynamic>? tokens;
    while (tokens == null) {
      await Future<void>.delayed(signIn.interval);
      if (cancelled()) return null;
      if (DateTime.now().isAfter(signIn.expiresAt)) throw const TwitchException('O código expirou. Gere outro.');
      try {
        tokens = await _api.deviceToken(signIn.deviceCode);
      } on TwitchException {
        rethrow;
      } catch (error) {
        debugPrint('Ultratube: Twitch sign-in poll failed ($error)'); // offline for a moment: keep waiting
      }
    }
    await _saveTokens(tokens);
    final who = await _api.validate(tokens['access_token'] as String);
    if (who == null) {
      await _forget();
      throw const TwitchException('Não foi possível confirmar a conta. Tente de novo.');
    }
    final login = who['login'] as String? ?? '';
    var (name, avatar) = (login, '');
    try {
      (name, avatar) = await _api.profile(login);
    } catch (_) {
      // Name and photo are cosmetic; the next sync fills them.
    }
    _set(TwitchAccountInfo(login: login, userId: '${who['user_id'] ?? ''}', displayName: name, avatar: avatar));
    var added = 0;
    try {
      added = await syncFollows();
    } catch (error) {
      debugPrint('Ultratube: Twitch follows not imported ($error)');
      return 'Conectado como $name. Não foi possível importar os canais agora; puxe para atualizar.';
    }
    return 'Conectado como $name${added > 0 ? ' · $added ${added == 1 ? 'canal importado' : 'canais importados'}' : ''}';
  }

  /// Adds the account's followed channels to "Seguindo". Returns how many
  /// were new; 0 when signed out.
  Future<int> syncFollows() async {
    final session = await _session();
    if (session == null) return 0;
    final (token, who) = session;
    final channels = await _api.followed(token, '${who['user_id'] ?? state?.userId ?? ''}');
    return ref.read(twitchFollowsProvider.notifier).merge([
      for (final (login, name, avatar) in channels) TwitchFollow(login: login.toLowerCase(), displayName: name, avatar: avatar),
    ]);
  }

  Future<void> signOut() async {
    final token = await _storage.read(key: _tokenKey);
    await _forget();
    if (token != null && token.isNotEmpty) {
      try {
        await _api.revoke(token);
      } catch (_) {
        // Already forgotten on this device; the token expires on its own.
      }
    }
  }
}

final twitchAccountProvider = NotifierProvider<TwitchAccountNotifier, TwitchAccountInfo?>(TwitchAccountNotifier.new);
