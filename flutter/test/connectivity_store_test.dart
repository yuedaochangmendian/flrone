import 'package:flrone/components/connectivity/connectivity_checker.dart';
import 'package:flrone/components/connectivity/connectivity_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('region normalisation follows the reference mapping', () {
    expect(normalizeRegion('US'), 'US');
    expect(normalizeRegion('us'), 'US');
    expect(normalizeRegion('CHN'), 'CN');
    expect(normalizeRegion('HKG'), 'HK');
    expect(normalizeRegion('USA'), 'US');
    expect(normalizeRegion(''), isNull);
    expect(normalizeRegion(null), isNull);
  });

  test('service ids are unique and lookups resolve', () {
    final ids = connectivityServices.map((service) => service.id).toSet();
    expect(ids.length, connectivityServices.length);
    for (final service in connectivityServices) {
      expect(connectivityService(service.id), same(service));
      expect(service.asset, 'assets/images/platforms/${service.id}.svg');
    }
    expect(connectivityService('missing'), isNull);
  });

  test('status classification follows the reference semantics', () {
    expect(const ConnectivityResult(status: ConnectivityStatus.completed).isCompleted, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.limited).isCompleted, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.blocked).isBlocked, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.flagged).isBlocked, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.failed).isBlocked, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.failed).isCompleted, isFalse);
    expect(const ConnectivityResult(status: ConnectivityStatus.completed).isBlocked, isFalse);
  });

  test('unknown service ids fail without a network call', () async {
    final result = await ConnectivityChecker().check('not-a-service');
    expect(result.status, MediaUnlockStatus.failed);
    expect(result.error, 'unknown service');
  });

  test('more-streaming services are exactly the HK four', () {
    expect(connectivityMoreStreaming, {'mytvsuper', 'viutv', 'hoytv', 'rthk'});
    for (final id in connectivityMoreStreaming) {
      expect(connectivityService(id), isNotNull);
    }
  });
}
