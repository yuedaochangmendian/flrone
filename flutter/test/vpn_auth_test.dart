// OpenVPN/OpenConnect sign-in challenge UI: rendering by kind, answer shape,
// cancel, masking, URL opening, deadline/error and the pushed-event path.
//
// The dialog and coordinator are pure Dart/Flutter — no core or channel is
// needed — so each test injects callbacks and fake status streams directly.

import 'dart:async';

import 'package:flrone/pages/vpn_auth.dart';
import 'package:flrone/widgets.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:flutter_test/flutter_test.dart';

VpnChallenge challengeOf(
  String kind, {
  String tag = 'vpn0',
  String id = 'c1',
  String username = '',
  String message = '',
  String banner = '',
  String error = '',
  String url = '',
  bool echo = false,
  int deadline = 0,
  List<Map<String, dynamic>> fields = const [],
}) =>
    VpnChallenge(
      endpointTag: tag,
      id: id,
      kind: kind,
      username: username,
      message: message,
      banner: banner,
      error: error,
      url: url,
      echo: echo,
      deadline: deadline,
      fields: fields
          .map((item) => VpnField(
                submissionKey: '${item['submission_key'] ?? ''}',
                name: '${item['name'] ?? ''}',
                label: '${item['label'] ?? ''}',
                kind: '${item['kind'] ?? ''}',
                value: '${item['value'] ?? ''}',
                options: [
                  for (final option in item['options'] is List ? item['options'] as List : const [])
                    if (option is Map)
                      VpnChoice(
                          value: '${option['value'] ?? ''}',
                          label: '${option['label'] ?? ''}'),
                ],
              ))
          .toList(),
    );

