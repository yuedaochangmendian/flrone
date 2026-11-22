import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/pages/access.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Scaffold scaffold(WidgetTester tester) => tester.widget<Scaffold>(
  find.descendant(of: find.byType(AccessPage), matching: find.byType(Scaffold)).first,
);

PopupMenuItem action(WidgetTester tester, String label) {
  Iterable<PopupMenuItem> flatten(List<PopupMenuItem> items) sync* {
    for (final item in items) {
      yield item;
      yield* flatten(item.subItems);
    }
  }
  return flatten(scaffold(tester).menuItems).firstWhere((item) => item.label == label);
}

Future<BoxController> openAccess(WidgetTester tester, Future<Object?> Function(MethodCall) handler,
  {StreamController<dynamic>? eventController}) async {
  tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
  addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
  const channel = MethodChannel('test.access-loading');
  final events = eventController ?? StreamController<dynamic>.broadcast();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, handler);
  final box = BoxController(channel: channel, events: events.stream);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });
  await tester.pumpWidget(BoxApp(controller: box));
  await tester.pumpAndSettle();
  openPage(tester.element(find.byType(HomePage)), const AccessPage());
  await tester.pumpAndSettle();
  return box;
}

const visibleApp = {'package': 'visible.app', 'name': 'Visible app', 'internet': true};
/// A row the host's mainland classifier answers for (`apps.china`).
const chinaApp = {'package': 'com.tencent.mm', 'name': 'WeChat', 'internet': true};
const systemApp = {'package': 'system.app', 'name': 'System app', 'internet': true, 'system': true};
const offlineApp = {'package': 'offline.app', 'name': 'Offline app', 'internet': false};
Json ready([Json settings = const {}]) => {'version': 'test', 'coreVersion': 'test',
  'settings': {'perAppEnabled': true, ...settings}, 'dashboard': {'status': 'Stopped'}};

void main() {
  testWidgets('app selections remain editable after a failed save', (tester) async {
    var reject = true;
    final edits = <Json>[];
    await openAccess(tester, (call) async {
      if (call.method == 'ready') return ready({'perAppMode': 1, 'perAppList': ['hidden.app']});
      if (call.method == 'apps.list') return [visibleApp];
      if (call.method == 'settings.patch') {
        edits.add(json(json(call.arguments)['value']));
        if (reject) throw PlatformException(code: 'disk', message: 'Save failed');
        return edits.last;
      }
      return null;
    });
    await tester.tap(find.text('Visible app'));
    await tester.pumpAndSettle();
    expect(edits, isEmpty);
    scaffold(tester).confirmationAction!.onPressed!();
    await tester.pumpAndSettle();
    expect(find.byType(AccessPage), findsOneWidget);
    expect(scaffold(tester).confirmationAction, isNotNull);
    reject = false;
    scaffold(tester).confirmationAction!.onPressed!();
    await tester.pumpAndSettle();
    expect(edits, hasLength(2));
    expect(edits.last['perAppList'], containsAll(['visible.app', 'hidden.app']));
    expect(edits.last['perAppEnabled'], true);
    expect(scaffold(tester).confirmationAction, isNull);
  });

  testWidgets('filters request cached metadata and preserve selections for hidden apps', (tester) async {
    final lists = <Json>[];
    final icons = <String>[];
    Json? saved;
    await openAccess(tester, (call) async {
      if (call.method == 'ready') return ready({'perAppList': ['offline.app']});
      if (call.method == 'apps.list') {
        final args = json(call.arguments);
        lists.add(args);
        return [visibleApp, if (args['system'] == true) systemApp, if (args['nonInternet'] == true) offlineApp];
      }
      if (call.method == 'apps.icon') icons.add(json(call.arguments)['package'] as String);
      if (call.method == 'settings.patch') { saved = json(json(call.arguments)['value']); return saved; }
      return null;
    });
    expect(lists, [{'refresh': true, 'system': false, 'nonInternet': false}]);
    expect(find.text('Visible app'), findsOneWidget);
    expect(find.text('System app'), findsNothing);
    action(tester, 'Show system apps').onPressed!();
    await tester.pumpAndSettle();
    expect(lists.last, {'refresh': false, 'system': true, 'nonInternet': false});
    expect(find.text('System app'), findsOneWidget);
    action(tester, 'Show apps without Internet permission').onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('Offline app'), findsOneWidget);
    expect(icons.where((package) => package == 'visible.app'), hasLength(1));
    action(tester, 'Show apps without Internet permission').onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Visible app'));
    await tester.pumpAndSettle();
    scaffold(tester).confirmationAction!.onPressed!();
    await tester.pumpAndSettle();
    expect(saved!['perAppList'], containsAll(['visible.app', 'offline.app']));
    expect(tester.takeException(), isNull);
  });

  /// One tap, direction by mode: Bettbox's 智能选择 fills the draft, Save commits it.
  Future<void> smartSelect(WidgetTester tester, int mode, {required List<String> expectList}) async {
    Json? saved;
    await openAccess(tester, (call) async {
      if (call.method == 'ready') return ready({'perAppMode': mode, 'perAppList': []});
      if (call.method == 'apps.list') return [visibleApp, chinaApp];
      if (call.method == 'apps.china') return ['com.tencent.mm'];
      if (call.method == 'settings.patch') { saved = json(json(call.arguments)['value']); return saved; }
      return null;
    });
    action(tester, 'Smart select').onPressed!();
    await tester.pumpAndSettle();
    scaffold(tester).confirmationAction!.onPressed!();
    await tester.pumpAndSettle();
    expect(saved!['perAppList'], expectList);
    expect(tester.takeException(), isNull);
  }

  testWidgets('smart select proxies everything that is not a mainland app', (tester) async {
    // Mode 2 = "proxy selected apps": the selection is the complement of the classification.
    await smartSelect(tester, 2, expectList: ['visible.app']);
  });

  testWidgets('smart select bypasses exactly the mainland apps', (tester) async {
    // Mode 1 = "bypass selected apps": the selection is the classification itself.
    await smartSelect(tester, 1, expectList: ['com.tencent.mm']);
  });
}
