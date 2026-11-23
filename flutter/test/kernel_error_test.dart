// The one error shape on both sides of the kernel boundary: a refusal carries
// the kernel's code, an unanswered call carries no answer at all. The start
// button's optimism depends on the second one not being mistaken for the first.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flutter_test/flutter_test.dart';

ActionResult _result(int code, Object? data, {String method = 'groupNodes'}) =>
    ActionResult(id: 'groupNodes#1', method: method, code: code, data: data);

void main() {
  group('a refused action', () {
    test('code 0 is a success, not an exception', () {
      final result = _result(0, {'nodes': const []});

      expect(result.isError, isFalse);
      expect(isUnansweredCoreError(null), isFalse);
    });

    test('keeps the kernel code and its string payload', () {
      final error = KernelProxyException.fromActionResult(
        _result(-1, 'instance is not running'),
      );

      expect(error.code, 'core_-1');
      expect(error.message, 'instance is not running');
      expect(error.details, 'instance is not running');
      expect(error.unanswered, isFalse);
      expect(error.refused, isTrue);
      expect(error.toString(), contains('core_-1'));
      expect(isUnansweredCoreError(error), isFalse);
    });

    test('takes the message from a structured payload', () {
      final payload = {'message': 'the profile document is unreadable', 'path': '/x'};
      final error = KernelProxyException.fromActionResult(_result(3, payload));

      expect(error.code, 'core_3');
      expect(error.message, 'the profile document is unreadable');
      expect(error.details, same(payload));
    });

    test('names the method when the payload explains nothing', () {
      final error = KernelProxyException.fromActionResult(_result(7, null));

      expect(error.code, 'core_7');
      expect(error.message, contains('groupNodes'));
      expect(error.details, isNull);
    });
  });

  group('an unanswered call', () {
    test('a transport timeout is unanswered', () {
      expect(isUnansweredCoreError(TimeoutException('no answer')), isTrue);
    });

    test('a bare KernelProxyException is a refusal, not a silence', () {
      const error = KernelProxyException('the core said no');
      expect(error.refused, isTrue);
      expect(isUnansweredCoreError(error), isFalse);
    });

    test('a link failure stays optimistic', () {
      const error = KernelProxyException('the link is down', unanswered: true);
      expect(error.refused, isFalse);
      expect(isUnansweredCoreError(error), isTrue);
      // The historical domain name answers the same question.
      expect(kernelUnanswered(error), isTrue);
    });

    test('an action-bus timeout is unanswered, a refusal is not', () {
      const timedOut = ActionException('speedTestOutbounds', 'timed out', timedOut: true);
      const refused = ActionException('speedTestOutbounds', 'instance is not running');
      expect(isUnansweredCoreError(timedOut), isTrue);
      expect(isUnansweredCoreError(refused), isFalse);
    });

    test('an unrelated error is neither', () {
      expect(isUnansweredCoreError(StateError('boom')), isFalse);
    });
  });
}
