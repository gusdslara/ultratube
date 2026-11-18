import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/home/home_screen.dart';
import '../../features/shorts/shorts_screen.dart';
import '../../features/downloads/downloads_screen.dart';
import '../../features/discover/discover_screen.dart';
import '../../features/home/recently_played_screen.dart';
import '../../features/home/genre_details_screen.dart';
import '../../features/search/search_screen.dart';
import '../../features/ultratube/channel_screen.dart';
import '../../features/ultratube/home_feed_screen.dart';
import '../../features/ultratube/playlist_screen.dart';
import '../../features/ultratube/you_screen.dart';
import '../../features/ultratube/subscriptions_screen.dart';
import '../../features/ultratube/watch_screen.dart';
import '../../features/ultratube/yt_search_screen.dart';
import '../../features/twitch/twitch_channel_screen.dart';
import '../../features/twitch/twitch_home_screen.dart';
import '../../features/twitch/twitch_watch_screen.dart';
import '../api/yt_models.dart';
import '../../features/library/library_screen.dart';
import '../../features/artist/artist_screen.dart';
import '../../features/album/album_screen.dart';
import '../../features/player/player_screen.dart';
import '../../features/library/liked_songs_screen.dart';
import '../../features/library/playlist_detail_screen.dart';
import '../../features/library/remote_playlist_screen.dart';
import '../../features/radio/radio_details_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/network_streams/stream_playlist_detail_screen.dart';
import '../../features/local_library/local_library_screen.dart';
import '../../features/local_library/local_video_library_screen.dart';
import '../../shared/widgets/scaffold_with_nav.dart';
import '../../shared/widgets/player_route_transition.dart';
import '../ultratube/ultratube_platform.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            ScaffoldWithNav(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/shorts',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: ShortsScreen(
                seed: state.extra is List
                    ? (state.extra as List).whereType<YtItem>().toList()
                    : const [],
              ),
            ),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: DownloadsScreen()),
          ),
          GoRoute(
            path: '/subscriptions',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: SubscriptionsScreen()),
          ),
          GoRoute(
            path: '/watch',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: WatchScreen(
                videoId: state.uri.queryParameters['v'] ?? '',
                item: state.extra is YtItem ? state.extra as YtItem : null,
              ),
            ),
          ),
          // Twitch module: directory tab, search, category, channel, player.
          GoRoute(
            path: '/twitch',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: TwitchHomeScreen()),
          ),
          GoRoute(
            path: '/twitch/search',
            builder: (context, state) => const TwitchSearchScreen(),
          ),
          GoRoute(
            path: '/twitch/category',
            builder: (context, state) => TwitchCategoryScreen(
              name: state.uri.queryParameters['name'] ?? '',
            ),
          ),
          GoRoute(
            path: '/twitch/channel',
            builder: (context, state) => TwitchChannelScreen(
              login: state.uri.queryParameters['c'] ?? '',
            ),
          ),
          GoRoute(
            path: '/twitch/watch',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: TwitchWatchScreen(
                login: state.uri.queryParameters['c'] ?? '',
                vodId: state.uri.queryParameters['vod'],
              ),
            ),
          ),
          GoRoute(
            path: '/channel',
            builder: (context, state) => ChannelScreen(
              url: state.uri.queryParameters['url'] ?? '',
              title: state.extra is String ? state.extra as String : '',
            ),
          ),
          GoRoute(
            path: '/history',
            builder: (context, state) => const HistoryScreen(),
          ),
          GoRoute(
            path: '/you',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: YouScreen()),
          ),
          GoRoute(
            path: '/ytplaylist',
            builder: (context, state) =>
                PlaylistScreen(url: state.uri.queryParameters['url'] ?? ''),
          ),
          GoRoute(
            path: '/myplaylist/:id',
            builder: (context, state) =>
                PlaylistScreen(localId: state.pathParameters['id']),
          ),
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) => NoTransitionPage(
              child: isUltratubePlatform
                  ? const HomeFeedScreen()
                  : const HomeScreen(),
            ),
          ),
          GoRoute(
            path: '/discover',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: DiscoverScreen()),
          ),
          GoRoute(
            path: '/recently-played',
            builder: (context, state) => const RecentlyPlayedScreen(),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: isUltratubePlatform
                  ? YtSearchScreen(
                      initialKind: state.uri.queryParameters['kind'] ?? 'all',
                      initialQuery: state.uri.queryParameters['q'] ?? '',
                    )
                  : const SearchScreen(),
            ),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (context, state) {
              final filterStr = state.uri.queryParameters['filter'];
              final filter = filterStr == 'playlists'
                  ? LibraryFilter.playlists
                  : LibraryFilter.all;
              return NoTransitionPage(
                child: LibraryScreen(initialFilter: filter),
              );
            },
          ),
          GoRoute(
            path: '/local-library',
            builder: (context, state) => const LocalLibraryScreen(),
          ),
          GoRoute(
            path: '/local-videos',
            builder: (context, state) => const LocalVideoLibraryScreen(),
          ),
          GoRoute(
            path: '/artist/:id',
            builder: (context, state) =>
                ArtistScreen(artistId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/album/:id',
            builder: (context, state) =>
                AlbumScreen(albumId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/playlist/:id',
            builder: (context, state) => PlaylistDetailScreen(
              playlistId: int.parse(state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/playlist/remote/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              final name = state.uri.queryParameters['name'];
              return RemotePlaylistScreen(playlistId: id, playlistName: name);
            },
          ),
          GoRoute(
            path: '/player',
            pageBuilder: (context, state) => CustomTransitionPage(
              transitionDuration: playerTransitionDuration,
              reverseTransitionDuration: playerTransitionDuration,
              child: PlayerScreen(
                startFullscreen:
                    state.uri.queryParameters['fullscreen'] == 'true',
              ),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
                    return PlayerRouteTransitionBoundary(
                      animation: animation,
                      child: child,
                    );
                  },
            ),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/liked-songs',
            builder: (context, state) => const LikedSongsScreen(),
          ),
          GoRoute(
            path: '/radio/:type/:id',
            builder: (context, state) {
              final type = state.pathParameters['type']!;
              final id = state.pathParameters['id']!;
              final title = state.uri.queryParameters['title'] ?? 'Radio';
              final imageUrl = state.uri.queryParameters['imageUrl'] ?? '';
              final subtitle = state.uri.queryParameters['subtitle'];
              final artistId = state.uri.queryParameters['artistId'];
              final artistName = state.uri.queryParameters['artistName'];

              final extra = state.extra as Map<String, dynamic>?;
              final color1 = extra?['color1'] as Color?;
              final color2 = extra?['color2'] as Color?;

              return RadioDetailsScreen(
                seedType: type,
                seedId: id,
                title: title,
                imageUrl: imageUrl,
                subtitle: subtitle,
                artistId: artistId,
                artistName: artistName,
                color1: color1,
                color2: color2,
              );
            },
          ),
          GoRoute(
            path: '/genre/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              final name = state.uri.queryParameters['name'] ?? id;
              return GenreDetailsScreen(categoryId: id, categoryName: name);
            },
          ),
          GoRoute(
            path: '/stream_playlist/:id',
            builder: (context, state) {
              final id = int.parse(state.pathParameters['id']!);
              return StreamPlaylistDetailScreen(playlistId: id);
            },
          ),
        ],
      ),
    ],
  );
});
