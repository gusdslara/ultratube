import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/ultratube_theme.dart';
import '../../core/twitch/twitch_api.dart';
import '../../core/twitch/twitch_providers.dart';
import '../../core/twitch/twitch_store.dart';
import '../ultratube/yt_widgets.dart' show Avatar, ErrorRetry, NetImage;
import 'twitch_widgets.dart';

enum _Filter {
  all('Tudo'),
  channels('Canais'),
  games('Categorias'),
  live('Ao vivo'),
  videos('Vídeos');

  const _Filter(this.label);
  final String label;
}

/// Twitch search: suggestions while typing, then channels, categories, live
/// channels and videos, filterable.
class TwitchSearchScreen extends ConsumerStatefulWidget {
  const TwitchSearchScreen({super.key});
  @override
  ConsumerState<TwitchSearchScreen> createState() => _TwitchSearchScreenState();
}

class _TwitchSearchScreenState extends ConsumerState<TwitchSearchScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  /// What was searched (results shown) vs. what is being typed (suggestions).
  String _query = '';
  String _typing = '';
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String text) {
    setState(() {}); // clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _typing = text.trim());
    });
  }

  void _submit(String text) {
    final query = text.trim();
    if (query.isEmpty) return;
    // A pasted channel link opens straight away.
    final url = RegExp(r'twitch\.tv/([A-Za-z0-9_]{2,25})').firstMatch(query);
    if (url != null) {
      openTwitchChannel(context, url.group(1)!);
      return;
    }
    _debounce?.cancel();
    _focus.unfocus();
    ref.read(twitchSearchHistoryProvider.notifier).add(query);
    _input.value = TextEditingValue(text: query, selection: TextSelection.collapsed(offset: query.length));
    setState(() {
      _query = query;
      _typing = query;
      _filter = _Filter.all;
    });
  }

  void _clear() {
    _debounce?.cancel();
    _input.clear();
    setState(() {
      _query = '';
      _typing = '';
    });
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final showResults = _query.isNotEmpty && _typing == _query;
    return Scaffold(
      backgroundColor: UT.bg,
      appBar: AppBar(
        backgroundColor: UT.bg,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 0,
        title: TextField(
          controller: _input,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _changed,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: 'Canais, jogos e categorias',
            filled: true,
            fillColor: UT.surface2,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            suffixIcon: _input.text.isEmpty
                ? null
                : IconButton(tooltip: 'Limpar', icon: const Icon(Icons.close, size: 20), onPressed: _clear),
          ),
        ),
        actions: [IconButton(tooltip: 'Buscar', icon: const Icon(Icons.search), onPressed: () => _submit(_input.text))],
      ),
      body: showResults
          ? _results()
          : _typing.length >= 2
          ? _suggestions()
          : _start(),
    );
  }

  // ------------------------------------------------------------ nothing typed

  Widget _start() {
    final recent = ref.watch(twitchSearchHistoryProvider);
    final games = ref.watch(twitchGamesProvider);
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        if (recent.isNotEmpty) ...[
          const _Header('Buscas recentes'),
          SliverList.builder(
            itemCount: recent.length,
            itemBuilder: (context, i) => ListTile(
              dense: true,
              leading: const Icon(Icons.history, color: UT.text2),
              title: Text(recent[i], maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                tooltip: 'Remover da lista',
                icon: const Icon(Icons.close, size: 18, color: UT.text2),
                onPressed: () => ref.read(twitchSearchHistoryProvider.notifier).remove(recent[i]),
              ),
              onTap: () => _submit(recent[i]),
            ),
          ),
        ],
        ...games.when(
          loading: () => [const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(UT.s8), child: Center(child: CircularProgressIndicator(color: UT.twitch))))],
          // The search itself still works without the suggestions below.
          error: (_, _) => [
            if (recent.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('Digite o nome de um canal ou jogo', style: TextStyle(color: UT.text2))),
              ),
          ],
          data: (list) => [
            const _Header('Categorias em alta'),
            SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 12), sliver: twitchGameGrid(context, list.take(24).toList())),
          ],
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 140)),
      ],
    );
  }

  // --------------------------------------------------------------- typing

  Widget _suggestions() {
    final suggestions = ref.watch(twitchSuggestionsProvider(_typing));
    final list = suggestions.value ?? const <TwitchSuggestion>[];
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        ListTile(
          leading: const Icon(Icons.search, color: UT.text2),
          title: Text('Buscar "$_typing"', maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _submit(_typing),
        ),
        if (suggestions.isLoading && list.isEmpty) const LinearProgressIndicator(minHeight: 2, color: UT.twitch, backgroundColor: Colors.transparent),
        for (final s in list)
          if (s.login.isNotEmpty)
            ListTile(
              leading: Stack(
                clipBehavior: Clip.none,
                children: [
                  Avatar(s.image, size: 36),
                  if (s.live)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: UT.red, shape: BoxShape.circle, border: Border.all(color: UT.bg, width: 2)),
                      ),
                    ),
                ],
              ),
              title: Text(s.text, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.live ? 'Canal · ao vivo' : 'Canal', style: TextStyle(color: s.live ? UT.text : UT.text2, fontSize: 12.5)),
              onTap: () => s.live ? openTwitchLive(context, s.login) : openTwitchChannel(context, s.login),
            )
          else if (s.game.isNotEmpty)
            ListTile(
              leading: SizedBox(
                width: 36,
                height: 48,
                child: ClipRRect(borderRadius: BorderRadius.circular(4), child: NetImage(s.image, icon: Icons.sports_esports_outlined)),
              ),
              title: Text(s.text, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Categoria', style: TextStyle(color: UT.text2, fontSize: 12.5)),
              onTap: () => openTwitchCategory(context, s.game),
            )
          else
            ListTile(
              leading: const Icon(Icons.north_west_rounded, color: UT.text2, size: 20),
              title: Text(s.text, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _submit(s.text),
            ),
      ],
    );
  }

  // -------------------------------------------------------------- results

  Widget _results() {
    final results = ref.watch(twitchSearchProvider(_query));
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator(color: UT.twitch)),
      error: (e, _) => Center(child: ErrorRetry(message: 'A busca falhou.\nVerifique sua conexão.', onRetry: () => ref.invalidate(twitchSearchProvider(_query)))),
      data: (r) {
        if (r.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(UT.s8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.search_off_rounded, size: 44, color: UT.text3),
                  const SizedBox(height: UT.s3),
                  Text('Nada encontrado para "$_query".', textAlign: TextAlign.center, style: const TextStyle(color: UT.text2)),
                  const SizedBox(height: UT.s2),
                  const Text('Confira a grafia ou tente o nome do jogo.', textAlign: TextAlign.center, style: TextStyle(color: UT.text3, fontSize: 13)),
                ],
              ),
            ),
          );
        }
        final counts = {
          _Filter.channels: r.channels.length,
          _Filter.games: r.games.length,
          _Filter.live: r.streams.length,
          _Filter.videos: r.videos.length,
        };
        // A filter with nothing in it is not offered.
        final filters = [_Filter.all, for (final f in counts.keys) if (counts[f]! > 0) f];
        final filter = filters.contains(_filter) ? _filter : _Filter.all;
        return CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  children: [
                    for (final f in filters) TwitchChip(label: f.label, selected: f == filter, onTap: () => setState(() => _filter = f)),
                  ],
                ),
              ),
            ),
            ...switch (filter) {
              _Filter.all => _everything(r),
              _Filter.channels => [SliverList.builder(itemCount: r.channels.length, itemBuilder: (context, i) => TwitchChannelTile(r.channels[i]))],
              _Filter.games => [SliverPadding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), sliver: twitchGameGrid(context, r.games))],
              _Filter.live => [SliverList.builder(itemCount: r.streams.length, itemBuilder: (context, i) => TwitchStreamRow(r.streams[i]))],
              _Filter.videos => [SliverList.builder(itemCount: r.videos.length, itemBuilder: (context, i) => TwitchVodRow(r.videos[i], showChannel: true))],
            },
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        );
      },
    );
  }

  /// "Tudo": a few of each kind, with a way into the full list.
  List<Widget> _everything(TwitchSearchResults r) => [
    if (r.games.isNotEmpty) ...[
      _Header('Categorias', more: r.games.length > 4 ? () => setState(() => _filter = _Filter.games) : null),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: r.games.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) => SizedBox(width: 104, child: TwitchGameTile(r.games[i])),
          ),
        ),
      ),
    ],
    if (r.channels.isNotEmpty) ...[
      _Header('Canais', more: r.channels.length > 4 ? () => setState(() => _filter = _Filter.channels) : null),
      SliverList.builder(itemCount: r.channels.length.clamp(0, 4), itemBuilder: (context, i) => TwitchChannelTile(r.channels[i])),
    ],
    if (r.streams.isNotEmpty) ...[
      _Header('Ao vivo', more: r.streams.length > 4 ? () => setState(() => _filter = _Filter.live) : null),
      SliverList.builder(itemCount: r.streams.length.clamp(0, 4), itemBuilder: (context, i) => TwitchStreamRow(r.streams[i])),
    ],
    if (r.videos.isNotEmpty) ...[
      _Header('Vídeos', more: r.videos.length > 3 ? () => setState(() => _filter = _Filter.videos) : null),
      SliverList.builder(itemCount: r.videos.length.clamp(0, 3), itemBuilder: (context, i) => TwitchVodRow(r.videos[i], showChannel: true)),
    ],
  ];
}

class _Header extends StatelessWidget {
  const _Header(this.title, {this.more});
  final String title;
  final VoidCallback? more;
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.fromLTRB(16, 12, more == null ? 16 : 4, more == null ? 8 : 0),
      child: Row(
        children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          if (more != null) TextButton(onPressed: more, child: const Text('Ver todos')),
        ],
      ),
    ),
  );
}
