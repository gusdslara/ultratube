import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ultratube/feeds.dart';
import '../../core/ultratube/ultratube_store.dart';
import 'yt_widgets.dart';

/// Inscrições: channel strip + chronological uploads, stored on-device.
class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'json']);
    if (picked.isEmpty || picked.first.path == null) return;
    try {
      final added = ref.read(subscriptionsProvider.notifier).importFile(File(picked.first.path!));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(added == 0 ? 'Nenhum canal novo no arquivo' : '$added canais importados')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Arquivo não reconhecido: $error')));
      }
    }
  }

  void _help(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => const Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Trazer suas inscrições do YouTube', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          SizedBox(height: 12),
          Text(
            '1. Abra takeout.google.com e desmarque tudo.\n'
            '2. Marque só "YouTube e YouTube Music" → "Todos os dados incluídos" → deixe só "inscrições".\n'
            '3. Exporte, baixe o .zip e extraia o arquivo subscriptions.csv.\n'
            '4. Aqui, toque em Importar e escolha esse arquivo.\n\n'
            'Também aceita o arquivo .json exportado pelo NewPipe ou LibreTube. '
            'Tudo fica só neste aparelho; nenhuma conta Google é usada.',
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(subscriptionsProvider);
    final feed = ref.watch(subscriptionFeedProvider);
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: () => ref.read(subscriptionFeedProvider.notifier).refresh(),
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: true,
              backgroundColor: colors.surface,
              surfaceTintColor: Colors.transparent,
              title: const Text('Inscrições', style: TextStyle(fontWeight: FontWeight.w700)),
              actions: [
                IconButton(tooltip: 'Buscar canais', icon: const Icon(Icons.search), onPressed: () => context.push('/search?kind=channels')),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    switch (v) {
                      case 'import':
                        await _import(context, ref);
                      case 'help':
                        _help(context);
                      case 'export':
                        await Clipboard.setData(ClipboardData(text: ref.read(subscriptionsProvider.notifier).exportJson()));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Lista copiada (formato NewPipe)')),
                          );
                        }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'import', child: ListTile(leading: Icon(Icons.file_upload_outlined), title: Text('Importar inscrições'))),
                    PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Copiar lista'))),
                    PopupMenuItem(value: 'help', child: ListTile(leading: Icon(Icons.help_outline), title: Text('Como importar do YouTube'))),
                  ],
                ),
              ],
            ),
            if (subs.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.subscriptions_outlined, size: 64, color: colors.primary),
                      const SizedBox(height: 16),
                      const Text('Nenhuma inscrição ainda', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(
                        'Inscreva-se em canais ou traga a sua lista do YouTube. Os vídeos novos aparecem aqui, em ordem.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () => _import(context, ref),
                        icon: const Icon(Icons.file_upload_outlined),
                        label: const Text('Importar do YouTube'),
                      ),
                      TextButton(onPressed: () => _help(context), child: const Text('Como exportar minhas inscrições?')),
                      TextButton(onPressed: () => context.push('/search?kind=channels'), child: const Text('Buscar canais')),
                    ],
                  ),
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 104,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: subs.length,
                    itemBuilder: (context, i) {
                      final s = subs[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => openChannel(context, s.url, title: s.title),
                        child: SizedBox(
                          width: 76,
                          child: Column(
                            children: [
                              const SizedBox(height: 8),
                              Avatar(s.avatar, size: 56),
                              const SizedBox(height: 6),
                              Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: Divider(height: 1)),
              if (feed.loading && feed.videos.isEmpty)
                const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.only(top: 16), child: FeedSkeleton()))
              else if (feed.error != null && feed.videos.isEmpty)
                SliverToBoxAdapter(
                  child: ErrorRetry(
                    message: 'Não foi possível atualizar as inscrições.',
                    onRetry: () => ref.read(subscriptionFeedProvider.notifier).refresh(),
                  ),
                )
              else ...[
                if (feed.loading) const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2)),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
                SliverList.builder(
                  itemCount: feed.videos.length,
                  itemBuilder: (context, i) => VideoCard(feed.videos[i]),
                ),
              ],
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }
}