Future<void> pumpDialog(
  WidgetTester tester, {
  required VpnChallenge challenge,
  required Future<void> Function(Json) onSubmit,
  required Future<void> Function() onCancel,
  void Function(String)? onOpenUrl,
  int Function()? now,
}) async {
  await tester.pumpWidget(material.MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [
      BoxUiDelegate(),
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: const [Locale('en'), Locale('zh')],
    home: Builder(
      builder: (appContext) => MeasureScope(
        measure: Measure.of(appContext, 1),
        child: ViewScope(
          size: const Size(360, 800),
          isMobile: true,
          child: MediaQuery(
            data: MediaQuery.of(appContext).copyWith(
              textScaler: TextScaler.linear(1),
              disableAnimations: true,
            ),
            child: material.Scaffold(
              // The dialog is mounted directly (not through showFloatingDialog)
              // so it stays inside this MeasureScope/ViewScope — the floating
              // overlay route sits at the Navigator root, outside app scopes.
              body: VpnChallengeDialog(
                challenge: challenge,
                onSubmit: onSubmit,
                onCancel: onCancel,
                onOpenUrl: onOpenUrl,
                now: now,
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('challenge parsing and kinds', () {
    test('all six kinds map from the wire strings', () {
      expect(vpnChallengeKindOf('credentials'), VpnChallengeKind.credentials);
      expect(vpnChallengeKindOf('secret'), VpnChallengeKind.secret);
      expect(vpnChallengeKindOf('message'), VpnChallengeKind.message);
      expect(vpnChallengeKindOf('open-url'), VpnChallengeKind.openUrl);
      expect(vpnChallengeKindOf('form'), VpnChallengeKind.form);
      expect(vpnChallengeKindOf('browser'), VpnChallengeKind.browser);
      expect(vpnChallengeKindOf('something-new'), VpnChallengeKind.unknown);
    });

    test('parses a full status list with a pending challenge', () {
      final statuses = parseVpnStatuses([
        {
          'tag': 'vpn0',
          'state': 'auth-pending',
          'connected': false,
          'auth_failed': false,
          'challenge': {
            'endpoint_tag': 'vpn0',
            'id': 'c7',
            'kind': 'credentials',
            'username': 'alice',
            'deadline': 1700000000,
          },
        },
      ]);
      expect(statuses, hasLength(1));
      expect(statuses.single.challenge!.id, 'c7');
      expect(statuses.single.challenge!.username, 'alice');
      final pending = pendingVpnChallenge([
        {
          'tag': 'vpn0',
          'challenge': {'endpoint_tag': 'vpn0', 'id': 'c7', 'kind': 'credentials'},
        },
      ]);
      expect(pending?.id, 'c7');
      expect(pendingVpnChallenge(const []), isNull);
    });

    testWidgets('credentials renders username and a masked password', (tester) async {
      Json? submitted;
      await pumpDialog(
        tester,
        challenge: challengeOf('credentials', username: 'alice'),
        onSubmit: (answer) async => submitted = answer,
        onCancel: () async {},
      );
      expect(find.text('Username'), findsNWidgets(2)); // label + field hint
      expect(find.text('Password'), findsNWidgets(2)); // label + field hint
      expect(find.byTooltip('Show password'), findsOneWidget);
      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      // The last field is the password; it is obscured by default.
      expect(fields.last.obscureText, isTrue);
      await tester.enterText(find.byType(TextField).first, 'bob');
      await tester.enterText(find.byType(TextField).last, 's3cret');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(submitted, {'username': 'bob', 'password': 's3cret'});
    });

    testWidgets('secret with echo=false is masked, echo=true is visible', (tester) async {
      Json? submitted;
      await pumpDialog(
        tester,
        challenge: challengeOf('secret'),
        onSubmit: (answer) async => submitted = answer,
        onCancel: () async {},
      );
      expect(find.byTooltip('Show password'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), '654321');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(submitted, {'secret': '654321'});

      // A second pump with echo=true replaces the tree.
      await pumpDialog(
        tester,
        challenge: challengeOf('secret', id: 'c2', echo: true),
        onSubmit: (answer) async => submitted = answer,
        onCancel: () async {},
      );
      expect(find.byTooltip('Show password'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
    });

    testWidgets('message renders banner and message text', (tester) async {
      await pumpDialog(
        tester,
        challenge: challengeOf(
          'message',
          banner: 'Server banner',
          message: 'Please wait',
        ),
        onSubmit: (_) async {},
        onCancel: () async {},
      );
      expect(find.text('Server banner'), findsOneWidget);
      expect(find.text('Please wait'), findsOneWidget);
    });

    testWidgets('open-url shows the URL and opens it through the callback', (tester) async {
      final opened = <String>[];
      await pumpDialog(
        tester,
        challenge: challengeOf(
          'open-url',
          url: 'https://example.com/sso',
          message: 'Approve the request',
        ),
        onSubmit: (_) async {},
        onCancel: () async {},
        onOpenUrl: opened.add,
      );
      expect(find.text('https://example.com/sso'), findsOneWidget);
      await tester.tap(find.text('Open link'));
      await tester.pumpAndSettle();
      expect(opened, ['https://example.com/sso']);
    });

    testWidgets('browser renders URL and status, with open action', (tester) async {
      final opened = <String>[];
      await pumpDialog(
        tester,
        challenge: challengeOf(
          'browser',
          url: 'https://vpn.example/auth',
          message: 'Browser SSO',
        ),
        onSubmit: (_) async {},
        onCancel: () async {},
        onOpenUrl: opened.add,
      );
      expect(find.text('https://vpn.example/auth'), findsOneWidget);
      expect(
        find.text('Complete the sign-in in the browser, then return here.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Open link'));
      await tester.pumpAndSettle();
      expect(opened, ['https://vpn.example/auth']);
    });

    testWidgets('form builds form_values keyed by submission_key', (tester) async {
      Json? submitted;
      await pumpDialog(
        tester,
        challenge: challengeOf(
          'form',
          fields: [
            {
              'submission_key': 'username',
              'name': 'un',
              'label': 'Account',
              'kind': 'text',
            },
            {
              'submission_key': 'password',
              'name': 'pw',
              'label': 'PIN',
              'kind': 'password',
            },
            {
              'submission_key': 'group',
              'name': 'grp',
              'label': 'Group',
              'kind': 'hidden',
              'value': 'students',
            },
          ],
        ),
        onSubmit: (answer) async => submitted = answer,
        onCancel: () async {},
      );
      expect(find.text('Account'), findsNWidgets(2)); // label + field hint
      expect(find.text('PIN'), findsNWidgets(2)); // label + field hint
      // Hidden field never appears in the UI.
      expect(find.text('Group'), findsNothing);
      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields, hasLength(2));
      expect(fields.last.obscureText, isTrue);
      await tester.enterText(find.byType(TextField).first, 'bob');
      await tester.enterText(find.byType(TextField).last, '1234');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      // Hidden field keeps its server-supplied value but is not displayed.
      expect(submitted, {
        'form_values': {
          'username': 'bob',
          'password': '1234',
          'group': 'students',
        },
      });
    });

    testWidgets('cancel calls the cancel callback with the challenge id', (tester) async {
      var cancelled = false;
      await pumpDialog(
        tester,
        challenge: challengeOf('credentials', id: 'c9'),
        onSubmit: (_) async {},
        onCancel: () async => cancelled = true,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(cancelled, isTrue);
    });

    testWidgets('deadline expiry shows an error and disables submit', (tester) async {
      var now = 1000;
      var submitted = false;
      await pumpDialog(
        tester,
        challenge: challengeOf(
          'credentials',
          deadline: 1010,
          error: 'Previous attempt failed',
        ),
        onSubmit: (_) async => submitted = true,
        onCancel: () async {},
        now: () => now,
      );
      expect(find.text('Previous attempt failed'), findsOneWidget);
      expect(find.text('Expires in 10 s'), findsOneWidget);
      now = 1010;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('This sign-in request has expired.'), findsOneWidget);
      expect(find.text('Expired'), findsOneWidget);
      await tester.tap(find.text('Expired'));
      await tester.pumpAndSettle();
      expect(submitted, isFalse);
    });

    testWidgets('submit failure surfaces the error and keeps the form', (tester) async {
      await pumpDialog(
        tester,
        challenge: challengeOf('secret'),
        onSubmit: (_) async => throw StateError('network down'),
        onCancel: () async {},
      );
      await tester.enterText(find.byType(TextField), '111');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('network down'), findsOneWidget);
      // The field keeps its value so the user can retry.
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '111');
    });

    test('answer builders emit only the documented keys', () {
      expect(credentialsAnswer('a', 'b'), {'username': 'a', 'password': 'b'});
      expect(secretAnswer('s'), {'secret': 's'});
      expect(formAnswer({'k': 'v'}), {'form_values': {'k': 'v'}});
      expect(vpnAckAnswer, isEmpty);
    });
  });

  group('pushed-event path', () {
    test('coordinator queues while a sheet is open and shows the newest', () async {
      final controller = StreamController<List<Json>>.broadcast();
      final presented = <String>[];
      final release = Completer<void>();
      final coordinator = VpnAuthCoordinator(
        present: (challenge) async {
          presented.add(challenge.id);
          if (challenge.id == 'c1') await release.future;
        },
      );
      coordinator.start(controller.stream);

      controller.add([
        {
          'tag': 'vpn0',
          'challenge': {
            'endpoint_tag': 'vpn0',
            'id': 'c1',
            'kind': 'credentials',
          },
        },
      ]);
      await testerWaiting();
      expect(presented, ['c1']);

      // Another push while c1 is on screen queues c2.
      controller.add([
        {
          'tag': 'vpn0',
          'challenge': {
            'endpoint_tag': 'vpn0',
            'id': 'c2',
            'kind': 'secret',
          },
        },
      ]);
      await testerWaiting();
      expect(presented, ['c1']);

      release.complete();
      await testerWaiting();
      await testerWaiting();
      expect(presented, ['c1', 'c2']);
      await coordinator.dispose();
      await controller.close();
    });

    test('coordinator ignores repeated pushes for the same challenge id', () async {
      final controller = StreamController<List<Json>>.broadcast();
      final presented = <String>[];
      final coordinator = VpnAuthCoordinator(
        present: (challenge) async => presented.add(challenge.id),
      );
      coordinator.start(controller.stream);
      final status = [
        {
          'tag': 'vpn0',
          'challenge': {
            'endpoint_tag': 'vpn0',
            'id': 'c1',
            'kind': 'credentials',
          },
        },
      ];
      controller.add(status);
      await testerWaiting();
      controller.add(status);
      await testerWaiting();
      expect(presented, ['c1']);
      // A no-challenge push clears the handled id so a new c1 can show again.
      controller.add(const []);
      await testerWaiting();
      controller.add(status);
      await testerWaiting();
      await testerWaiting();
      expect(presented, ['c1', 'c1']);
      await coordinator.dispose();
      await controller.close();
    });

    test('box event bus fans a vpnStatus push out as a typed stream', () async {
      // BoxController.handleEvent is the exact entry point the service engine's
      // IPC stream feeds, so this pins the push wire shape end to end.
      final box = BoxController(events: const Stream.empty());
      final seen = <List<Json>>[];
      final sub = box.vpnStatuses.listen(seen.add);
      box.handleEvent({
        'type': 'vpnStatus',
        'value': [
          {
            'tag': 'vpn0',
            'challenge': {
              'endpoint_tag': 'vpn0',
              'id': 'c1',
              'kind': 'secret',
            },
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(box.vpnStatusSnapshot, hasLength(1));
      expect(box.vpnStatusSnapshot.single['tag'], 'vpn0');
      expect(seen, hasLength(1));
      expect(seen.single.single['challenge']['id'], 'c1');

      box.handleEvent({'type': 'vpnStatus', 'value': []});
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
      expect(seen.last, isEmpty);
      await sub.cancel();
      box.dispose();
    });
  });
}

/// A microtask yield used by the stream tests (avoiding a widget tester).
Future<void> testerWaiting() => Future<void>.delayed(Duration.zero);
