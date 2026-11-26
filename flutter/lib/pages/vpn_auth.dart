// OpenVPN / OpenConnect sign-in challenge UI.
//
// The core parks an endpoint on a human and pushes its status list through the
// action bus's `vpnStatus` event (see vpn_auth_actions.go). This file decodes
// that list, renders one challenge by kind, and answers/cancels through the
// BoxController facade in box_api.dart. It holds no answer longer than the
// dialog's lifetime: nothing here is logged or persisted.
//
// Two surfaces share one coordinator: the dashboard's "needs input" hint and
// the app-shell subscription. A challenge that arrives while another sheet is
// open is queued and presented when that sheet closes, so an OTP prompt never
// steals focus mid-edit and is never silently dropped.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets.dart';
import '../components/form.dart';

/// The app-wide VPN auth host: owns the single challenge queue and the pending
/// challenge the dashboard hint reads. Replaced in widget tests with a fake so
/// push paths can be exercised without a native core.
class VpnAuthHost {
  VpnAuthHost(this.coordinator, this.pending);
  final VpnAuthCoordinator coordinator;
  final ValueNotifier<VpnChallenge?> pending;

  Future<void> dispose() => coordinator.dispose();
}

final vpnAuthHostProvider = Provider<VpnAuthHost>((ref) {
  throw UnimplementedError('override vpnAuthHostProvider in BoxApp');
});

/// The six kinds the core emits, plus an unknown fallback so a new upstream
/// kind renders a safe acknowledgement instead of crashing the sheet.
enum VpnChallengeKind { credentials, secret, message, openUrl, form, browser, unknown }

VpnChallengeKind vpnChallengeKindOf(String kind) => switch (kind) {
      'credentials' => VpnChallengeKind.credentials,
      'secret' => VpnChallengeKind.secret,
      'message' => VpnChallengeKind.message,
      'open-url' => VpnChallengeKind.openUrl,
      'form' => VpnChallengeKind.form,
      'browser' => VpnChallengeKind.browser,
      _ => VpnChallengeKind.unknown,
    };

class VpnChoice {
  const VpnChoice({required this.value, required this.label});
  final String value;
  final String label;

  static VpnChoice fromJson(Map<String, dynamic> item) => VpnChoice(
        value: '${item['value'] ?? ''}',
        label: '${item['label'] ?? ''}',
      );
}

class VpnField {
  const VpnField({
    required this.submissionKey,
    required this.name,
    required this.label,
    required this.kind,
    required this.value,
    required this.options,
  });
  final String submissionKey;
  final String name;
  final String label;
  final String kind;
  final String value;
  final List<VpnChoice> options;

  /// `password` and `hidden` are masked; `select` and `text` are not.
  bool get masked => kind == 'password' || kind == 'hidden';
  String get displayLabel {
    final labelText = label.isNotEmpty ? label : name;
    return labelText.isNotEmpty ? labelText : submissionKey;
  }

  static VpnField fromJson(Map<String, dynamic> item) => VpnField(
        submissionKey: '${item['submission_key'] ?? ''}',
        name: '${item['name'] ?? ''}',
        label: '${item['label'] ?? ''}',
        kind: '${item['kind'] ?? ''}',
        value: '${item['value'] ?? ''}',
        options: [
          for (final option in item['options'] is List ? item['options'] as List : const [])
            if (option is Map) VpnChoice.fromJson(json(option)),
        ],
      );
}

class VpnChallenge {
  const VpnChallenge({
    required this.endpointTag,
    required this.id,
    required this.kind,
    required this.username,
    required this.message,
    required this.banner,
    required this.error,
    required this.url,
    required this.echo,
    required this.deadline,
    required this.fields,
  });
  final String endpointTag;
  final String id;
  final String kind;
  final String username;
  final String message;
  final String banner;
  final String error;
  final String url;
  final bool echo;
  final int deadline;
  final List<VpnField> fields;

  VpnChallengeKind get type => vpnChallengeKindOf(kind);
  bool get hasError => error.isNotEmpty;
  bool expiredAt(int nowSeconds) => deadline > 0 && nowSeconds >= deadline;
  int remainingAt(int nowSeconds) => deadline > 0 ? deadline - nowSeconds : 0;

