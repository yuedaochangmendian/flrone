import 'package:flrone/app/app.dart';
import 'package:flrone/box.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBox extends BoxController {
  _FakeBox() : super(channel: const MethodChannel('flrone.test'));

  @override
  Future<void> initialize() async {
    ready = true;
    version = 'test';
    coreVersion = 'test';
    dashboard = {
      'status': 'Started',
      'startedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120,
      'uploadTotal': 1024,
      'downloadTotal': 4096,
      'connections': 1,
      'selectedProfileId': 1,
      'modes': ['rule', 'global', 'direct'],
      'mode': 'rule',
    };
    profiles = [
      {'id': 1, 'name': 'Test profile', 'type': 'local', 'nodeCount': 2},
    ];
    groups = [
      {
        'tag': 'Proxy',
        'selected': 'Node A',
        'selectedId': 1,
        'selectable': true,
        'nodeCount': 2,
        'items': [
          {'id': 1, 'tag': 'Node A', 'delay': 20},
          {'id': 2, 'tag': 'Node B', 'delay': 80},
        ],
      },
    ];
    connections = [
      {
        'id': '1',
        'displayDestination': 'example.com:443',
        'network': 'tcp',
        'rule': 'MATCH',
        'outbound': 'Proxy',
        'source': 'com.example',
        'uploadTotal': 100,
        'downloadTotal': 200,
      },
    ];
    logs = [
      {'message': 'test log', 'level': 'info'},
    ];
    memory = {'rss': 1024, 'app': 512, 'core': 256, 'other': 256};
    lan = {
      'addresses': ['192.168.1.2'],
      'enabled': false,
      'canToggle': false,
    };
    preferences = {'theme': 'light'};
    notifyListeners();
  }

  @override
  void setGroupsVisible(Object owner, bool visible) {}
}

void main() {
  testWidgets('the rebuilt shell renders', (tester) async {
    final box = _FakeBox();
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Test profile'), findsWidgets);
    expect(find.text('Running'), findsWidgets);
  });

  testWidgets('the desktop sidebar switches pages', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final box = _FakeBox();
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Test profile'), findsWidgets);
    await tester.tap(find.text('Proxies').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Proxy'), findsWidgets);
    await tester.tap(find.text('Profiles').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Test profile'), findsWidgets);
    await tester.tap(find.text('Requests').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('example.com:443'), findsWidgets);
    await tester.tap(find.text('Tools').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('General'), findsWidgets);
  });
}
