import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/ultratube_catalog.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/ultratube/ultratube_store.dart';
import 'yt_widgets.dart';

const _kinds = {
  'all': 'Tudo',
  'videos': 'Vídeos',
  'shorts': 'Shorts',
  'music': 'Músicas',
  'channels': 'Canais',
  'playlists': 'Playlists',
  'music_albums': 'Álbuns',
  'music_videos': 'Clipes',
};

class YtSearchScreen extends ConsumerStatefulWidget {
  const YtSearchScreen({super.key, this.initialKind = 'all', this.initialQuery = ''});
  final String initialKind;
  final String initialQuery;
  @override
  ConsumerState<YtSearchScreen> createState() => _YtSearchScreenState();
}

class _YtSearchScreenState extends ConsumerState<YtSearchScreen> {
  static const _catalog = UltratubeCatalog();
  late final _query = TextEditingController(text: widget.initialQuery);
  final _focus = FocusNode();
  late String _kind = _kinds.containsKey(widget.initialKind) ? widget.initialKind : 'all';
  List<String> _suggestions = const [];
  List<YtItem> _results = const [];
  String? _next;
  String _suggestion = '';
  bool _corrected = false;
  String? _submitted;
  bool _busy = false;
  String? _error;
  int _generation = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) {
      _search(widget.initialQuery);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _typed(String text) {
    setState(() => _submitted = null);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final s = await _catalog.suggestions(text);
        if (mounted && _query.text == text) setState(() => _suggestions = s);
      } catch (_) {}
    });
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _query.text = q;
    _focus.unfocus();
    ref.read(searchHistoryProvider.notifier).add(q);
    final generation = ++_generation;
    setState(() {
      _submitted = q;
      _busy = true;
      _error = null;
      _results = const [];
      _next = null;
    });
    try {
      final page = await _catalog.searchItems(q, kind: _kind);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = page.items;
        _next = page.next;
        _suggestion = page.suggestion;
        _corrected = page.corrected;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = '$error');
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _more() async {
    final token = _next;
    if (token == null || _busy) return;
    final generation = _generation;
    setState(() => _busy = true);
    try {
      final page = await _catalog.more(token);
      if (!mounted || generation != _generation) return;
      final seen = {for (final r in _results) r.url};
      setState(() {
        _results = [..._results, ...page.items.where((i) => seen.add(i.url))];
        _next = page.next;
      });
    } catch (_) {
      _next = null;
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final history = ref.watch(searchHistoryProvider);
    final typing = _submitted == null;
    final shorts = [for (final r in _results) if (r.shorts) r];

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 0,
        title: TextField(
          controller: _query,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onChanged: _typed,
          onSubmitted: _search,
          onTap: () => setState(() => _submitted = null),
          decoration: InputDecoration(
            hintText: 'Pesquisar no YouTube',
            filled: true,
            fillColor: colors.surfaceContainerHighest,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Limpar',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _query.clear();
                      _typed('');
                      _focus.requestFocus();
                    },
                  ),
          ),
        ),
        actions: [IconButton(tooltip: 'Buscar', icon: const Icon(Icons.search), onPressed: () => _search(_query.text))],
      ),
      body: typing
          ? ListView(
              children: [
                for (final s in (_query.text.isEmpty ? history : _suggestions))
                  ListTile(
                    leading: Icon(_query.text.isEmpty ? Icons.history : Icons.search),
                    title: Text(s),
                    trailing: IconButton(
                      tooltip: 'Usar na busca',
                      icon: const Icon(Icons.north_west),
                      onPressed: () {
                        _query.text = s;
                        _query.selection = TextSelection.collapsed(offset: s.length);
                        _typed(s);
                      },
                    ),
                    onTap: () => _search(s),
                    onLongPress: _query.text.isEmpty ? () => ref.read(searchHistoryProvider.notifier).remove(s) : null,
                  ),
              ],
            )
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 900) _more();
                return false;
              },
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                        children: [
                          for (final entry in _kinds.entries)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(entry.value),
                                selected: _kind == entry.key,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() => _kind = entry.key);
                                  _search(_submitted ?? _query.text);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_suggestion.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Text.rich(
                          TextSpan(
                            style: const TextStyle(fontSize: 13.5, color: UT.text2),
                            children: [
                              TextSpan(text: _corrected ? 'Mostrando resultados para ' : 'Você quis dizer: '),
                              TextSpan(
                                text: _suggestion,
                                style: const TextStyle(color: UT.text, fontWeight: FontWeight.w700, fontStyle: FontStyle.italic),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_suggestion.isNotEmpty && !_corrected)
                    SliverToBoxAdapter(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: TextButton(onPressed: () => _search(_suggestion), child: Text('Buscar "$_suggestion"')),
                        ),
                      ),
                    ),
                  if (_busy && _results.isEmpty) const SliverToBoxAdapter(child: FeedSkeleton(count: 2)),
                  if (_error != null && _results.isEmpty)
                    SliverToBoxAdapter(child: ErrorRetry(message: 'A busca falhou.', onRetry: () => _search(_submitted!))),
                  if (!_busy && _error == null && _results.isEmpty)
                    const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Nenhum resultado')))),
                  if (_kind == 'shorts')
                    SliverPadding(
                      padding: const EdgeInsets.all(8),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 9 / 16,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        itemCount: shorts.length,
                        itemBuilder: (context, i) => GestureDetector(
                          onTap: () => openItem(context, shorts[i], shortsFeed: shorts),
                          child: ClipRRect(borderRadius: BorderRadius.circular(10), child: NetImage(shorts[i].cover)),
                        ),
                      ),
                    )
                  else ...[
                    if (_kind == 'all' && shorts.isNotEmpty) SliverToBoxAdapter(child: ShortsShelf(shorts)),
                    SliverList.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final item = _results[i];
                        if (item.shorts && _kind == 'all') return const SizedBox.shrink();
                        return switch (item.kind) {
                          YtKind.channel => ChannelTile(item),
                          YtKind.playlist => VideoRow(item),
                          _ when _kind.startsWith('music') => VideoRow(item),
                          _ => VideoCard(item),
                        };
                      },
                    ),
                  ],
                  SliverToBoxAdapter(
                    child: _busy && _results.isNotEmpty
                        ? const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
                        : const SizedBox(height: 140),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Recently watched videos, with pause/clear controls.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    final notifier = ref.read(historyProvider.notifier);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: const Text('Histórico'),
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'pause') notifier.paused = !notifier.paused;
              if (v == 'clear') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Limpar histórico?'),
                    content: const Text('As recomendações de "Para você" usam o histórico.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
                      FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Limpar')),
                    ],
                  ),
                );
                if (ok == true) notifier.clear();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'pause', child: Text(notifier.paused ? 'Retomar histórico' : 'Pausar histórico')),
              const PopupMenuItem(value: 'clear', child: Text('Limpar histórico')),
            ],
          ),
        ],
      ),
      body: history.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 56, color: colors.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text(notifier.paused ? 'O histórico está pausado' : 'Nada assistido ainda'),
                  const SizedBox(height: 12),
                  TextButton(onPressed: () => context.go('/home'), child: const Text('Explorar vídeos')),
                ],
              ),
            )
          : ListView.builder(
              itemCount: history.length,
              itemBuilder: (context, i) => Dismissible(
                key: ValueKey(history[i].url),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  color: colors.errorContainer,
                  child: const Icon(Icons.delete_outline),
                ),
                onDismissed: (_) => notifier.remove(history[i]),
                child: VideoRow(history[i]),
              ),
            ),
    );
  }
}
