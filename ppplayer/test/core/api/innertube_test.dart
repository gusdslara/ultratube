import 'package:flutter_test/flutter_test.dart';
import 'package:ppplayer/core/api/innertube.dart';

void main() {
  group('parseCount', () {
    test('full numbers in pt-BR and en', () {
      expect(parseCount('1.838.405.393 visualizações'), 1838405393);
      expect(parseCount('12,345 views'), 12345);
    });

    test('abbreviations', () {
      expect(parseCount('1,2 mi de visualizações'), 1200000);
      expect(parseCount('34 mil visualizações'), 34000);
      expect(parseCount('4,56 milhões de inscritos'), 4560000);
      expect(parseCount('2 bi de visualizações'), 2000000000);
      expect(parseCount('12K views'), 12000);
      expect(parseCount('1.5M subscribers'), 1500000);
    });

    test('no number', () {
      expect(parseCount('Nenhuma visualização'), 0);
      expect(parseCount('No views'), 0);
      expect(parseCount('Comentários'), -1);
    });
  });

  test('seconds', () {
    expect(seconds('3:45'), 225);
    expect(seconds('1:02:03'), 3723);
    expect(seconds('AO VIVO'), 0);
  });

  test('relativeTime is in the past and ordered', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final hours = relativeTime('há 2 horas');
    final days = relativeTime('3 days ago');
    final years = relativeTime('Transmitido há 1 ano');
    expect(hours, lessThan(now));
    expect(days, lessThan(hours));
    expect(years, lessThan(days));
    expect(relativeTime('Estreia em breve'), 0);
  });

  test('hd upsizes music art only', () {
    expect(
      hd('https://lh3.googleusercontent.com/abc=w60-h60-l90-rj'),
      'https://lh3.googleusercontent.com/abc=w1080-h1080-l90-rj',
    );
    expect(hd('https://yt3.ggpht.com/x=s88-c-k'), 'https://yt3.ggpht.com/x=s1080');
    expect(hd('https://i.ytimg.com/vi/x/hqdefault.jpg'), 'https://i.ytimg.com/vi/x/hqdefault.jpg');
  });

  test('artistName strips Topic channels', () {
    expect(artistName('Anitta - Topic'), 'Anitta');
    expect(artistName('Anitta - Tópico'), 'Anitta');
    expect(artistName('Anitta'), 'Anitta');
  });

  group('parseItems', () {
    test('videoRenderer, channel and ads', () {
      final page = {
        'contents': [
          {
            'videoRenderer': {
              'videoId': 'dQw4w9WgXcQ',
              'title': {
                'runs': [
                  {'text': 'Never Gonna Give You Up'},
                ],
              },
              'ownerText': {
                'runs': [
                  {
                    'text': 'Rick Astley',
                    'navigationEndpoint': {
                      'browseEndpoint': {'browseId': 'UCuAXFkgsw1L7xaCfnd5JJOw'},
                    },
                  },
                ],
              },
              'lengthText': {'simpleText': '3:33'},
              'viewCountText': {'simpleText': '1.000 visualizações'},
              'publishedTimeText': {'simpleText': 'há 15 anos'},
              'ownerBadges': [
                {
                  'metadataBadgeRenderer': {'style': 'BADGE_STYLE_TYPE_VERIFIED_ARTIST'},
                },
              ],
            },
          },
          {
            'adSlotRenderer': {
              'videoRenderer': {'videoId': 'AAAAAAAAAAA'},
            },
          },
          {
            'channelRenderer': {
              'channelId': 'UCuAXFkgsw1L7xaCfnd5JJOw',
              'title': {'simpleText': 'Rick Astley'},
              'videoCountText': {'simpleText': '4,56 mi de inscritos'},
            },
          },
        ],
      };
      final items = parseItems(page);
      expect(items, hasLength(2));
      final video = items.first;
      expect(video['url'], 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(video['channel'], 'Rick Astley');
      expect(video['channelUrl'], 'https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw');
      expect(video['duration'], 213);
      expect(video['views'], 1000);
      expect(video['verified'], isTrue);
      expect(video['shorts'], isFalse);
      expect(items.last['type'], 'channel');
      expect(items.last['subscribers'], 4560000);
    });

    test('lockup without owner keeps channel empty', () {
      final page = {
        'lockupViewModel': {
          'contentId': 'dQw4w9WgXcQ',
          'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
          'metadata': {
            'lockupMetadataViewModel': {
              'title': {'content': 'Karaokê'},
              'metadata': {
                'contentMetadataViewModel': {
                  'metadataRows': [
                    {
                      'metadataParts': [
                        {
                          'text': {'content': '34 mil visualizações'},
                        },
                        {
                          'text': {'content': 'há 11 dias'},
                        },
                      ],
                    },
                  ],
                },
              },
            },
          },
        },
      };
      final item = parseItems(page).single;
      expect(item['channel'], '');
      expect(item['views'], 34000);
      expect(item['uploaded'], 'há 11 dias');
    });

    test('Shorts shelves only when asked', () {
      final page = {
        'reelShelfRenderer': {
          'items': [
            {
              'reelItemRenderer': {
                'videoId': 'abcdefghijk',
                'headline': {'simpleText': 'Short'},
              },
            },
          ],
        },
      };
      expect(parseItems(page), isEmpty);
      final shorts = parseItems(page, shelves: true);
      expect(shorts.single['shorts'], isTrue);
    });
  });

  test('continuation prefers the command token', () {
    expect(
      continuation({
        'continuationItemRenderer': {
          'continuationEndpoint': {
            'continuationCommand': {'token': 'abc'},
          },
        },
      }),
      ('abc', false),
    );
    expect(
      continuation({
        'continuations': [
          {
            'nextContinuationData': {'continuation': 'legacy'},
          },
        ],
      }),
      ('legacy', true),
    );
    expect(continuation(const {}), isNull);
  });
}
