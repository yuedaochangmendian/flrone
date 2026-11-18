import '../../widgets.dart';
import 'connectivity_store.dart';

/// A compact brand-coloured service chip. The Bettbox platform SVGs are not
/// vendored; the short label keeps the same visual anchor without an SVG
/// dependency.
class ConnectivityAvatar extends StatelessWidget {
  const ConnectivityAvatar({super.key, required this.service, this.size = 40});
  final ConnectivityService service;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Color(service.color);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: Text(
        service.short,
        style: TextStyle(
          color: color,
          fontSize: size * 0.32,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}
