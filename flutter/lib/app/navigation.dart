import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

final tabIndexProvider = StateProvider<int>((ref) => 0);

Future<T?> openPage<T>(BuildContext context, Widget page) {
  return Navigator.of(context).push<T>(HomeRoute<T>(builder: (_) => page));
}
