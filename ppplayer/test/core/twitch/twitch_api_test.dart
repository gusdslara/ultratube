import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ppplayer/core/twitch/twitch_api.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _stream(String login, int viewers) => {
  'id': '1',
  'title': 'live de $login',
  'viewersCount': viewers,
  'broadcaster': {'login': login, 'displayName': login.toUpperCase(), 'profileImageURL': ''},
  'game': {'id': '9', 'name': 'VALORANT', 'displayName': 'VALORANT', 'boxArtURL': ''},
  'freeformTags': <Object>[],
};

void main() {
  test('searchAll maps every kind and puts live channels first', () async {
    final api = TwitchApi(
      client: MockClient((request) async {
        expect(request.headers['Client-ID'], TwitchApi.clientId);
        expect(request.headers.containsKey('Authorization'), isFalse);
        return _json({
          'data': {
            'searchFor': {
              'channels': {
                'edges': [
                  {
                    'item': {'id': '1', 'login': 'offline_one', 'displayName': 'Offline', 'stream': null},
                  },
                  {
                    'item': {'id': '2', 'login': 'live_one', 'displayName': 'Live', 'stream': _stream('live_one', 10)},
                  },
                  {'item': <String, dynamic>{}}, // an entry of another type
                ],
              },
              'games': {
                'edges': [
                  {
                    'item': {'id': '9', 'name': 'VALORANT', 'displayName': 'VALORANT', 'viewersCount': null},
                  },
                ],
              },
              'videos': {
                'edges': [
                  {
                    'item': {
                      'id': '77',
                      'title': 'vod',
                      'lengthSeconds': 60,
                      'viewCount': 5,
                      'owner': {'login': 'someone', 'displayName': 'Someone'},
                    },
                  },
                ],
              },
            },
            'searchStreams': {
              'edges': [
                {'node': _stream('live_one', 10)},
                {'node': _stream('live_one', 10)}, // Twitch repeats channels here
                {'node': _stream('live_two', 3)},
              ],
            },
          },
        });
      }),
    );
    final r = await api.searchAll('valorant');
    expect(r.channels.map((c) => c.login), ['live_one', 'offline_one']);
    expect(r.games.single.viewers, -1);
    expect(r.videos.single.login, 'someone');
    expect(r.streams.map((s) => s.login), ['live_one', 'live_two']);
    expect((await api.searchAll('  ')).isEmpty, isTrue);
  });

  test('suggestions tell channels, categories and plain text apart', () async {
    final api = TwitchApi(
      client: MockClient(
        (request) async => _json({
          'data': {
            'searchSuggestions': {
              'edges': [
                {
                  'node': {
                    'text': 'Gaules',
                    'content': {'__typename': 'SearchSuggestionChannel', 'login': 'gaules', 'isLive': true, 'profileImageURL': 'a.png'},
                  },
                },
                {
                  'node': {
                    'text': 'Fortnite',
                    'content': {
                      '__typename': 'SearchSuggestionCategory',
                      'boxArtURL': 'b.jpg',
                      'game': {'name': 'Fortnite'},
                    },
                  },
                },
                {
                  'node': {'text': 'fortnite drops', 'content': null},
                },
              ],
            },
          },
        }),
      ),
    );
    final s = await api.suggestions('fo');
    expect(s[0].login, 'gaules');
    expect(s[0].live, isTrue);
    expect(s[1].game, 'Fortnite');
    expect(s[1].login, isEmpty);
    expect(s[2].login.isEmpty && s[2].game.isEmpty, isTrue);
    expect(await api.suggestions('f'), isEmpty); // too short to ask
  });

  test('category sort is sent to Twitch; tags and followers are read', () async {
    late Map<String, dynamic> sent;
    final api = TwitchApi(
      client: MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({
          'data': {
            'game': {
              'id': '9',
              'name': 'Just Chatting',
              'displayName': 'Só na conversa',
              'viewersCount': 100,
              'followersCount': 5000,
              'tags': [
                {'localizedName': 'IRL'},
              ],
              'streams': {
                'edges': [
                  {'node': _stream('a', 1)},
                ],
              },
            },
          },
        });
      }),
    );
    final (game, page) = await api.gameStreams('Just Chatting', language: 'pt', sort: TwitchSort.recent);
    expect((sent['variables'] as Map)['sort'], 'RECENT');
    expect((sent['variables'] as Map)['langs'], ['pt']);
    expect(game!.tags, ['IRL']);
    expect(game.followers, 5000);
    expect(page.items.single.login, 'a');
  });

  group('account', () {
    test('a pending sign-in polls as null; an expired code throws', () async {
      var pending = true;
      final api = TwitchApi(
        client: MockClient((request) async {
          expect(request.bodyFields['client_id'], TwitchApi.tvClientId);
          return pending
              ? _json({'status': 400, 'message': 'authorization_pending'}, 400)
              : _json({'status': 400, 'message': 'invalid device code'}, 400);
        }),
      );
      expect(await api.deviceToken('code'), isNull);
      pending = false;
      expect(() => api.deviceToken('code'), throwsA(isA<TwitchException>()));
    });

    test('followed channels: every page, with the account token', () async {
      final cursors = <Object?>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          expect(request.headers['Client-ID'], TwitchApi.tvClientId);
          expect(request.headers['Authorization'], 'OAuth tok');
          final after = ((jsonDecode(request.body) as Map)['variables'] as Map)['after'];
          cursors.add(after);
          return _json({
            'data': {
              'currentUser': {
                'follows': {
                  'edges': [
                    {
                      'cursor': after == null ? 'c1' : 'c2',
                      'node': {'login': after == null ? 'first' : 'second', 'displayName': 'X', 'profileImageURL': 'p.png'},
                    },
                  ],
                  'pageInfo': {'hasNextPage': after == null},
                },
              },
            },
          });
        }),
      );
      final list = await api.followed('tok', '42');
      expect(cursors, [null, 'c1']);
      expect(list.map((c) => c.$1), ['first', 'second']);
    });

    test('followed channels fall back to the public API', () async {
      final api = TwitchApi(
        client: MockClient((request) async {
          if (request.url.host == 'gql.twitch.tv') {
            return _json({
              'data': {'currentUser': null},
            });
          }
          expect(request.url.path, '/helix/channels/followed');
          expect(request.url.queryParameters['user_id'], '42');
          expect(request.headers['Authorization'], 'Bearer tok');
          return _json({
            'data': [
              {'broadcaster_login': 'helix_one', 'broadcaster_name': 'Helix One'},
            ],
            'pagination': <String, dynamic>{},
          });
        }),
      );
      expect(await api.followed('tok', '42'), [('helix_one', 'Helix One', '')]);
    });

    test('an expired token validates as null', () async {
      final api = TwitchApi(client: MockClient((request) async => _json({'status': 401, 'message': 'invalid access token'}, 401)));
      expect(await api.validate('old'), isNull);
    });
  });
}
