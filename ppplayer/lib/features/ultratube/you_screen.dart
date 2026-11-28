import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/yt_models.dart';
import '../../core/downloads/ultratube_downloads.dart';
import '../../core/services/settings_provider.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/ultratube/feeds.dart';
import '../../core/ultratube/ultratube_store.dart';
import '../../core/ultratube/youtube_account.dart';
import '../../core/ai/video_assistant.dart';
import '../live/live_chat_view.dart';
import 'pip_button.dart';
import 'playlist_picker.dart';
import 'yt_widgets.dart';

/// "Você": history, playlists, likes, downloads and preferences.
class YouScreen extends ConsumerWidget {
  const YouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    final playlists = ref.watch(playlistsProvider);
    final saved = ref.watch(savedPlaylistsProvider);
    final liked = ref.watch(likedProvider);
    final downloads = ref.watch(downloadsProvider).value ?? const <DownloadJob>[];
    final doneDownloads = downloads.where((d) => d.state == DownloadState.done).length;
    final subs = ref.watch(subscriptionsProvider).length;
    final account = ref.watch(youtubeAccountProvider);

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            title: const Text('Você'),
            actions: [
              IconButton(tooltip: 'Buscar', icon: const Icon(Icons.search), onPressed: () => context.push('/search')),
              IconButton(tooltip: 'Configurações', icon: const Icon(Icons.settings_outlined), onPressed: () => _settings(context)),
            ],
          ),
          SliverToBoxAdapter(
            child: _AccountHeader(summary: '$subs inscrições · ${history.length} assistidos · sem anúncios'),
          ),
          _Section(
            title: 'Histórico',
            onMore: () => context.push('/history'),
            child: history.isEmpty
                ? const _Empty('Os vídeos que você assistir aparecem aqui')
                : SizedBox(
                    height: 150,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: UT.s4),
                      itemCount: history.length.clamp(0, 20),
                      separatorBuilder: (_, _) => const SizedBox(width: UT.s3),
                      itemBuilder: (context, i) => _SmallCard(item: history[i]),
                    ),
                  ),
          ),
          _Section(
            title: 'Playlists',
            onMore: () => saveToNewPlaylist(context, ref, const []),
            moreLabel: 'Nova',
            child: SizedBox(
              height: 168,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: UT.s4),
                children: [
                  _PlaylistCard(
                    title: 'Vídeos curtidos',
                    subtitle: '${liked.length} vídeos',
                    cover: liked.isEmpty ? '' : liked.first.bestCover,
                    icon: Icons.thumb_up,
                    onTap: () => context.push('/myplaylist/liked'),
                  ),
                  for (final p in playlists)
                    _PlaylistCard(
                      title: p.title,
                      subtitle: '${p.items.length} vídeos',
                      cover: p.cover,
                      onTap: () => context.push('/myplaylist/${p.id}'),
                    ),
                  for (final p in saved)
                    _PlaylistCard(
                      title: p.title,
                      subtitle: p.channel.isEmpty ? 'YouTube' : p.channel,
                      cover: p.bestCover,
                      onTap: () => context.push('/ytplaylist?url=${Uri.encodeComponent(p.url)}'),
                    ),
                ],
              ),
            ),
          ),
          SliverList.list(
            children: [
              const SizedBox(height: UT.s2),
              _Row(icon: Icons.download_outlined, title: 'Downloads', subtitle: '$doneDownloads offline', onTap: () => context.push('/downloads')),
              _Row(icon: Icons.history, title: 'Histórico', onTap: () => context.push('/history')),
              _Row(icon: Icons.subscriptions_outlined, title: 'Inscrições', subtitle: '$subs canais', onTap: () => context.go('/subscriptions')),
              _Row(icon: Icons.library_music_outlined, title: 'Arquivos do aparelho', subtitle: 'Músicas e vídeos locais', onTap: () => context.push('/library')),
              _Row(icon: Icons.tune, title: 'Reprodução e qualidade', onTap: () => _settings(context)),
              if (account != null) ...[
                _Row(
                  icon: Icons.sync,
                  title: 'Sincronizar inscrições do YouTube',
                  subtitle: 'Traz os canais que você segue na conta',
                  onTap: () => _sync(context, ref),
                ),
                if (YoutubeAccountApi.watchLinkSupported)
                  _Row(
                    icon: Icons.watch_outlined,
                    title: 'Conectar relógio',
                    subtitle: 'Entra com esta conta no Ultratube do Galaxy Watch',
                    onTap: () => const YoutubeAccountApi().linkWatch(),
                  ),
                _Row(icon: Icons.logout, title: 'Sair da conta do YouTube', onTap: () => _signOut(context, ref)),
              ],
              const SizedBox(height: 140),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Sincronizando inscrições…')));
    try {
      final added = await ref.read(youtubeAccountProvider.notifier).syncSubscriptions();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(added == 0 ? 'Inscrições já estão em dia' : '$added novas inscrições importadas')),
      );
    } catch (error) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Não foi possível sincronizar: ${_reason(error)}')));
    }
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sair da conta do YouTube?'),
        content: const Text('Suas inscrições, histórico e playlists continuam neste aparelho.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sair')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(youtubeAccountProvider.notifier).signOut();
    unawaited(ref.read(forYouFeedProvider.notifier).refresh());
  }

  void _settings(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = ref.watch(videoQualityProvider);
    final audioQuality = ref.watch(audioQualityProvider);
    final audioOnly = ref.watch(audioOnlyProvider);
    final dataSaver = ref.watch(mobileDataSaverProvider);
    final autoplay = ref.watch(ultratubeAutoplayProvider);
    final skip = ref.watch(sponsorSkipProvider);
    final pip = ref.watch(settingsProvider.select((s) => s.continuePlaybackInPip));
    ref.watch(historyProvider);
    final history = ref.read(historyProvider.notifier);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(UT.s5, 0, UT.s5, UT.s2),
            child: Text('Reprodução e qualidade', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          ListTile(
            leading: const Icon(Icons.hd_outlined),
            title: const Text('Qualidade máxima do vídeo'),
            trailing: DropdownButton<int>(
              value: quality,
              underline: const SizedBox(),
              borderRadius: BorderRadius.circular(UT.rMd),
              dropdownColor: UT.surface2,
              items: [
                for (final h in VideoQualityNotifier.options)
                  DropdownMenuItem(value: h, child: Text(h >= 2160 ? '4K' : '${h}p')),
              ],
              onChanged: (v) => v == null ? null : ref.read(videoQualityProvider.notifier).set(v),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: const Text('Qualidade do áudio'),
            subtitle: Text(AudioQualityNotifier.label(audioQuality)),
            trailing: DropdownButton<String>(
              value: audioQuality,
              underline: const SizedBox(),
              borderRadius: BorderRadius.circular(UT.rMd),
              dropdownColor: UT.surface2,
              items: const [
                DropdownMenuItem(value: 'low', child: Text('Econômica')),
                DropdownMenuItem(value: 'normal', child: Text('Normal')),
                DropdownMenuItem(value: 'high', child: Text('Alta')),
              ],
              onChanged: (v) => v == null ? null : ref.read(audioQualityProvider.notifier).set(v),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.headphones_outlined),
            title: const Text('Só áudio'),
            subtitle: const Text('Vídeos tocam sem imagem: só a faixa de áudio é baixada (Shorts continuam com vídeo)'),
            value: audioOnly,
            onChanged: (v) {
              ref.read(audioOnlyProvider.notifier).set(v);
              ref.read(settingsProvider.notifier).setPlayerView(v ? PlayerView.artwork : PlayerView.video);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.signal_cellular_alt),
            title: const Text('Economia na rede móvel'),
            subtitle: const Text('Fora do Wi-Fi: vídeo até 480p e áudio econômico'),
            value: dataSaver,
            onChanged: ref.read(mobileDataSaverProvider.notifier).set,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.playlist_play),
            title: const Text('Reprodução automática'),
            subtitle: const Text('Toca o próximo vídeo relacionado'),
            value: autoplay,
            onChanged: ref.read(ultratubeAutoplayProvider.notifier).set,
          ),
          if (pipSupported)
            SwitchListTile(
              secondary: const Icon(Icons.picture_in_picture_alt_outlined),
              title: const Text('Janela flutuante (PiP)'),
              subtitle: const Text('Ao sair do app, o vídeo que está tocando continua numa janela sobre as outras'),
              value: pip,
              onChanged: ref.read(settingsProvider.notifier).toggleContinuePlaybackInPip,
            ),
          SwitchListTile(
            secondary: const Icon(Icons.fast_forward_outlined),
            title: const Text('Pular patrocínios'),
            subtitle: const Text('SponsorBlock: patrocínio, autopromoção e trechos sem música'),
            value: skip,
            onChanged: ref.read(sponsorSkipProvider.notifier).set,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.history_toggle_off),
            title: const Text('Pausar histórico'),
            subtitle: const Text('Não registra o que você assiste'),
            value: history.paused,
            onChanged: (v) => history.paused = v,
          ),
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const Text('Chat ao vivo'),
            subtitle: const Text('Chat sobre o vídeo, transparência e contador de espectadores'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLiveChatSettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome),
            title: const Text('Perguntar (Gemini)'),
            subtitle: const Text('Chave da API e modelo usados para resumir vídeos'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog<void>(context: context, builder: (_) => const _GeminiDialog()),
          ),
          const SizedBox(height: UT.s4),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.onMore, this.moreLabel = 'Ver tudo'});
  final String title;
  final Widget child;
  final VoidCallback? onMore;
  final String moreLabel;
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.only(bottom: UT.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(UT.s4, 0, UT.s2, UT.s2),
            child: Row(
              children: [
                Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
                const Spacer(),
                if (onMore != null)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: onMore,
                    child: Text(moreLabel),
                  ),
              ],
            ),
          ),
          child,
        ],
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: UT.s4),
    child: Text(text, style: const TextStyle(color: UT.text2)),
  );
}

