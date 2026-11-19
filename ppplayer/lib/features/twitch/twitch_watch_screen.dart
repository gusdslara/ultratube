import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fullscreen_window/fullscreen_window.dart';
import 'package:go_router/go_router.dart';

import '../../core/live/live_chat.dart';
import '../../core/player/player_provider.dart';
import '../../core/player/video_layout_provider.dart';
import '../../core/services/settings_provider.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/twitch/twitch_api.dart';
import '../../core/twitch/twitch_chat.dart';
import '../../core/twitch/twitch_providers.dart';
import '../../core/twitch/twitch_proxy.dart';
import '../../core/twitch/twitch_store.dart';
import '../../core/ultratube/ultratube_platform.dart';
import '../live/live_chat_view.dart';
import '../player/player_providers.dart';
import '../ultratube/yt_widgets.dart' show Avatar, NetImage, durationLabel;
import 'twitch_widgets.dart';

/// Twitch live (or past broadcast) page: the shared video surface under a
/// transparent slot, Twitch-style controls, ad-break status, and chat both
/// below the video and optionally over it.
class TwitchWatchScreen extends ConsumerStatefulWidget {
  const TwitchWatchScreen({super.key, required this.login, this.vodId});
  final String login;
  final String? vodId;
  @override
  ConsumerState<TwitchWatchScreen> createState() => _TwitchWatchScreenState();
}

class _TwitchWatchScreenState extends ConsumerState<TwitchWatchScreen> with WidgetsBindingObserver {
  final _slot = GlobalKey();
  late VideoLayoutNotifier _layout;
  TwitchLiveSession? _session;
  StreamSubscription<TwitchAdEvent>? _adSub;
  TwitchAdState _ad = TwitchAdState.none;
  List<TwitchVariant> _variants = const [];
  TwitchVideo? _vod;
  String? _error;
  bool _offline = false;
  bool _starting = false;
  bool _fullscreen = false;

