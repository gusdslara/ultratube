import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/yt_models.dart';
import 'dart_account.dart';
import 'ultratube_store.dart';

/// Signed-in YouTube account shown on "Você".
class YoutubeAccountInfo {
  const YoutubeAccountInfo({required this.name, this.handle = '', this.avatar = ''});
  factory YoutubeAccountInfo.fromJson(Map<String, dynamic> j) => YoutubeAccountInfo(
    name: j['name'] as String? ?? '',
    handle: j['handle'] as String? ?? '',
    avatar: j['avatar'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {'name': name, 'handle': handle, 'avatar': avatar};
  final String name;
  final String handle;
  final String avatar;
}

/// The optional YouTube account: the regular Google sign-in page in a
/// WebView, no client ID or API key. Android uses `YoutubeAccount.kt`; iOS the
/// Dart port ([DartYoutubeAccount]) with a native WKWebView sign-in page.
class YoutubeAccountApi {
  const YoutubeAccountApi();
  static const _channel = MethodChannel('app.ultratube/account');
  static const _timeout = Duration(seconds: 90);

  static bool get _native =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The Google sign-in page needs the native WebView hosts (Android/iOS).
  static bool get signInSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<dynamic> _call(String method, [Map<String, Object?>? args]) async {
    if (!_native) {
      final account = DartYoutubeAccount.instance;
      return switch (method) {
        'info' => account.info().timeout(_timeout),
        'subscriptions' => account.subscriptions().timeout(_timeout),
        'home' => account.home(args?['token'] as String?).timeout(_timeout),
        _ => throw UnsupportedError(method),
      };
    }
    return jsonDecode((await _channel.invokeMethod<String>(method, args).timeout(_timeout))!);
  }

  /// Opens the Google sign-in page. True once the user signed in.
  Future<bool> signIn() async => _native
      ? await _channel.invokeMethod<bool>('signIn') ?? false
      : DartYoutubeAccount.instance.signIn();

  Future<void> signOut() =>
      _native ? _channel.invokeMethod<String>('signOut') : DartYoutubeAccount.instance.signOut();

  /// Null when there is no (valid) session.
  Future<YoutubeAccountInfo?> info() async {
    final j = Map<String, dynamic>.from(await _call('info') as Map);
    return j['signedIn'] == true ? YoutubeAccountInfo.fromJson(j) : null;
  }

  Future<List<Subscription>> subscriptions() async => [
    for (final e in await _call('subscriptions') as List) Subscription.fromJson(Map<String, dynamic>.from(e as Map)),
  ];

  /// The account's YouTube home recommendations.
  Future<YtPage> home([String? token]) async =>
      YtPage.fromJson(Map<String, dynamic>.from(await _call('home', {'token': token}) as Map));
}

class YoutubeAccountNotifier extends Notifier<YoutubeAccountInfo?> {
  static const _key = 'youtube_account';
  static const api = YoutubeAccountApi();

  @override
  YoutubeAccountInfo? build() {
    final cached = UltratubeStore.box.get(_key);
    if (cached == null) return null;
    // Confirm the session is still valid (name/photo may have changed too).
    Future.microtask(_refresh);
    return YoutubeAccountInfo.fromJson(Map<String, dynamic>.from(cached as Map));
  }

  void _set(YoutubeAccountInfo? info) {
    state = info;
    if (info == null) {
      UltratubeStore.box.delete(_key);
    } else {
      UltratubeStore.box.put(_key, info.toJson());
    }
  }

  Future<void> _refresh() async {
    try {
      final info = await api.info();
      if (info == null) {
        _set(null);
      } else {
        _set(info);
      }
    } catch (error) {
      debugPrint('Ultratube: account check failed ($error)'); // offline: keep cache
    }
  }

  /// Opens the Google page; after signing in, imports the subscriptions.
  /// Returns a message for the user, or null when cancelled.
  Future<String?> signIn() async {
    if (!await api.signIn()) return null;
    final info = await api.info();
    if (info == null) return 'Não foi possível confirmar a conta. Tente de novo.';
    _set(info);
    final added = await syncSubscriptions();
    return 'Conectado como ${info.name}${added > 0 ? ' · $added inscrições importadas' : ''}';
  }

  /// Adds the account's subscriptions to the local list. Returns how many were new.
  Future<int> syncSubscriptions() async {
    final subs = await api.subscriptions();
    return ref.read(subscriptionsProvider.notifier).merge(subs);
  }

  Future<void> signOut() async {
    await api.signOut();
    _set(null);
  }
}

final youtubeAccountProvider = NotifierProvider<YoutubeAccountNotifier, YoutubeAccountInfo?>(
  YoutubeAccountNotifier.new,
);
