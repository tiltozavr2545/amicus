import 'package:flutter/material.dart';

/// The launcher's white foreground, without its background or adaptive padding.
class AmicusMark extends StatelessWidget {
  const AmicusMark({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: ClipRect(
        child: OverflowBox(
          maxWidth: size * 1.6,
          maxHeight: size * 1.6,
          child: Image.asset(
            'assets/branding/app_icon.png',
            width: size * 1.6,
            height: size * 1.6,
            fit: BoxFit.contain,
            color: Theme.of(context).brightness == Brightness.light
                ? Theme.of(context).colorScheme.primary
                : Colors.white,
            colorBlendMode: BlendMode.srcIn,
          ),
        ),
      ),
    ),
  );
}