  String get _login => widget.login.toLowerCase();
  bool get _isVod => widget.vodId != null;
  String get _trackId => _isVod ? 'twitchvod:${widget.vodId}' : 'twitch:$_login';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _layout = ref.read(videoLayoutProvider.notifier);
    if (!_isVod) {
      _session = TwitchLiveSession(_login);
      _adSub = TwitchProxy.instance.events.where((e) => e.login == _login).listen((e) {
        if (mounted) setState(() => _ad = e.state);
      });
      _ad = TwitchProxy.instance.adState(_login);
      _variants = TwitchProxy.instance.variants(_login);
    }
    final player = ref.read(playerProvider);
    final current = player.currentTrack?.spotifyId;
    // Same channel already playing: keep it. A track restored from a previous
    // app run points at an old proxy port (no session yet), so reopen it.
    final stale = !_isVod && TwitchProxy.instance.variants(_login).isEmpty;
    if (current != _trackId || stale || player.loadError != null) {
      // After this build pass: starting touches other providers.
      Future<void>.microtask(_start);
    } else if (_isVod) {
      _loadVodInfo();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _adSub?.cancel();
    _session?.dispose();
    if (_fullscreen) _restoreSystemUi();
    Future<void>.microtask(_layout.clear);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _measure();

  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _slot.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final position = box.localToGlobal(Offset.zero);
      final old = ref.read(videoLayoutProvider);
      if (old.size != box.size || old.position != position || !old.isVisible) {
        _layout.updateLayout(box.size, position, isVisible: true, label: 'twitch_watch');
      }
    });
  }

  Future<void> _loadVodInfo() async {
    try {
      final channel = await ref.read(twitchChannelProvider(_login).future);
      final vod = channel.videos.where((v) => v.id == widget.vodId).firstOrNull;
      if (mounted) setState(() => _vod = vod);
    } catch (_) {}
  }

  Future<void> _start({String? quality}) async {
    if (_starting) return;
    final String q = quality ?? ref.read(twitchQualityProvider);
    setState(() {
      _starting = true;
      _error = null;
      _offline = false;
    });
    try {
      // Video surface on unless the user asked for audio only.
      final settings = ref.read(settingsProvider.notifier);
      if (q == 'audio_only') {
        if (ref.read(settingsProvider).showVideo) await settings.toggleVideo();
      } else {
        await settings.setPlayerView(PlayerView.video);
      }
      final Track track;
      if (_isVod) {
        final channel = await ref.read(twitchChannelProvider(_login).future);
        final vod = channel.videos.where((v) => v.id == widget.vodId).firstOrNull ??
            TwitchVideo(id: widget.vodId!, title: 'Vídeo de ${channel.displayName}', lengthSeconds: 0, login: _login, displayName: channel.displayName);
        final (url, variants) = await TwitchProxy.instance.vodUrl(widget.vodId!, quality: q);
        _vod = vod;
        _variants = variants;
        track = twitchVodTrack(video: vod, url: url.toString());
      } else {
        final url = await TwitchProxy.instance.liveUrl(_login, quality: q);
        _variants = TwitchProxy.instance.variants(_login);
        final info = _session?.stream.value ?? await TwitchApi.instance.liveInfo(_login);
        track = twitchLiveTrack(
          login: _login,
          displayName: info?.displayName ?? _login,
          url: url.toString(),
          title: info?.title ?? '',
          preview: info?.previewAt(640, 360) ?? '',
        );
      }
      if (!mounted) return;
      await ref.read(playerProvider.notifier).playTrack(track, queue: [track]);
    } on TwitchException catch (e) {
      if (mounted) {
        setState(() {
          _offline = e.message.toLowerCase().contains('offline') || e.message.contains('indisponível');
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Não foi possível abrir a transmissão ($e).');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _setQuality(String q) {
    ref.read(twitchQualityProvider.notifier).set(q);
    _start(quality: q);
  }

  Future<void> _toggleFullscreen() async {
    if (isUltratubeDesktop) {
      final next = !ref.read(isFullscreenProvider);
      ref.read(isFullscreenProvider.notifier).setFullscreen(next);
      await FullScreenWindow.setFullScreen(next);
      if (mounted) setState(() => _fullscreen = next);
      _measure();
      return;
    }
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    if (!_fullscreen && landscape) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      return;
    }
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    ref.read(isFullscreenProvider.notifier).setFullscreen(next);
    if (next) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      await _restoreSystemUi();
    }
    _measure();
  }

  Future<void> _restoreSystemUi() async {
    ref.read(isFullscreenProvider.notifier).setFullscreen(false);
    if (isUltratubeDesktop) {
      await FullScreenWindow.setFullScreen(false);
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  @override
  Widget build(BuildContext context) {
    _measure();
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    // Landscape = fullscreen only on phones; desktop uses the button / F key.
    final immersive = isUltratubeDesktop ? ref.watch(isFullscreenProvider) : (_fullscreen || landscape);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 900;
    final slot = _TwitchVideoSlot(
      slotKey: _slot,
      trackId: _trackId,
      live: !_isVod,
      session: _session,
      fullscreen: immersive,
      onFullscreen: _toggleFullscreen,
      ad: _ad,
      variants: _variants,
      onQuality: _setQuality,
      onRestart: () => _start(),
      error: _error,
      offline: _offline,
      starting: _starting,
      login: _login,
      cover: _isVod ? (_vod?.thumbnail ?? '') : 'https://static-cdn.jtvnw.net/previews-ttv/live_user_$_login-640x360.jpg',
    );

    return PopScope(
      canPop: !(isUltratubeDesktop ? immersive : _fullscreen),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: immersive
            ? slot
            : SafeArea(
                bottom: false,
                child: !wide
                    ? Column(
                        children: [
                          AspectRatio(aspectRatio: 16 / 9, child: slot),
                          Expanded(child: ColoredBox(color: UT.bg, child: _details())),
                        ],
                      )
                    // Twitch desktop layout: player + info, chat column on the right.
                    : ColoredBox(
                        color: UT.bg,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    ConstrainedBox(
                                      constraints: BoxConstraints(maxHeight: size.height - 180),
                                      child: AspectRatio(aspectRatio: 16 / 9, child: slot),
                                    ),
                                    _details(infoOnly: true),
                                  ],
                                ),
                              ),
                            ),
                            if (_session != null)
                              Container(
                                width: size.width >= 1300 ? 380 : 320,
                                decoration: const BoxDecoration(border: Border(left: BorderSide(color: UT.line))),
                                child: _details(chatOnly: true),
                              ),
                          ],
                        ),
                      ),
              ),
      ),
    );
  }

  /// [header]: only title/channel (wide layout, chat lives in its own column).
  /// [chatOnly]: only the chat column.
  Widget _details({bool infoOnly = false, bool chatOnly = false}) {
    final channel = ref.watch(twitchChannelProvider(_login));
    final c = channel.value;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_session != null)
            ValueListenableBuilder<TwitchStream?>(
              valueListenable: _session!.stream,
              builder: (_, s, _) => _titleBlock(s?.title ?? c?.stream?.title ?? '', s?.game ?? c?.stream?.game ?? '', s?.startedAt ?? c?.stream?.startedAt),
            )
          else
            _titleBlock(_vod?.title ?? '', _vod?.game ?? '', null),
          const SizedBox(height: 10),
          Row(
            children: [
              GestureDetector(onTap: () => openTwitchChannel(context, _login), child: Avatar(c?.avatar ?? '', size: 40)),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => openTwitchChannel(context, _login),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c?.displayName ?? _login, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if ((c?.followers ?? -1) >= 0)
                        Text('${compactFollowers(c!.followers)} seguidores', style: const TextStyle(fontSize: 12, color: UT.text2)),
                    ],
                  ),
                ),
              ),
              FollowButton(login: _login, displayName: c?.displayName ?? _login, avatar: c?.avatar ?? ''),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
    );
    final others = (c?.videos ?? const <TwitchVideo>[]).where((v) => v.id != widget.vodId).toList();
    if (infoOnly) {
      // Wide layout (inside a scroll view): plain column, no slivers.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (_session == null && others.isNotEmpty) ...[
            const Divider(color: UT.line, height: 16),
            const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 6), child: Text('Mais vídeos do canal', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            for (final v in others) TwitchVodRow(v),
          ],
          const SizedBox(height: 120),
        ],
      );
    }
    if (_session == null) {
      // Past broadcast: details + more videos from the channel.
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: header),
          const SliverToBoxAdapter(child: Divider(color: UT.line, height: 16)),
          if (others.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 6), child: Text('Mais vídeos do canal', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            ),
            SliverList.builder(
              itemCount: others.length,
              itemBuilder: (context, i) => TwitchVodRow(others[i]),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!chatOnly) header,
        Container(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: UT.line), bottom: BorderSide(color: UT.line))),
          padding: const EdgeInsets.only(left: 16),
          child: Row(
            children: [
              const Text('Chat da transmissão', style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              Consumer(
                builder: (context, ref, _) {
                  final overlay = ref.watch(liveChatPrefsProvider.select((p) => p.overlay));
                  return IconButton(
                    tooltip: overlay ? 'Tirar chat de cima do vídeo' : 'Mostrar chat sobre o vídeo',
                    icon: Icon(overlay ? Icons.picture_in_picture_alt_rounded : Icons.picture_in_picture_alt_outlined, color: overlay ? UT.text : UT.text2),
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      ref.read(liveChatPrefsProvider.notifier).toggleOverlay();
                    },
                  );
                },
              ),
              IconButton(tooltip: 'Ajustes do chat', icon: const Icon(Icons.tune_rounded, color: UT.text2), onPressed: () => showLiveChatSettings(context)),
            ],
          ),
        ),
        Expanded(child: LiveChatPanel(feed: _session!.chat, emptyLabel: 'Bem-vindo ao chat! As mensagens aparecem aqui.')),
        // Room for the mini player / nav bar insets on the shell.
        SizedBox(height: MediaQuery.paddingOf(context).bottom),
      ],
    );
  }

  Widget _titleBlock(String title, String game, DateTime? startedAt) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title.isEmpty ? (_isVod ? '' : 'Ao vivo') : title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, height: 1.25)),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (game.isNotEmpty)
            GestureDetector(
              onTap: () => openTwitchCategory(context, game),
              child: Text(game, style: const TextStyle(color: UT.twitch, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          if (startedAt != null) Text('ao vivo há ${uptimeLabel(startedAt)}', style: const TextStyle(color: UT.text2, fontSize: 12.5)),
          if (_vod != null) Text(agoLabel(_vod!.publishedAt), style: const TextStyle(color: UT.text2, fontSize: 12.5)),
        ],
      ),
    ],
  );
}

