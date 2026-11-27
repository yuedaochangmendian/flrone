import 'package:flrone/core/kernel_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FFI core startup profile selection', () {
    test('dashboard display id comes from the dashboard wire', () {
      // B-box profile cards carry group ids; UI appearance preferences never
      // hold the selected profile.
      expect(dashboardSelectedId(<String, dynamic>{'selectedProfileId': 7}), 7);
      expect(dashboardSelectedId(<String, dynamic>{}), -1);
    });
  });
}
