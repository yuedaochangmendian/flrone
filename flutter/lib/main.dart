import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'box.dart';
import 'core/frame_watch.dart';
import 'core/kernel_proxy.dart';
import 'service_entry.dart' as service;

@pragma('vm:entry-point')
Future<void> serviceMain(List<String> args) => service.serviceMain(args);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  imageCache.maximumSizeBytes = 50 << 20;
  final controller = BoxController(kernelControl: KernelProxy());
  FrameWatch(
    report: (text) => unawaited(
      controller.call('log.note', {'text': text}).then((_) {}, onError: (_) {}),
    ),
    context: () => 'status=${controller.dashboard['status']}',
  ).start();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    controller.report(details.exception);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    controller.report(error);
    return true;
  };
  runApp(BoxApp(controller: controller));
}