String compactFollowers(int n) => n < 0 ? '' : n >= 1000000 ? '${(n / 1e6).toStringAsFixed(1).replaceAll('.', ',')} mi' : n >= 1000 ? '${(n / 1e3).toStringAsFixed(n >= 10000 ? 0 : 1).replaceAll('.', ',')} mil' : '$n';

class _TwitchVideoSlot extends ConsumerStatefulWidget {
  const _TwitchVideoSlot({
    required this.slotKey,
    required this.trackId,
    required this.live,
    required this.session,
    required this.fullscreen,
    required this.onFullscreen,
    required this.ad,
    required this.variants,
    required this.onQuality,
    required this.onRestart,
    required this.error,
    required this.offline,
    required this.starting,
    required this.login,
    required this.cover,
  });
  final GlobalKey slotKey;
  final String trackId;
  final bool live;
  final LiveSession? session;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final TwitchAdState ad;
  final List<TwitchVariant> variants;
  final ValueChanged<String> onQuality;
  final VoidCallback onRestart;
  final String? error;
  final bool offline;
  final bool starting;
  final String login;
  final String cover;
  @override
  ConsumerState<_TwitchVideoSlot> createState() => _TwitchVideoSlotState();
}

class _TwitchVideoSlotState extends ConsumerState<_TwitchVideoSlot> {
  bool _controls = true;
  bool _behind = false;
  Timer? _hide;
  double? _drag;

