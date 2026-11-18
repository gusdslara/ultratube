import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/ultratube_catalog.dart';
import '../../core/ultratube/ultratube_store.dart';
import 'yt_widgets.dart';

const _tabLabels = {
  'videos': 'Vídeos',
  'shorts': 'Shorts',
  'livestreams': 'Ao vivo',
  'playlists': 'Playlists',
};

/// Channel page: banner, avatar, subscribe, and its Videos/Shorts/Live tabs.
class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({super.key, required this.url, this.title = ''});
  final String url;
  final String title;
  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  static const _catalog = UltratubeCatalog();
  YtChannel? _channel;
  String? _error;
  String _tab = 'videos';
  final Map<String, List<YtItem>> _items = {};
  final Map<String, String?> _next = {};
  bool _loadingTab = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final channel = await _catalog.channel(widget.url);
      if (!mounted) return;
      setState(() {
        _channel = channel;
        _tab = channel.tabs.isNotEmpty ? channel.tabs.first : 'videos';
        _items[_tab] = channel.videos.items;
        _next[_tab] = channel.videos.next;
      });
      ref.read(subscriptionsProvider.notifier).refresh(
        Subscription(url: widget.url, title: channel.title, avatar: channel.avatar),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _selectTab(String tab) async {
    setState(() => _tab = tab);
    if (_items.containsKey(tab)) return;
    setState(() => _loadingTab = true);
    try {
      final page = await _catalog.channelTab(widget.url, tab);
      if (!mounted) return;
      setState(() {
        _items[tab] = page.items;
        _next[tab] = page.next;
      });
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falha ao carregar: $error')));
    } finally {
      if (mounted) setState(() => _loadingTab = false);
    }
  }

  Future<void> _more() async {
    final token = _next[_tab];
    if (token == null || _loadingTab) return;
    final tab = _tab;
    setState(() => _loadingTab = true);
    try {
      final page = await _catalog.more(token);
      if (!mounted) return;
      setState(() {
        _items[tab] = [...?_items[tab], ...page.items];
        _next[tab] = page.next;
      });
    } catch (_) {
      _next[tab] = null;
    } finally {
      if (mounted) setState(() => _loadingTab = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final channel = _channel;
    final items = _items[_tab] ?? const <YtItem>[];
    final isShorts = _tab == 'shorts';

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: Text(channel?.title ?? widget.title),
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      body: _error != null
          ? Center(child: ErrorRetry(message: 'Não foi possível abrir o canal.', onRetry: _load))
          : channel == null
          ? const Center(child: CircularProgressIndicator())
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 900) _more();
                return false;
              },
              child: CustomScrollView(
                slivers: [
                  if (channel.banner.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: AspectRatio(aspectRatio: 6.2, child: NetImage(channel.banner)),
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Avatar(channel.avatar, size: 72),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            channel.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                                          ),
                                        ),
                                        if (channel.verified) ...[
                                          const SizedBox(width: 4),
                                          Icon(Icons.verified, size: 16, color: colors.onSurfaceVariant),
                                        ],
                                      ],
                                    ),
                                    Text(subscribersLabel(channel.subscribers), style: TextStyle(color: colors.onSurfaceVariant)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (channel.description.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            InkWell(
                              onTap: () => showModalBottomSheet<void>(
                                context: context,
                                showDragHandle: true,
                                isScrollControlled: true,
                                builder: (_) => DraggableScrollableSheet(
                                  expand: false,
                                  builder: (_, controller) => SingleChildScrollView(
                                    controller: controller,
                                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                                    child: SelectableText(channel.description),
                                  ),
                                ),
                              ),
                              child: Text(
                                channel.description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: colors.onSurfaceVariant),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: SubscribeButton(url: widget.url, title: channel.title, avatar: channel.avatar),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _TabsHeader(
                      tabs: channel.tabs.isEmpty ? const ['videos'] : channel.tabs,
                      selected: _tab,
                      onSelect: _selectTab,
                      color: colors.surface,
                    ),
                  ),
                  if (items.isEmpty && _loadingTab)
                    const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())))
                  else if (items.isEmpty)
                    const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Nada por aqui'))))
                  else if (isShorts)
                    SliverPadding(
                      padding: const EdgeInsets.all(8),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 9 / 16,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, i) => GestureDetector(
                          onTap: () => openItem(context, YtItem.fromJson({...items[i].toJson(), 'shorts': true}), shortsFeed: items),
                          child: ClipRRect(borderRadius: BorderRadius.circular(8), child: NetImage(items[i].cover)),
                        ),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) => VideoRow(items[i], showChannel: false),
                    ),
                  SliverToBoxAdapter(
                    child: _loadingTab && items.isNotEmpty
                        ? const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
                        : const SizedBox(height: 140),
                  ),
                ],
              ),
            ),
    );
  }
}

class _TabsHeader extends SliverPersistentHeaderDelegate {
  _TabsHeader({required this.tabs, required this.selected, required this.onSelect, required this.color});
  final List<String> tabs;
  final String selected;
  final ValueChanged<String> onSelect;
  final Color color;

  @override
  double get minExtent => 48;
  @override
  double get maxExtent => 48;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      color: color,
      child: Row(
        children: [
          for (final tab in tabs)
            InkWell(
              onTap: () => onSelect(tab),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: tab == selected ? colors.onSurface : Colors.transparent, width: 2),
                  ),
                ),
                child: Text(
                  _tabLabels[tab] ?? tab,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: tab == selected ? colors.onSurface : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TabsHeader old) => old.selected != selected || old.tabs != tabs;
}
