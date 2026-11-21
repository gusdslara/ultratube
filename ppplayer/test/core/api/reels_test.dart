import 'package:flutter_test/flutter_test.dart';
import 'package:ppplayer/core/api/innertube.dart';
import 'package:ppplayer/core/api/reels.dart';

/// Trimmed shapes of the real `reel/*` replies.
Json _overlay({required String title, required String channel, required String channelId, String likes = '78 mil', String comments = '157'}) => {
  'overlay': {
    'reelPlayerOverlayRenderer': {
      'playerOverlay': {
        'reelPlayerOverlayViewModel': {
          'metapanel': {
            'reelMetapanelViewModel': {
              'metadataItems': [
                {
                  'reelChannelBarViewModel': {
                    'decoratedAvatarViewModel': {
                      'decoratedAvatarViewModel': {
                        'avatar': {
                          'avatarViewModel': {
                            'image': {
                              'sources': [
                                {'url': 'https://yt3.ggpht.com/a=s48'},
                              ],
                            },
                          },
                        },
                        'rendererContext': {
                          'commandContext': {
                            'onTap': {
                              'innertubeCommand': {
                                'browseEndpoint': {'browseId': channelId},
                              },
                            },
                          },
                        },
                      },
                    },
                    'channelName': {'content': '@$channel'},
                  },
                },
                {
                  'shortsVideoTitleViewModel': {
                    'text': {'content': title},
                  },
                },
              ],
            },
          },
          'actionBar': {
            'reelActionBarViewModel': {
              'buttonViewModels': [
                {
                  'likeButtonViewModel': {
                    'toggleButtonViewModel': {
                      'toggleButtonViewModel': {
                        'defaultButtonViewModel': {
                          'buttonViewModel': {'title': likes},
                        },
                        'toggledButtonViewModel': {
                          'buttonViewModel': {'title': 'other'},
                        },
                      },
                    },
                  },
                },
                {
                  'buttonViewModel': {'title': comments},
                },
                {
                  'buttonViewModel': {'title': 'Compartilhar'},
                },
              ],
            },
          },
        },
      },
    },
  },
};

void main() {
  test('first page: seed Short with its overlay, then the sequence', () async {
    final calls = <(String, Json)>[];
    final reels = Reels((endpoint, body) async {
      calls.add((endpoint, body));
      if (endpoint == 'reel/reel_item_watch') {
        return {
          ..._overlay(title: 'Primeiro', channel: 'canal_um', channelId: 'UCaaaaaaaaaaaaaaaaaaaaaa'),
          'replacementEndpoint': {
            'reelWatchEndpoint': {'videoId': 'aaaaaaaaaaa'},
          },
          'sequenceContinuation': 'SEQ1',
        };
      }
      return {
        'entries': [
          {
            'command': {
              'reelWatchEndpoint': {
                'videoId': 'bbbbbbbbbbb',
                'unserializedPrefetchData': {
                  'playerResponse': {
                    'videoDetails': {'title': 'Segundo', 'author': 'Canal Dois', 'channelId': 'UCbbbbbbbbbbbbbbbbbbbbbb', 'lengthSeconds': '52'},
                  },
                },
              },
            },
          },
          {
            'command': {
              'reelWatchEndpoint': {'videoId': 'ccccccccccc'},
            },
          },
          // Repeats and malformed ids are dropped.
          {
            'command': {
              'reelWatchEndpoint': {'videoId': 'aaaaaaaaaaa'},
            },
          },
          {
            'command': {
              'reelWatchEndpoint': {'videoId': 'short'},
            },
          },
        ],
        'continuationEndpoint': {
          'continuationCommand': {'token': 'SEQ2'},
        },
      };
    });

    final page = await reels.feed(null);
    expect(calls.map((c) => c.$1), ['reel/reel_item_watch', 'reel/reel_watch_sequence']);
    expect(calls[1].$2['sequenceParams'], 'SEQ1');
    expect(page['next'], 'SEQ2');
    final items = (page['items'] as List).cast<Json>();
    expect(items.map((i) => i['url']), [
      'https://www.youtube.com/shorts/aaaaaaaaaaa',
      'https://www.youtube.com/shorts/bbbbbbbbbbb',
      'https://www.youtube.com/shorts/ccccccccccc',
    ]);
    expect(items[0]['title'], 'Primeiro');
    expect(items[0]['channel'], 'canal_um');
    expect(items[0]['channelUrl'], 'https://www.youtube.com/channel/UCaaaaaaaaaaaaaaaaaaaaaa');
    expect(items[1]['title'], 'Segundo');
    expect(items[1]['duration'], 52);
    expect(items[2]['title'], '');
    expect(items.every((i) => i['shorts'] == true && i['type'] == 'video'), isTrue);
  });

  test('continuation goes straight to the sequence; last page has no token', () async {
    final calls = <String>[];
    final reels = Reels((endpoint, body) async {
      calls.add(endpoint);
      expect(body['sequenceParams'], 'SEQ2');
      return {'entries': <Object>[]};
    });
    final page = await reels.feed('SEQ2');
    expect(calls, ['reel/reel_watch_sequence']);
    expect(page['items'], isEmpty);
    expect(page['next'], isNull);
  });

  test('info reads title, channel and counters', () async {
    final reels = Reels((endpoint, body) async {
      expect((body['playerRequest'] as Map)['videoId'], 'ddddddddddd');
      return _overlay(title: 'Título', channel: 'criador', channelId: 'UCdddddddddddddddddddddd', likes: '4,7 mil', comments: '104');
    });
    expect(await reels.info('ddddddddddd'), {
      'title': 'Título',
      'channel': 'criador',
      'channelUrl': 'https://www.youtube.com/channel/UCdddddddddddddddddddddd',
      'channelAvatar': 'https://yt3.ggpht.com/a=s48',
      'likes': '4,7 mil',
      'comments': '104',
    });
  });

  test('info: comments turned off leave the count empty; bad ids are refused', () async {
    final reels = Reels((endpoint, body) async => _overlay(title: 't', channel: 'c', channelId: 'UCx', comments: 'Comentários'));
    expect((await reels.info('ddddddddddd'))['comments'], '');
    expect(() => reels.info('../etc'), throwsArgumentError);
  });
}
