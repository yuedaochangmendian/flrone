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
            service.short,
            style: TextStyle(
              color: Color(service.color),
              fontSize: size * 0.3,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}
