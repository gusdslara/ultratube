import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ppplayer/features/search/ultratube_search_screen.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(800, 600)]) {
    testWidgets('direct catalog fits $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: UltratubeSearchScreen())),
        ),
      );
      expect(find.text('ULTRATUBE'), findsOneWidget);
      expect(find.text('Músicas'), findsOneWidget);
      expect(find.text('Vídeos'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
