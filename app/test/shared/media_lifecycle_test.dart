import 'dart:async';

import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';
import 'package:amicus/shared/media_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Player extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>.broadcast(sync: true);
  int plays = 0;
  int pauses = 0;
  int disposals = 0;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => 1;
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events.stream;
  @override
  Future<void> dispose(int playerId) async => disposals++;
  @override
  Future<void> play(int playerId) async => plays++;
  @override
  Future<void> pause(int playerId) async => pauses++;
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildView(int playerId) => const SizedBox();

  void initialize() => events.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(minutes: 1),
      size: const Size(400, 300),
    ),
  );
}

void main() {
  for (final whilePreparing in [false, true]) {
    for (final hide in ['background', 'tab', 'slide']) {
      testWidgets('$hide stops playback, preparing: $whilePreparing', (
        tester,
      ) async {
        final previous = VideoPlayerPlatform.instance;
        final player = _Player();
        VideoPlayerPlatform.instance = player;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        var tickerEnabled = true;
        var current = true;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Scaffold(
                  body: TickerMode(
                    enabled: tickerEnabled,
                    child: MediaSlide(
                      item: const PostMedia(
                        id: 'clip',
                        position: 0,
                        mediaType: MediaType.video,
                        storagePath: 'clip.mp4',
                        url: 'https://example.invalid/clip.mp4',
                      ),
                      fit: BoxFit.contain,
                      constrainHeight: true,
                      isCurrent: current,
                    ),
                  ),
                );
              },
            ),
          ),
        );
        try {
          await tester.tap(find.byIcon(Icons.play_circle_fill));
          await tester.pump();
          if (!whilePreparing) {
            player.initialize();
            await tester.pump();
            await tester.pump();
            expect(player.plays, 1);
          }
          switch (hide) {
            case 'background':
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.hidden,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
            case 'tab':
              update(() => tickerEnabled = false);
            case 'slide':
              update(() => current = false);
          }
          await tester.pump();
          if (whilePreparing) player.initialize();
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 1));
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          }
          if (whilePreparing) {
            expect(player.plays, 0);
            expect(player.disposals, 1);
          } else {
            expect(player.pauses, greaterThan(0));
          }
          if (hide == 'background') {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          }
          update(() {
            tickerEnabled = true;
            current = true;
          });
          await tester.pump();
          expect(
            player.plays,
            whilePreparing ? 0 : 1,
            reason: 'Returning must not automatically resume a hidden clip',
          );
        } finally {
          await tester.pumpWidget(const SizedBox());
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 1));
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          }
          expect(player.disposals, 1);
          unawaited(player.events.close());
          await tester.pump();
          VideoPlayerPlatform.instance = previous;
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
