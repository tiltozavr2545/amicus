import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Bound decoded memory, preserving aspect ratio without upscaling the source.
/// Fourfold zoom still has a per-image ceiling of 4096 x 4096 RGBA pixels.
ImageProvider boundedImage(
  ImageProvider source,
  Size viewport,
  double pixelRatio, {
  double scale = 1,
}) => ResizeImage(
  source,
  width: (viewport.width * pixelRatio * scale).ceil().clamp(1, 4096),
  height: (viewport.height * pixelRatio * scale).ceil().clamp(1, 4096),
  policy: ResizeImagePolicy.fit,
);

/// Keep original files in the disk cache; decode only the display budget.
class CachedMediaImage extends StatelessWidget {
  const CachedMediaImage({
    super.key,
    required this.imageUrl,
    required this.cacheKey,
    this.fit = BoxFit.contain,
    this.width,
    this.height,
    this.zoomScale = 1,
  });

  final String imageUrl;
  final String? cacheKey;
  final BoxFit fit;
  final double? width;
  final double? height;
  final double zoomScale;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = MediaQuery.sizeOf(context);
      final size = Size(
        width != null && width!.isFinite
            ? constraints.constrainWidth(width!)
            : constraints.hasBoundedWidth
            ? constraints.maxWidth
            : viewport.width,
        height != null && height!.isFinite
            ? constraints.constrainHeight(height!)
            : constraints.hasBoundedHeight
            ? constraints.maxHeight
            : viewport.height,
      );
      return Image(
        image: boundedImage(
          CachedNetworkImageProvider(imageUrl, cacheKey: cacheKey),
          size,
          MediaQuery.devicePixelRatioOf(context),
          scale: zoomScale,
        ),
        fit: fit,
        width: width,
        height: height,
        errorBuilder: (_, _, _) =>
            const Center(child: Icon(Icons.broken_image_outlined)),
      );
    },
  );
}
