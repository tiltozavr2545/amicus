import 'dart:async';
import 'dart:ui' as ui;

import 'package:amicus/shared/bounded_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('decoded images preserve aspect ratio and respect the zoom cap', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final image = (await tester.runAsync(() => picture.toImage(1000, 2000)))!;
    picture.dispose();
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    ))!;
    image.dispose();
    final source = MemoryImage(bytes.buffer.asUint8List());
    final provider = boundedImage(source, const Size(100, 100), 1, scale: 4);
    final result = Completer<ImageInfo>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) => result.complete(info),
      onError: result.completeError,
    );
    stream.addListener(listener);
    for (var i = 0; i < 100 && !result.isCompleted; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(result.isCompleted, isTrue);
    final info = await result.future;
    expect(info.image.width, 200);
    expect(info.image.height, 400);
    info.dispose();
    stream.removeListener(listener);
    final capped =
        boundedImage(source, const Size(1440, 3200), 3, scale: 4)
            as ResizeImage;
    expect(capped.width, 4096);
    expect(capped.height, 4096);
    expect(capped.allowUpscaling, isFalse);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}
