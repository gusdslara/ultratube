import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/ultratube_theme.dart';
import '../../core/twitch/twitch_api.dart';
import '../../core/twitch/twitch_providers.dart';
import '../../core/twitch/twitch_store.dart';
import '../ultratube/yt_widgets.dart' show Avatar, ErrorRetry, NetImage;
import 'twitch_widgets.dart';

enum _Tab { following, top, categories }

/// Twitch tab: followed channels, most watched lives and categories, with a
/// language filter. No account, no ads (see TwitchProxy).
class TwitchHomeScreen extends ConsumerStatefulWidget {
  const TwitchHomeScreen({super.key});
  @override
  ConsumerState<TwitchHomeScreen> createState() => _TwitchHomeScreenState();
}

class _TwitchHomeScreenState extends ConsumerState<TwitchHomeScreen> {
  _Tab? _tab;

  @override
  Widget build(BuildContext context) {
    final follows = ref.watch(twitchFollowsProvider);
    // Open on "Seguindo" once the user follows someone, like the Twitch app.
    final tab = _tab ?? (follows.isEmpty ? _Tab.top : _Tab.following);
    final language = ref.watch(twitchLanguageProvider);

    Future<void> refresh() async {
      switch (tab) {
        case _Tab.following:
          ref.invalidate(twitchFollowedProvider);
          await ref.read(twitchFollowedProvider.future).catchError((_) => <TwitchChannel>[]);
        case _Tab.top:
          ref.invalidate(twitchTopProvider(language));
          await ref.read(twitchTopProvider(language).future).catchError((_) => <TwitchStream>[]);
        case _Tab.categories:
          ref.invalidate(twitchGamesProvider);
          await ref.read(twitchGamesProvider.future).catchError((_) => <TwitchGame>[]);
      }
    }

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: UT.twitch,
        onRefresh: refresh,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: true,
              snap: true,
              backgroundColor: UT.bg,
              surfaceTintColor: Colors.transparent,
              titleSpacing: 12,
              title: const _TwitchLogo(),
              actions: [
                IconButton(tooltip: 'Buscar na Twitch', icon: const Icon(Icons.search), onPressed: () => context.push('/twitch/search')),
                PopupMenuButton<String>(
                  tooltip: 'Idioma das transmissões',
                  icon: const Icon(Icons.translate_rounded),
                  initialValue: language,
                  onSelected: ref.read(twitchLanguageProvider.notifier).set,
                  itemBuilder: (_) => [
                    for (final e in TwitchLanguageNotifier.options.entries)
                      CheckedPopupMenuItem(value: e.key, checked: e.key == language, child: Text(e.value)),
                  ],
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    children: [
                      TwitchChip(label: 'Seguindo', icon: Icons.favorite_border_rounded, selected: tab == _Tab.following, onTap: () => setState(() => _tab = _Tab.following)),
                      TwitchChip(label: 'Ao vivo agora', selected: tab == _Tab.top, onTap: () => setState(() => _tab = _Tab.top)),
                      TwitchChip(label: 'Categorias', selected: tab == _Tab.categories, onTap: () => setState(() => _tab = _Tab.categories)),
                    ],
                  ),
                ),
              ),
            ),
            ...switch (tab) {
              _Tab.following => _following(context),
              _Tab.top => _top(context, language),
              _Tab.categories => _categories(context),
            },
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }

  List<Widget> _top(BuildContext context, String language) {
    final top = ref.watch(twitchTopProvider(language));
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: [
              const Icon(Icons.shield_outlined, size: 16, color: UT.text2),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Sem anúncios · ${TwitchLanguageNotifier.options[language] ?? 'Todos os idiomas'}',
                  style: const TextStyle(color: UT.text2, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
      ),
      ...top.when(
        loading: () => [const SliverToBoxAdapter(child: TwitchSkeleton())],
        error: (e, _) => [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: ErrorRetry(message: 'Não foi possível carregar a Twitch.\n$e', onRetry: () => ref.invalidate(twitchTopProvider(language)))),
          ),
        ],
        data: (streams) => streams.isEmpty
            ? [const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('Nenhuma live neste idioma agora.', style: TextStyle(color: UT.text2))))]
            : [twitchStreamSliver(context, streams)],
      ),
    ];
  }

  List<Widget> _categories(BuildContext context) {
    final games = ref.watch(twitchGamesProvider);
    return games.when(
      loading: () => [const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator(color: UT.twitch)))],
      error: (e, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: ErrorRetry(message: 'Não foi possível carregar as categorias.', onRetry: () => ref.invalidate(twitchGamesProvider))),
        ),
      ],
      data: (list) => [SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 12), sliver: twitchGameGrid(context, list))],
    );
  }

  List<Widget> _following(BuildContext context) {
    final follows = ref.watch(twitchFollowsProvider);
    if (follows.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(UT.s8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.favorite_border_rounded, size: 44, color: UT.text3),
                  const SizedBox(height: UT.s3),
                  const Text('Siga canais para vê-los aqui', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: UT.s2),
                  const Text(
                    'Os canais ficam salvos neste aparelho, sem conta da Twitch. Quem estiver ao vivo aparece primeiro.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: UT.text2),
                  ),
                  const SizedBox(height: UT.s4),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: UT.twitch, foregroundColor: Colors.white),
                    icon: const Icon(Icons.search),
                    label: const Text('Buscar canais'),
                    onPressed: () => context.push('/twitch/search'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }
    final followed = ref.watch(twitchFollowedProvider);
    return followed.when(
      loading: () => [const SliverToBoxAdapter(child: TwitchSkeleton(count: 2))],
      error: (e, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: ErrorRetry(message: 'Não foi possível verificar seus canais.', onRetry: () => ref.invalidate(twitchFollowedProvider))),
        ),
      ],
      data: (channels) {
        final live = channels.where((c) => c.isLive).toList();
        final offline = channels.where((c) => !c.isLive).toList();
        return [
          if (live.isNotEmpty) ...[
            _header('Ao vivo (${live.length})'),
            twitchStreamSliver(context, [for (final c in live) c.stream!]),
          ] else
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text('Nenhum canal que você segue está ao vivo agora.', style: TextStyle(color: UT.text2)),
              ),
            ),
          if (offline.isNotEmpty) ...[
            _header('Offline'),
            SliverList.builder(
              itemCount: offline.length,
              itemBuilder: (context, i) {
                final c = offline[i];
                return ListTile(
                  onTap: () => openTwitchChannel(context, c.login),
                  leading: Opacity(opacity: 0.7, child: Avatar(c.avatar, size: 42)),
                  title: Text(c.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    c.lastStartedAt == null ? 'Offline' : 'Última live ${agoLabel(c.lastStartedAt)}${c.lastTitle.isEmpty ? '' : ' · ${c.lastTitle}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: UT.text2, fontSize: 12.5),
                  ),
                  trailing: FollowButton(login: c.login, displayName: c.displayName, avatar: c.avatar, compact: true),
                );
              },
            ),
          ],
        ];
      },
    );
  }

  Widget _header(String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
    ),
  );
}

