import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/yt_models.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/ultratube/ultratube_store.dart';
import 'yt_widgets.dart';

Future<String?> _askName(BuildContext context, {String initial = '', String title = 'Nova playlist'}) async {
  final input = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: input,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Nome da playlist'),
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(d, input.text), child: const Text('Salvar')),
      ],
    ),
  );
  Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
  return name?.trim().isEmpty ?? true ? null : name!.trim();
}

Future<void> renamePlaylist(BuildContext context, WidgetRef ref, LocalPlaylist playlist) async {
  final name = await _askName(context, initial: playlist.title, title: 'Renomear playlist');
  if (name != null) ref.read(playlistsProvider.notifier).rename(playlist.id, name);
}

/// Creates a playlist from [items] (e.g. the current queue).
Future<void> saveToNewPlaylist(BuildContext context, WidgetRef ref, List<YtItem> items) async {
  final name = await _askName(context);
  if (name == null || !context.mounted) return;
  ref.read(playlistsProvider.notifier).create(name, items: items);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Salvo em "$name"')));
}

/// "Salvar em playlist" sheet, like YouTube's.
Future<void> showAddToPlaylist(BuildContext context, YtItem item) => showModalBottomSheet<void>(
  context: context,
  builder: (_) => _PickerSheet(item: item),
);

class _PickerSheet extends ConsumerWidget {
  const _PickerSheet({required this.item});
  final YtItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final liked = ref.watch(likedProvider).any((i) => i.url == item.url);
    final notifier = ref.read(playlistsProvider.notifier);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(UT.s5, 0, UT.s5, UT.s2),
            child: Text('Salvar em…', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          CheckboxListTile(
            value: liked,
            activeColor: UT.red,
            secondary: const Icon(Icons.thumb_up_outlined),
            title: const Text('Vídeos curtidos'),
            onChanged: (_) => ref.read(likedProvider.notifier).toggle(item),
          ),
          for (final p in playlists)
            CheckboxListTile(
              value: p.items.any((i) => i.url == item.url),
              activeColor: UT.red,
              secondary: SizedBox(
                width: 40,
                height: 40,
                child: ClipRRect(borderRadius: BorderRadius.circular(6), child: NetImage(p.cover, icon: Icons.playlist_play)),
              ),
              title: Text(p.title),
              subtitle: Text('${p.items.length} vídeos'),
              onChanged: (v) => v == true ? notifier.add(p.id, item) : notifier.remove(p.id, item),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Nova playlist'),
            onTap: () async {
              final name = await _askName(context);
              if (name == null) return;
              notifier.create(name, items: [item]);
              if (context.mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(height: UT.s2),
        ],
      ),
    );
  }
}
