// The host already puts a subscription's quota and expiry on the profile wire
// (`BboxCatalog.trafficOf`/`expiryOf` format them); these tests pin what the
// card and the details page do with them — including the segments that must
// not be printed at all.

import 'dart:async';

import 'package:flrone/components/configuration_card.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/configuration_details.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

const _full = <String, dynamic>{
  'id': 1, 'name': 'Remote A', 'remote': true,
  'traffic': '12.3 GB / 100 GB', 'expiry': 'Until Nov 30, 2026',
};

Future<void> _pumpCard(WidgetTester tester, Json profile,
    {double width = 300, double textScale = 1, Locale locale = const Locale('en')}) async {
  if (textScale != 1) {
    tester.binding.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.binding.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await tester.pumpWidget(TestApp(child: Builder(builder: (context) =>
    Localizations.override(context: context, locale: locale,
      child: Align(alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: ConfigurationCard(profile: profile, selected: false,
          updating: false, onPressed: null, menuItems: const [])))))));
  await tester.pump();
}

Future<void> _mountApp(WidgetTester tester, List<Json> profiles, {int selected = 1}) async {
  tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
  addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const channel = MethodChannel('test.profile-quota');
  final events = StreamController<dynamic>.broadcast();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'ready') {
      return {
        'version': 'test', 'coreVersion': 'test', 'profiles': profiles,
        'preferences': const {'locale': 'en'},
        'dashboard': {'status': 'Stopped', 'selectedProfileId': selected},
      };
    }
    if (call.method == 'profiles.platform' &&
        json(call.arguments)['op'] == 'stats') {
      return {'groups': 1, 'outbounds': 2, 'rules': 3};
    }
    return null;
  });
  final box = BoxController(channel: channel, events: events.stream);
  await tester.pumpWidget(BoxApp(controller: box));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });
}

void main() {
  test('the preformatted wire fields become the facts the card needs', () {
    final full = SubscriptionQuota.of(_full);
    expect(full.traffic, '87.7 GB');
    expect(full.expires, 'Nov 30, 2026');
    expect(full.expired, isFalse);
    expect(full.permanent, isFalse);
    expect(full.isEmpty, isFalse);

    expect(SubscriptionQuota.of(const {}).isEmpty, isTrue);
    expect(SubscriptionQuota.of(const {'traffic': '', 'expiry': '  '}).isEmpty, isTrue);

    // No quota reported: a provider that reports usage is unlimited; zero
    // usage has nothing to say.
    expect(SubscriptionQuota.of(const {'traffic': '12.3 GB'}).traffic, 'Unlimited');
    expect(SubscriptionQuota.of(const {'traffic': '0 B'}).traffic, isNull);
    expect(SubscriptionQuota.of(const {'traffic': '0 B / 0 B'}).traffic, isNull);
    // A quota the provider gave keeps its full remainder visible at zero usage.
    expect(SubscriptionQuota.of(const {'traffic': '0 B / 100 GB'}).traffic, '100.0 GB');

    expect(SubscriptionQuota.of(const {'expiry': 'Expired Jan 5, 2024'}).expired, isTrue);
    expect(SubscriptionQuota.of(const {'expiry': 'Expired Jan 5, 2024'}).expires, 'Jan 5, 2024');

    // A remote subscription without a date is permanent; a local profile is not.
    expect(SubscriptionQuota.of(const {'remote': true, 'traffic': '12.3 GB'}).permanent, isTrue);
    expect(SubscriptionQuota.of(const {'remote': false, 'traffic': '12.3 GB'}).permanent, isFalse);

    // The host formats with the device locale; a comma decimal still parses.
    expect(SubscriptionQuota.of(const {'traffic': '12,3 GB / 100 GB'}).traffic, '87.7 GB');
  });

  testWidgets('the card shows the remainder and the expiry as one line', (tester) async {
    await _pumpCard(tester, _full);
    expect(find.text('Remaining 87.7 GB · Expires Nov 30, 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a subscription without an expiry shows permanent', (tester) async {
    await _pumpCard(tester, {..._full, 'expiry': ''});
    expect(find.text('Remaining 87.7 GB · Permanent'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing pair adds no quota line', (tester) async {
    await _pumpCard(tester, const {'id': 2, 'name': 'Local B', 'remote': false});
    expect(find.byType(SubscriptionQuotaLine), findsNothing);
    expect(find.textContaining('Expires'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zero usage and unlimited quotas read as remaining traffic', (tester) async {
    await _pumpCard(tester, {..._full, 'traffic': '0 B'});
    expect(find.text('Expires Nov 30, 2026'), findsOneWidget);
    expect(find.textContaining('0 B'), findsNothing);

    await _pumpCard(tester, {..._full, 'traffic': '0 B', 'expiry': ''});
    expect(find.byType(SubscriptionQuotaLine), findsNothing);

    await _pumpCard(tester, {..._full, 'traffic': '12.3 GB'});
    expect(find.text('Remaining Unlimited · Expires Nov 30, 2026'), findsOneWidget);

    await _pumpCard(tester, {..._full, 'traffic': '0 B / 100 GB'});
    expect(find.text('Remaining 100.0 GB · Expires Nov 30, 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the quota line fits a narrow card at 1.4 text scale', (tester) async {
    await _pumpCard(tester, _full, width: 240, textScale: 1.4);
    expect(find.byType(SubscriptionQuotaLine), findsOneWidget);
    final text = tester.widget<Text>(find.descendant(
      of: find.byType(SubscriptionQuotaLine), matching: find.byType(Text)));
    expect(text.maxLines, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the remaining and expiry labels are localized', (tester) async {
    await _pumpCard(tester, _full, locale: const Locale('zh'));
    expect(find.text('剩余 87.7 GB · 到期 Nov 30, 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the details page labels the quota and the expiry', (tester) async {
    await _mountApp(tester, [_full]);
    openForm(tester.element(find.byType(HomePage)), const ConfigurationDetailsPage(profile: _full));
    await tester.pumpAndSettle();
    expect(find.text('Remaining'), findsOneWidget);
    expect(find.text('87.7 GB'), findsOneWidget);
    expect(find.text('Expires'), findsOneWidget);
    expect(find.text('Nov 30, 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the details page leaves both rows out without the wire fields', (tester) async {
    const local = <String, dynamic>{'id': 2, 'name': 'Local B', 'remote': false};
    await _mountApp(tester, [local], selected: 2);
    openForm(tester.element(find.byType(HomePage)), const ConfigurationDetailsPage(profile: local));
    await tester.pumpAndSettle();
    expect(find.text('Remaining'), findsNothing);
    expect(find.text('Expires'), findsNothing);
    expect(find.text('Last updated'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
