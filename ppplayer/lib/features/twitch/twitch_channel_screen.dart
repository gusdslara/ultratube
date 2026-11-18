import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/ultratube_theme.dart';
import '../../core/twitch/twitch_providers.dart';
import '../ultratube/yt_widgets.dart' show Avatar, ErrorRetry, NetImage, compactCount;
import 'twitch_widgets.dart';

class TwitchChannelScreen extends ConsumerWidget {
  const TwitchChannelScreen({super.key, required this.login});
  final String login;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(twitchChannelProvider(login));
    return Scaffold(
      backgroundColor: UT.bg,
      body: channel.when(
        loading: () => const Center(child: CircularProgressIndicator(color: UT.twitch)),
        error: (e, _) => SafeArea(
          child: Column(
            children: [
              Align(alignment: Alignment.centerLeft, child: BackButton(onPressed: () => Navigator.of(context).maybePop())),
              Expanded(child: Center(child: ErrorRetry(message: '$e', onRetry: () => ref.invalidate(twitchChannelProvider(login))))),
            ],
          ),
        ),
        data: (c) => RefreshIndicator(
          color: UT.twitch,
          onRefresh: () async {
            ref.invalidate(twitchChannelProvider(login));
            await ref.read(twitchChannelProvider(login).future).catchError((_) => c);
          },
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: c.banner.isEmpty ? null : 150,
                backgroundColor: UT.bg,
                surfaceTintColor: Colors.transparent,
                title: Text(c.displayName),
                flexibleSpace: c.banner.isEmpty
                    ? null
                    : FlexibleSpaceBar(
                        background: Stack(
                          fit: StackFit.expand,
                          children: [
                            NetImage(c.banner),
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x66000000), Color(0x00000000), Color(0xCC000000)]),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.isLive ? UT.red : Colors.transparent, width: 2.5)),
                        child: Avatar(c.avatar, size: 68),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.displayName, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                            if (c.followers >= 0) Text('${compactCount(c.followers)} seguidores', style: const TextStyle(color: UT.text2)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(children: [FollowButton(login: c.login, displayName: c.displayName, avatar: c.avatar)]),
                ),
              ),
              if (c.description.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(c.description, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: UT.text2, height: 1.4)),
                  ),
                ),
              if (c.stream case final s?) ...[
                const SliverToBoxAdapter(
                  child: Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 10), child: Text('Ao vivo agora', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                ),
                SliverToBoxAdapter(child: TwitchStreamCard(s)),
              ] else
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Container(
                      padding: const EdgeInsets.all(UT.s4),
                      decoration: BoxDecoration(color: UT.surface2, borderRadius: BorderRadius.circular(UT.rMd)),
                      child: Row(
                        children: [
                          const Icon(Icons.nightlight_round, color: UT.text3),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              c.lastStartedAt == null ? 'Offline' : 'Offline · última live ${agoLabel(c.lastStartedAt)}',
                              style: const TextStyle(color: UT.text2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(
                child: Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 6), child: Text('Transmissões anteriores', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
              ),
              if (c.videos.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(padding: EdgeInsets.all(16), child: Text('Este canal não mantém vídeos salvos.', style: TextStyle(color: UT.text2))),
                )
              else
                SliverList.builder(itemCount: c.videos.length, itemBuilder: (context, i) => TwitchVodRow(c.videos[i])),
              const SliverToBoxAdapter(child: SizedBox(height: 140)),
            ],
          ),
        ),
      ),
    );
  }
}