class _TwitchLogo extends StatelessWidget {
  const _TwitchLogo();
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: UT.twitch, borderRadius: BorderRadius.circular(7)),
        child: const Icon(Icons.live_tv_rounded, color: Colors.white, size: 18),
      ),
      const SizedBox(width: 8),
      const Text('Lives', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
      const SizedBox(width: 6),
      const Text('Twitch', style: TextStyle(fontSize: 13, color: UT.text2, fontWeight: FontWeight.w600)),
    ],
  );
}

/// Search: channels (live first) and categories.
class TwitchSearchScreen extends ConsumerStatefulWidget {
  const TwitchSearchScreen({super.key});
  @override
  ConsumerState<TwitchSearchScreen> createState() => _TwitchSearchScreenState();
}

class _TwitchSearchScreenState extends ConsumerState<TwitchSearchScreen> {
  final _input = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    // A bare channel name/URL opens straight away.
    final url = RegExp(r'twitch\.tv/([A-Za-z0-9_]{2,25})').firstMatch(query);
    if (url != null) {
      openTwitchChannel(context, url.group(1)!);
      return;
    }
    setState(() => _query = query);
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.isEmpty ? null : ref.watch(twitchSearchProvider(_query));
    return Scaffold(
      backgroundColor: UT.bg,
      appBar: AppBar(
        backgroundColor: UT.bg,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 0,
        title: TextField(
          controller: _input,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: 'Buscar canais e categorias',
            filled: true,
            fillColor: UT.surface2,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            suffixIcon: IconButton(
              tooltip: 'Limpar',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () {
                _input.clear();
                setState(() => _query = '');
              },
            ),
          ),
        ),
        actions: [IconButton(tooltip: 'Buscar', icon: const Icon(Icons.search), onPressed: () => _submit(_input.text))],
      ),
      body: results == null
          ? const Center(child: Text('Digite o nome de um canal ou jogo', style: TextStyle(color: UT.text2)))
          : results.when(
              loading: () => const Center(child: CircularProgressIndicator(color: UT.twitch)),
              error: (e, _) => Center(child: ErrorRetry(message: 'A busca falhou.', onRetry: () => ref.invalidate(twitchSearchProvider(_query)))),
              data: (r) {
                final (channels, games) = r;
                if (channels.isEmpty && games.isEmpty) {
                  return const Center(child: Text('Nada encontrado.', style: TextStyle(color: UT.text2)));
                }
                return CustomScrollView(
                  slivers: [
                    if (games.isNotEmpty) ...[
                      const SliverToBoxAdapter(
                        child: Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 8), child: Text('Categorias', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 210,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: games.length,
                            separatorBuilder: (_, _) => const SizedBox(width: 10),
                            itemBuilder: (context, i) => SizedBox(width: 112, child: TwitchGameTile(games[i])),
                          ),
                        ),
                      ),
                    ],
                    if (channels.isNotEmpty) ...[
                      const SliverToBoxAdapter(
                        child: Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Canais', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                      ),
                      SliverList.builder(itemCount: channels.length, itemBuilder: (context, i) => TwitchChannelTile(channels[i])),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 140)),
                  ],
                );
              },
            ),
    );
  }
}