  static VpnChallenge fromJson(Map<String, dynamic> item) => VpnChallenge(
        endpointTag: '${item['endpoint_tag'] ?? ''}',
        id: '${item['id'] ?? ''}',
        kind: '${item['kind'] ?? ''}',
        username: '${item['username'] ?? ''}',
        message: '${item['message'] ?? ''}',
        banner: '${item['banner'] ?? ''}',
        error: '${item['error'] ?? ''}',
        url: '${item['url'] ?? ''}',
        echo: item['echo'] == true,
        deadline: (item['deadline'] as num?)?.toInt() ?? 0,
        fields: [
          for (final field in item['fields'] is List ? item['fields'] as List : const [])
            if (field is Map) VpnField.fromJson(json(field)),
        ],
      );
}

class VpnEndpointStatus {
  const VpnEndpointStatus({
    required this.tag,
    required this.state,
    required this.error,
    required this.connected,
    required this.authFailed,
    required this.challenge,
  });
  final String tag;
  final String state;
  final String error;
  final bool connected;
  final bool authFailed;
  final VpnChallenge? challenge;

  static VpnEndpointStatus fromJson(Map<String, dynamic> item) {
    final raw = item['challenge'];
    return VpnEndpointStatus(
      tag: '${item['tag'] ?? ''}',
      state: '${item['state'] ?? ''}',
      error: '${item['error'] ?? ''}',
      connected: item['connected'] == true,
      authFailed: item['auth_failed'] == true,
      challenge: raw is Map ? VpnChallenge.fromJson(json(raw)) : null,
    );
  }
}

List<VpnEndpointStatus> parseVpnStatuses(List<Json> statuses) => [
      for (final item in statuses) VpnEndpointStatus.fromJson(item),
    ];

/// The first endpoint parked on a human, or null. The coordinator and the
/// dashboard hint both use this so they cannot disagree about what "needs
/// input" means.
VpnChallenge? pendingVpnChallenge(List<Json> statuses) {
  for (final status in parseVpnStatuses(statuses)) {
    if (status.challenge != null) return status.challenge;
  }
  return null;
}

/// Answer builders. The core reads username/password/secret for OpenVPN and
/// form_values (keyed by submission_key) for OpenConnect; anything else is
/// dropped at the Go boundary, so building only these keys is both correct and
/// the simplest way to keep secrets out of logs and persistence.
Json credentialsAnswer(String username, String password) =>
    <String, dynamic>{'username': username, 'password': password};

Json secretAnswer(String secret) => <String, dynamic>{'secret': secret};

Json formAnswer(Map<String, String> values) =>
    <String, dynamic>{'form_values': Map<String, String>.from(values)};

const Json vpnAckAnswer = <String, dynamic>{};

/// Renders one challenge. All three callbacks are injected so widget tests can
/// assert the shape of the answer, the cancelled id and the opened URL without
/// a running core.
class VpnChallengeDialog extends StatefulWidget {
  const VpnChallengeDialog({
    super.key,
    required this.challenge,
    required this.onSubmit,
    required this.onCancel,
    this.onOpenUrl,
    int Function()? now,
  }) : _now = now;

  final VpnChallenge challenge;
  final Future<void> Function(Json answer) onSubmit;
  final Future<void> Function() onCancel;
  final void Function(String url)? onOpenUrl;
  final int Function()? _now;

  int get nowSeconds => (_now ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000)();

  @override
  State<VpnChallengeDialog> createState() => _VpnChallengeDialogState();
}

class _VpnChallengeDialogState extends State<VpnChallengeDialog> {
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _secret;
  late final List<TextEditingController> _formControllers;
  late final List<String> _formValues;
  Timer? _deadlineTimer;
  bool _busy = false;
  String? _error;

  /// Android Back is routed through the same guarded cancel as the Cancel
  /// button. The route stays put until [VpnChallengeDialog.onCancel] decides to
  /// pop it (the caller owns the route), so a second Back while the first is
  /// still being answered must not send a second cancellation to the core.
  bool _backHandled = false;