class _SmallCard extends StatelessWidget {
  const _SmallCard({required this.item});
  final YtItem item;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 160,
    child: InkWell(
      borderRadius: BorderRadius.circular(UT.rSm),
      onTap: () => openItem(context, item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Thumbnail(item, radius: UT.rSm),
          const SizedBox(height: 6),
          Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.25)),
          Text(item.channel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: UT.text2)),
        ],
      ),
    ),
  );
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.title, required this.subtitle, required this.cover, required this.onTap, this.icon});
  final String title;
  final String subtitle;
  final String cover;
  final IconData? icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: UT.s3),
    child: SizedBox(
      width: 160,
      child: InkWell(
        borderRadius: BorderRadius.circular(UT.rSm),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Stacked-card look, like YouTube playlist tiles.
            Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 10,
                  right: 10,
                  top: -5,
                  child: Container(height: 10, decoration: BoxDecoration(color: UT.surface3, borderRadius: BorderRadius.circular(6))),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(UT.rSm),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        NetImage(cover, icon: icon ?? Icons.playlist_play),
                        if (icon != null && cover.isEmpty) const SizedBox(),
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                            child: Icon(icon ?? Icons.playlist_play, size: 14, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: UT.text2, fontSize: 11.5)),
          ],
        ),
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.onTap, this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: UT.s5),
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const Icon(Icons.chevron_right, color: UT.text3),
    onTap: onTap,
  );
}

