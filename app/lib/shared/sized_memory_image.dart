import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A [MemoryImage] decoded no larger than the box it will be drawn into.
///
/// Photos are picked at `maxWidth: 1600` and stored at that size, so a raw
/// `MemoryImage` decodes to roughly 1600×2000×4 ≈ 12 MB of ARGB **per image**
/// no matter how small it is painted. A 40 px avatar in the Connections list
/// paid that in full, and the delete screen — which builds all up-to-80
/// gallery tiles at once, in a `Wrap` inside a `SingleChildScrollView` rather
/// than a lazy list — asked for it 80 times over against a 100 MB
/// `ImageCache`, so the cache thrashed and re-decoded on every scroll.
///
/// [logicalWidth] is the painted width in logical pixels; it is multiplied by
/// the device pixel ratio here, so callers pass the same number they gave the
/// surrounding `SizedBox`/`radius`. Only the width is constrained, which
/// [ResizeImage] scales proportionally — right for both `BoxFit.cover` tiles
/// and round avatars.
///
/// Not for a zoomable full-screen viewer: there the full resolution is the
/// point.
ImageProvider sizedMemoryImage(
  BuildContext context,
  Uint8List bytes, {
  required double logicalWidth,
}) {
  final ratio = MediaQuery.devicePixelRatioOf(context);
  return ResizeImage(MemoryImage(bytes), width: (logicalWidth * ratio).round());
}