  bool get _expired => widget.challenge.expiredAt(widget.nowSeconds);

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: widget.challenge.username);
    _password = TextEditingController();
    _secret = TextEditingController();
    _formControllers = [
      for (final field in widget.challenge.fields)
        TextEditingController(text: field.value),
    ];
    _formValues = [for (final field in widget.challenge.fields) field.value];
    // A deadline counts down without blocking the UI: one tick a second is
    // enough to retire a stale prompt, and the timer dies with the dialog.
    if (widget.challenge.deadline > 0) {
      _deadlineTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (_expired) _deadlineTimer?.cancel();
      });
    }
  }

  @override
  void dispose() {
    _deadlineTimer?.cancel();
    _username.dispose();
    _password.dispose();
    _secret.dispose();
    for (final controller in _formControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  String _kindTitle(VpnChallengeKind kind) => switch (kind) {
        VpnChallengeKind.credentials => 'Credentials',
        VpnChallengeKind.secret => 'Verification code',
        VpnChallengeKind.message => 'Message',
        VpnChallengeKind.openUrl => 'Open link',
        VpnChallengeKind.form => 'Sign in',
        VpnChallengeKind.browser => 'Browser sign-in',
        VpnChallengeKind.unknown => 'Sign in',
      };

  Future<void> _submit(Json answer) async {
    if (_busy || _expired) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(answer);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onCancel();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(int index, VpnField field) async {
    final picked = await showOptionSheet<String>(
      context: context,
      title: field.displayLabel,
      options: [for (final choice in field.options) (choice.value, choice.label)],
      selected: _formValues[index],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _formValues[index] = picked;
      _formControllers[index].text = picked;
    });
  }

  Widget _textRow({
    required String label,
    required TextEditingController controller,
    bool masked = false,
    String? hint,
  }) =>
      FormRow(
        title: label,
        trailing: masked
            ? FormRowSecretTextField(controller: controller, hintText: hint)
            : FormRowTextField(controller: controller, hintText: hint),
      );

  List<Widget> _fields() {
    final challenge = widget.challenge;
    final body = <Widget>[];
    final banner = challenge.banner;
    if (banner.isNotEmpty) {
      body.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(banner, style: context.listCaptionStyle),
      ));
    }
    if (challenge.hasError) {
      body.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(challenge.error,
            style: context.listCaptionStyle.copyWith(color: context.colorScheme.error)),
      ));
    }
    if (_error != null) {
      body.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(_error!,
            style: context.listCaptionStyle.copyWith(color: context.colorScheme.error)),
      ));
    }
    final message = challenge.message;
    if (message.isNotEmpty) {
      body.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(message),
      ));
    }
    switch (challenge.type) {
      case VpnChallengeKind.credentials:
        body.add(_textRow(
            label: context.tr('Username'),
            controller: _username,
            hint: context.tr('Username')));
        // A password field is always masked, regardless of the challenge's
        // echo flag — echo only governs the single-field `secret` kind.
        body.add(_textRow(
            label: context.tr('Password'),
            controller: _password,
            masked: true,
            hint: context.tr('Password')));
      case VpnChallengeKind.secret:
        body.add(_textRow(
            label: context.tr('Verification code'),
            // echo=false means the answer is a secret: mask it. echo=true is a
            // visible one-time code the user must read back, so leave it open.
            controller: _secret,
            masked: !challenge.echo,
            hint: context.tr('Verification code')));
      case VpnChallengeKind.form:
        for (var i = 0; i < challenge.fields.length; i++) {
          final field = challenge.fields[i];
          if (field.kind == 'hidden') {
            // Hidden fields carry a server-supplied value keyed by
            // submission_key; keep it out of the UI entirely.
            continue;
          }
          if (field.kind == 'select' && field.options.isNotEmpty) {
            body.add(FormRow(
              title: field.displayLabel,
              trailing: Text(_formValues[i]),
              onPressed: () => _pick(i, field),
            ));
          } else {
            body.add(_textRow(
                label: field.displayLabel,
                controller: _formControllers[i],
                masked: field.masked,
                hint: field.displayLabel));
          }
        }
      case VpnChallengeKind.openUrl:
      case VpnChallengeKind.browser:
        body.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(challenge.url.isNotEmpty
              ? challenge.url
              : context.tr('No link was provided')),
        ));
        body.add(Text(context.tr('Complete the sign-in in the browser, then return here.'),
            style: context.listCaptionStyle));
      case VpnChallengeKind.message:
      case VpnChallengeKind.unknown:
        break;
    }
    if (challenge.deadline > 0) {
      final remaining = challenge.remainingAt(widget.nowSeconds);
      body.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          _expired
              ? context.tr('This sign-in request has expired.')
              : context.tr('Expires in {seconds} s').replaceAll('{seconds}', '$remaining'),
          style: context.listCaptionStyle.copyWith(
            color: _expired ? context.colorScheme.error : null,
          ),
        ),
      ));
    }
    return body;
  }

  Json _answer() {
    switch (widget.challenge.type) {
      case VpnChallengeKind.credentials:
        return credentialsAnswer(_username.text, _password.text);
      case VpnChallengeKind.secret:
        return secretAnswer(_secret.text);
      case VpnChallengeKind.form:
        final values = <String, String>{};
        for (var i = 0; i < widget.challenge.fields.length; i++) {
          final field = widget.challenge.fields[i];
          if (field.submissionKey.isEmpty) continue;
          // Text fields write into their controller; select/hidden fields keep
          // their value in _formValues. Reading the controller for every field
          // keeps both in one place and avoids a stale value after typing.
          values[field.submissionKey] =
              field.kind == 'select' || field.kind == 'hidden'
                  ? _formValues[i]
                  : _formControllers[i].text;
        }
        return formAnswer(values);
      default:
        return vpnAckAnswer;
    }
  }

  bool get _hasUrl => widget.challenge.url.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final challenge = widget.challenge;
    final canSubmit = !_busy && !_expired;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _backHandled) return;
        _backHandled = true;
        // The caller's onCancel pops the route after the core acknowledged it.
        // A failed cancel keeps the sheet (and its fields) on screen, so a
        // later Back is ignored rather than duplicating the request.
        unawaited(_cancel());
      },
      child: AlertDialog(
      title: '${challenge.endpointTag} · ${context.tr(_kindTitle(challenge.type))}',
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _fields(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _cancel,
          child: Text(context.tr('Cancel')),
        ),
        if (_hasUrl && widget.onOpenUrl != null)
          TextButton(
            onPressed: () => widget.onOpenUrl!(challenge.url),
            child: Text(context.tr('Open link')),
          ),
        FilledButton(
          onPressed: canSubmit ? () => _submit(_answer()) : null,
          child: Text(context.tr(_expired ? 'Expired' : 'Submit')),
        ),
      ],
      ),
    );
  }

  /// Exposed for widget tests: builds the answer from the current field values
  /// using only the core's four documented keys.
  Json answerForTest() => _answer();
}

