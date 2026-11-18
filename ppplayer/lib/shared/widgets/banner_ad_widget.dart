import 'package:flutter/widgets.dart';

/// Compatibility slot retained for existing layouts. Ultratube has no ad SDK.
class BannerAdWidget extends StatelessWidget {
  const BannerAdWidget({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