  @override
  void initState() {
    super.initState();
    _armHide();
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _armHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && ref.read(playerProvider).isPlaying) setState(() => _controls = false);
    });
  }

  void _show() {
    setState(() => _controls = true);
    _armHide();
  }

  void _toggleControls() {
    if (_controls) {
      _hide?.cancel();
      setState(() => _controls = false);
    } else {
      _show();
    }
  }

  void _qualityMenu() {
    final current = ref.read(twitchQualityProvider);
    final names = <String>{'best', for (final v in widget.variants) v.audioOnly ? 'audio_only' : RegExp(r'^\d+p').firstMatch(v.name)?.group(0) ?? v.name};
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: UT.surface1,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(alignment: Alignment.centerLeft, child: Text('Qualidade', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            ),
            for (final q in names)
              ListTile(
                leading: Icon(q == current ? Icons.radio_button_checked : Icons.radio_button_off, color: q == current ? UT.twitch : UT.text2),
                title: Text(_qualityLabel(q)),
                onTap: () {
                  Navigator.pop(context);
                  if (q != current) widget.onQuality(q);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _qualityLabel(String q) {
    if (q == 'best') return 'Automática (melhor)';
    if (q == 'audio_only') return 'Só áudio';
    final v = widget.variants.where((v) => v.name.startsWith(q)).firstOrNull;
    return v?.label ?? q;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerProvider.select((s) => s.isPlaying), (was, playing) {
      if (!mounted) return;
      if (playing && _controls) _armHide();
      if (!playing && was == true && !_controls) _show();
    });
    final state = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final prefs = ref.watch(liveChatPrefsProvider);
    final mine = state.currentTrack?.spotifyId == widget.trackId;
    final started = mine && (state.position > Duration.zero || state.isPlaying || state.duration > Duration.zero);
    final loading = widget.starting || (mine && state.isLoadingVideo) || (!started && widget.error == null);
    final session = widget.session;
    final failed = widget.error != null || (mine && state.loadError != null);
    final duration = state.duration.inMilliseconds.toDouble();
    final position = (_drag ?? state.position.inMilliseconds.toDouble()).clamp(0.0, duration <= 0 ? 1.0 : duration);

    return MouseRegion(
      onHover: (_) => _controls ? _armHide() : _show(),
      child: Container(
      key: widget.slotKey,
      color: started && !failed ? Colors.transparent : Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!started && widget.cover.isNotEmpty) Opacity(opacity: 0.45, child: NetImage(widget.cover)),
          if (loading && !failed) const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (failed)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.offline ? Icons.nightlight_round : Icons.error_outline, color: Colors.white),
                    const SizedBox(height: 8),
                    Text(
                      widget.offline ? '${widget.login} está offline' : (widget.error ?? 'Falha ao reproduzir'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        TextButton(onPressed: widget.onRestart, child: const Text('Tentar de novo')),
                        if (widget.offline) TextButton(onPressed: () => openTwitchChannel(context, widget.login), child: const Text('Ver vídeos do canal')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _controls ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: const ColoredBox(color: Colors.black38),
            ),
          ),
          GestureDetector(behavior: HitTestBehavior.translucent, onTap: _toggleControls),
          if (widget.live && session != null && prefs.overlay && started)
            AnimatedPositioned(
              duration: UT.motion,
              curve: UT.curve,
              left: 10,
              right: 10,
              top: 44,
              bottom: _controls ? 64 : 10,
              child: LiveChatOverlay(feed: session.chat, maxLines: widget.fullscreen ? 9 : 4, widthFactor: widget.fullscreen ? 0.4 : 0.7),
            ),
          // Ad-break status stays visible even with the controls hidden.
          if (widget.ad != TwitchAdState.none && started)
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(child: _AdPill(widget.ad)),
            ),
          IgnorePointer(
            ignoring: !_controls,
            child: AnimatedOpacity(
              opacity: _controls ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Stack(
                children: [
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      tooltip: 'Minimizar',
                      color: Colors.white,
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: () => widget.fullscreen ? widget.onFullscreen() : context.pop(),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Row(
                      children: [
                        if (widget.live)
                          IconButton(
                            tooltip: 'Ajustes do chat ao vivo',
                            color: Colors.white,
                            icon: const Icon(Icons.tune_rounded),
                            onPressed: () => showLiveChatSettings(context),
                          ),
                        IconButton(
                          tooltip: 'Qualidade',
                          color: Colors.white,
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: widget.variants.isEmpty ? null : _qualityMenu,
                        ),
                      ],
                    ),
                  ),
                  Center(
                    child: IconButton(
                      iconSize: 56,
                      color: Colors.white,
                      tooltip: state.isPlaying ? 'Pausar' : 'Reproduzir',
                      icon: Icon(state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      onPressed: !mine
                          ? null
                          : () {
                              if (widget.live && state.isPlaying) setState(() => _behind = true);
                              notifier.togglePlay();
                              _show();
                            },
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 4,
                    bottom: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (widget.live) ...[
                              LiveBadge(
                                behind: _behind,
                                onTap: _behind
                                    ? () {
                                        setState(() => _behind = false);
                                        widget.onRestart();
                                      }
                                    : null,
                              ),
                              if (session != null) ...[const SizedBox(width: 6), ViewerCountChip(viewers: session.viewers)],
                            ] else
                              Text(
                                '${durationLabel(position ~/ 1000).isEmpty ? '0:00' : durationLabel(position ~/ 1000)} / ${durationLabel(state.duration.inSeconds)}',
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            const Spacer(),
                            if (widget.live && session != null)
                              IconButton(
                                color: Colors.white,
                                tooltip: prefs.overlay ? 'Ocultar chat do vídeo' : 'Mostrar chat no vídeo',
                                icon: Icon(prefs.overlay ? Icons.chat_rounded : Icons.chat_outlined),
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  ref.read(liveChatPrefsProvider.notifier).toggleOverlay();
                                  _show();
                                },
                              ),
                            IconButton(
                              color: Colors.white,
                              tooltip: widget.fullscreen ? 'Sair da tela cheia' : 'Tela cheia',
                              icon: Icon(widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                              onPressed: widget.onFullscreen,
                            ),
                          ],
                        ),
                        if (widget.live)
                          Container(height: 3, margin: const EdgeInsets.fromLTRB(0, 4, 8, 10), color: UT.twitch)
                        else
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                              activeTrackColor: UT.twitch,
                              thumbColor: UT.twitch,
                              inactiveTrackColor: Colors.white30,
                            ),
                            child: SizedBox(
                              height: 24,
                              child: Slider(
                                value: position.toDouble(),
                                max: duration <= 0 ? 1 : duration,
                                onChanged: duration <= 0 ? null : (v) => setState(() => _drag = v),
                                onChangeEnd: (v) {
                                  notifier.seekTo(Duration(milliseconds: v.round()));
                                  setState(() => _drag = null);
                                  _show();
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

class _AdPill extends StatelessWidget {
  const _AdPill(this.state);
  final TwitchAdState state;
  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (state) {
      TwitchAdState.backup => (Icons.shield_rounded, 'Anúncio bloqueado · qualidade reduzida no intervalo'),
      _ => (Icons.shield_outlined, 'Anúncio bloqueado · voltando em instantes'),
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(20), border: Border.all(color: UT.twitch.withValues(alpha: 0.7))),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: UT.twitch),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