/// Opens a challenge dialog and waits for it to close. The dialog itself never
/// pops the route: the caller decides when to dismiss after submit/cancel, so
/// a failed submit keeps the form and its values on screen.
Future<void> showVpnChallengeDialog(
  BuildContext context, {
  required VpnChallenge challenge,
  required Future<void> Function(Json answer) onSubmit,
  required Future<void> Function() onCancel,
  void Function(String url)? onOpenUrl,
  int Function()? now,
}) async {
  await showAppDialog<void>(
    context,
    dismissible: false,
    child: VpnChallengeDialog(
      challenge: challenge,
      onSubmit: onSubmit,
      onCancel: onCancel,
      onOpenUrl: onOpenUrl,
      now: now,
    ),
  );
}

/// Queues pushed challenges so a prompt arriving over another screen waits its
/// turn. At most one is on screen; while one is open the newest pending one
/// wins (an OTP supersedes the challenge it replaced). [present] is injected
/// so the queue semantics are unit-testable without Flutter navigation.
class VpnAuthCoordinator {
  VpnAuthCoordinator({
    required this.present,
    int Function()? now,
  }) : _now = now;

  final Future<void> Function(VpnChallenge challenge) present;
  final int Function()? _now;
  StreamSubscription<List<Json>>? _subscription;
  bool _open = false;
  VpnChallenge? _pending;
  String? _handledId;

  int get _nowSeconds => (_now ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000)();

  /// Starts listening. Idempotent: a second start cannot double-subscribe.
  void start(Stream<List<Json>> statuses) {
    if (_subscription != null) return;
    _subscription = statuses.listen(_onStatus);
  }

  void _onStatus(List<Json> statuses) {
    final challenge = pendingVpnChallenge(statuses);
    if (challenge == null) {
      // No prompt means the previous one was answered or cancelled. Forget the
      // id so a genuinely new challenge with the same text can be shown again.
      if (!_open) _handledId = null;
      return;
    }
    if (_open) {
      _pending = challenge;
      return;
    }
    unawaited(_show(challenge));
  }

  Future<void> _show(VpnChallenge challenge) async {
    if (_open) {
      _pending = challenge;
      return;
    }
    // A push may repeat the same state many times while the user is looking at
    // another screen. Only a new challenge id is worth re-presenting.
    if (challenge.id.isNotEmpty && challenge.id == _handledId) return;
    _open = true;
    _handledId = challenge.id;
    try {
      await present(challenge);
    } on Object {
      // A failed presentation must not wedge the queue: the next push can try
      // again, and the dashboard hint remains available as a manual fallback.
    } finally {
      _open = false;
      final next = _pending;
      _pending = null;
      if (next != null && !next.expiredAt(_nowSeconds)) unawaited(_show(next));
    }
  }

  /// Opens the currently pending challenge from a UI tap (dashboard hint).
  Future<void> openNow(List<Json> statuses) async {
    final challenge = pendingVpnChallenge(statuses);
    if (challenge != null) await _show(challenge);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _pending = null;
  }
}
