import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/ultratube_theme.dart';
import '../../core/twitch/twitch_account.dart';
import '../../core/twitch/twitch_api.dart';
import '../../core/twitch/twitch_providers.dart';
import '../../core/twitch/twitch_store.dart';
import '../ultratube/yt_widgets.dart' show Avatar, ErrorRetry;
import 'twitch_account_sheet.dart';
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
  String? _genre; // Categorias: genre tag filter

  @override
  Widget build(BuildContext context) {
    final follows = ref.watch(twitchFollowsProvider);
    // Open on "Seguindo" once the user follows someone, like the Twitch app.
    final tab = _tab ?? (follows.isEmpty ? _Tab.top : _Tab.following);
    final language = ref.watch(twitchLanguageProvider);

    Future<void> refresh() async {
      switch (tab) {
        case _Tab.following:
          // Signed in: also pick up channels followed on Twitch meanwhile.
          await ref.read(twitchAccountProvider.notifier).syncFollows().then((_) {}, onError: (Object _) {});
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
                const _AccountButton(),
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
      if (ref.watch(twitchGamesProvider).value case final games? when games.isNotEmpty)
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
                child: Row(
                  children: [
                    const Expanded(child: Text('Categorias em alta', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                    TextButton(onPressed: () => setState(() => _tab = _Tab.categories), child: const Text('Ver todas')),
                  ],
                ),
              ),
              SizedBox(
                height: 196,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: games.length.clamp(0, 12),
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => SizedBox(width: 104, child: TwitchGameTile(games[i])),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Text('Ao vivo agora', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ],
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
      data: (list) {
        // Genres present in the list, most common first.
        final counts = <String, int>{};
        for (final g in list) {
          for (final t in g.tags) {
            counts[t] = (counts[t] ?? 0) + 1;
          }
        }
        final genres = (counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!))).take(14).toList();
        final genre = genres.contains(_genre) ? _genre : null;
        final shown = genre == null ? list : list.where((g) => g.tags.contains(genre)).toList();
        return [
          if (genres.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    TwitchChip(label: 'Todos os gêneros', selected: genre == null, onTap: () => setState(() => _genre = null)),
                    for (final g in genres) TwitchChip(label: g, selected: genre == g, onTap: () => setState(() => _genre = g)),
                  ],
                ),
              ),
            ),
          SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 12), sliver: twitchGameGrid(context, shown)),
        ];
      },
    );
  }

  List<Widget> _following(BuildContext context) {
    final follows = ref.watch(twitchFollowsProvider);
    final signedIn = ref.watch(twitchAccountProvider) != null;
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
                  Text(
                    signedIn
                        ? 'Sua conta ainda não segue nenhum canal. Siga canais aqui ou na Twitch; quem estiver ao vivo aparece primeiro.'
                        : 'Entre na Twitch para trazer os canais que você já segue, ou siga canais só neste aparelho, sem conta.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: UT.text2),
                  ),
                  const SizedBox(height: UT.s4),
                  if (!signedIn) ...[
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: UT.twitch, foregroundColor: Colors.white),
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('Entrar na Twitch'),
                      onPressed: () => showTwitchAccountSheet(context),
                    ),
                    const SizedBox(height: UT.s2),
                  ],
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: UT.text, side: const BorderSide(color: UT.line)),
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

/// Opens the account sheet; shows the profile photo once signed in.
class _AccountButton extends ConsumerWidget {
  const _AccountButton();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(twitchAccountProvider);
    return IconButton(
      tooltip: account == null ? 'Entrar na Twitch' : 'Conta da Twitch (${account.name})',
      onPressed: () => showTwitchAccountSheet(context),
      icon: account == null || account.avatar.isEmpty
          ? Icon(account == null ? Icons.account_circle_outlined : Icons.account_circle, color: account == null ? null : UT.twitch)
          : Container(
              padding: const EdgeInsets.all(1.5),
              decoration: const BoxDecoration(shape: BoxShape.circle, color: UT.twitch),
              child: Avatar(account.avatar, size: 24),
            ),
    );
  }
}