String _reason(Object error) {
  final text = error is PlatformException ? (error.message ?? error.code) : '$error';
  return text.replaceFirst(RegExp(r'^(Bad state|Exception): '), '');
}

/// Profile header: the YouTube account when signed in, otherwise the
/// Ultratube mark and a one-tap "Entrar com Google".
class _AccountHeader extends ConsumerStatefulWidget {
  const _AccountHeader({required this.summary});
  final String summary;
  @override
  ConsumerState<_AccountHeader> createState() => _AccountHeaderState();
}

class _AccountHeaderState extends ConsumerState<_AccountHeader> {
  bool _busy = false;

  Future<void> _signIn() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final message = await ref.read(youtubeAccountProvider.notifier).signIn();
      if (message != null) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
        unawaited(ref.read(forYouFeedProvider.notifier).refresh());
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Não foi possível entrar: ${_reason(error)}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(youtubeAccountProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(UT.s4, UT.s2, UT.s4, UT.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (account != null && account.avatar.isNotEmpty)
                Avatar(account.avatar, size: 64)
              else
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [UT.red, UT.redDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  ),
                  child: const Icon(Icons.play_arrow_rounded, size: 38, color: Colors.white),
                ),
              const SizedBox(width: UT.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account?.name.isNotEmpty == true ? account!.name : 'Ultratube',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6),
                    ),
                    if (account != null && account.handle.isNotEmpty)
                      Text(account.handle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: UT.text2, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(widget.summary, style: const TextStyle(color: UT.text2, fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
          if (account == null && YoutubeAccountApi.signInSupported) ...[
            const SizedBox(height: UT.s4),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _busy ? null : _signIn,
                icon: _busy
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.account_circle_outlined),
                label: Text(_busy ? 'Entrando…' : 'Entrar com Google'),
              ),
            ),
            const SizedBox(height: UT.s2),
            const Text(
              'Opcional. Usa a página normal de login do Google e traz suas inscrições e recomendações.',
              style: TextStyle(color: UT.text3, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// Gemini key + model for the "Perguntar" assistant.
class _GeminiDialog extends StatefulWidget {
  const _GeminiDialog();
  @override
  State<_GeminiDialog> createState() => _GeminiDialogState();
}

class _GeminiDialogState extends State<_GeminiDialog> {
  final _key = TextEditingController();
  late final _model = TextEditingController(text: VideoAssistant.instance.model);
  bool? _hasKey;

  @override
  void initState() {
    super.initState();
    VideoAssistant.instance.apiKey().then((k) {
      if (mounted) setState(() => _hasKey = k != null);
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_key.text.trim().isNotEmpty) await VideoAssistant.instance.setApiKey(_key.text);
    VideoAssistant.instance.model = _model.text;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Perguntar (Gemini)'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _hasKey == null ? '' : (_hasKey! ? 'Chave salva neste aparelho.' : 'Nenhuma chave salva.'),
          style: const TextStyle(color: UT.text2),
        ),
        const SizedBox(height: UT.s3),
        TextField(
          controller: _key,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: _hasKey == true ? 'Nova chave (opcional)' : 'Chave da API do Gemini',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: UT.s3),
        TextField(
          controller: _model,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Modelo',
            helperText: 'Padrão: ${VideoAssistant.defaultModel}',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    ),
    actions: [
      if (_hasKey == true)
        TextButton(
          onPressed: () async {
            await VideoAssistant.instance.setApiKey(null);
            if (mounted) setState(() => _hasKey = false);
          },
          child: const Text('Remover chave'),
        ),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _save, child: const Text('Salvar')),
    ],
  );
}
