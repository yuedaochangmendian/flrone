import 'package:flutter_svg/flutter_svg.dart';

import '../../widgets.dart';
import 'connectivity_store.dart';

/// Bettbox's platform artwork, rendered at the row's glyph size. The bundled
/// SVGs keep each service recognisable without a raster asset variant per
/// density.
class ConnectivityAvatar extends StatelessWidget {
  const ConnectivityAvatar({super.key, required this.service, this.size = 40});
  final ConnectivityService service;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.asset(
        service.asset,
        fit: BoxFit.contain,
        placeholderBuilder: (_) => Center(
          child: Text(
            service.name.characters.take(2).toString(),
            style: TextStyle(
              color: context.colorScheme.onSurfaceVariant,
              fontSize: size * 0.3,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

/// The regional-indicator emoji for a two-letter ISO code, as Bettbox's card and
/// rows show the exit region.
String connectivityFlag(String code) {
  if (code.length != 2) return '';
  final upper = code.toUpperCase();
  final first = upper.codeUnitAt(0) - 0x41;
  final second = upper.codeUnitAt(1) - 0x41;
  if (first < 0 || first > 25 || second < 0 || second > 25) return '';
  return String.fromCharCodes([0x1F1E6 + first, 0x1F1E6 + second]);
}