/// One category's lives.
class TwitchCategoryScreen extends ConsumerWidget {
  const TwitchCategoryScreen({super.key, required this.name});
  final String name;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(twitchLanguageProvider);
    final data = ref.watch(twitchCategoryProvider((name, language)));
    return Scaffold(
      backgroundColor: UT.bg,
      body: RefreshIndicator(
        color: UT.twitch,
        onRefresh: () async {
          ref.invalidate(twitchCategoryProvider((name, language)));
          await ref.read(twitchCategoryProvider((name, language)).future).catchError((_) => (null, <TwitchStream>[]));
        },
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: UT.bg,
              surfaceTintColor: Colors.transparent,
              title: Text(data.value?.$1?.displayName ?? name),
              actions: [
                PopupMenuButton<String>(
                  tooltip: 'Idioma',
                  icon: const Icon(Icons.translate_rounded),
                  initialValue: language,
                  onSelected: ref.read(twitchLanguageProvider.notifier).set,
                  itemBuilder: (_) => [
                    for (final e in TwitchLanguageNotifier.options.entries)
                      CheckedPopupMenuItem(value: e.key, checked: e.key == language, child: Text(e.value)),
                  ],
                ),
              ],
            ),
            if (data.value?.$1 case final game?)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 72,
                        child: AspectRatio(
                          aspectRatio: 285 / 380,
                          child: ClipRRect(borderRadius: BorderRadius.circular(UT.rSm), child: NetImage(game.boxArt, icon: Icons.sports_esports_outlined)),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(game.displayName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(viewersLabel(game.viewers), style: const TextStyle(color: UT.text2)),
                            Text('${data.value!.$2.length} lives · ${TwitchLanguageNotifier.options[language]}', style: const TextStyle(color: UT.text2)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ...data.when(
              loading: () => [const SliverToBoxAdapter(child: TwitchSkeleton())],
              error: (e, _) => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: ErrorRetry(message: 'Não foi possível abrir a categoria.', onRetry: () => ref.invalidate(twitchCategoryProvider((name, language))))),
                ),
              ],
              data: (d) => d.$2.isEmpty
                  ? [const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('Ninguém ao vivo nesta categoria e idioma.', style: TextStyle(color: UT.text2))))]
                  : [twitchStreamSliver(context, d.$2)],
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }
}
