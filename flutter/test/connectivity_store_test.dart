import 'package:flrone/components/connectivity/connectivity_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HTTP status maps to the row status without network', () {
    expect(ConnectivityStore.statusForCode(200), ConnectivityStatus.completed);
    expect(ConnectivityStore.statusForCode(302), ConnectivityStatus.completed);
    expect(ConnectivityStore.statusForCode(403), ConnectivityStatus.blocked);
    expect(ConnectivityStore.statusForCode(451), ConnectivityStatus.blocked);
    expect(ConnectivityStore.statusForCode(429), ConnectivityStatus.limited);
    expect(ConnectivityStore.statusForCode(500), ConnectivityStatus.failed);
  });

  test('service ids are unique and lookups resolve', () {
    final ids = connectivityServices.map((service) => service.id).toSet();
    expect(ids.length, connectivityServices.length);
    for (final service in connectivityServices) {
      expect(connectivityService(service.id), same(service));
    }
    expect(connectivityService('missing'), isNull);
  });

  test('completed and blocked classification follows the status', () {
    expect(const ConnectivityResult(status: ConnectivityStatus.completed).isCompleted, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.limited).isCompleted, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.blocked).isBlocked, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.failed).isCompleted, isFalse);
  });
}
