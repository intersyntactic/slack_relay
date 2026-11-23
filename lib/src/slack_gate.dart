/// Decides whether an inbound Slack delivery is authentic and worth acting on.
///
/// A sibling of intersyntactic's `webhook_gate.dart`, not an extension of it:
/// Slack signs `v0:{timestamp}:{body}` rather than the bare body, carries the
/// event kind inside the signed payload rather than in a header, and
/// (crucially for us) delivers slash commands whose `text` the receiver must
/// ACT ON, not merely re-read something idempotent in response to. That last
/// point is the one `webhook_gate.dart`'s long comment calls out as the
/// condition under which "digest-keyed replay protection becomes required":
/// the Slack gate therefore takes a `hasSeen` closure and refuses a signature
/// it has seen before.
///
/// Pure, like its sibling: the replay cache is caller-owned, so the gate's
/// cases are testable without a clock, a socket, or Slack.
///
/// Slack's own `X-Slack-Request-Timestamp` is signed (unlike GitHub's
/// `X-GitHub-Delivery`), so a replayer cannot edit it to defeat a signature
/// cache. The timestamp window below (default 5 min, per Slack's docs) bounds
/// how long a captured delivery remains replayable at all; the digest cache
/// collapses it further to "once".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'slack_delivery.dart';
import 'slack_event.dart';

/// What the caller should do.
enum SlackGateOutcome {
  /// Fan this doorbell out to listeners; answer 200.
  trigger,

  /// Authentic but uninteresting (a quiet event, or a replay we have already
  /// delivered once). Answer 200; do not fan out.
  ignore,

  /// The one-time setup handshake. Answer 200 with [SlackGateDecision.challenge]
  /// in the response body; do not fan out.
  urlVerification,

  /// Refused. Never say why in the response body; the log may.
  reject,
}

class SlackGateDecision {
  final SlackGateOutcome outcome;

  /// Operator-facing, logged. A rejection reason in a response body is a hint
  /// to whoever is guessing at the signature.
  final String reason;

  /// What arrived, present iff [outcome] == [SlackGateOutcome.trigger].
  final SlackEvent? event;

  /// Challenge to echo in the response body, present iff
  /// [outcome] == [SlackGateOutcome.urlVerification].
  final String? challenge;

  /// The digest the caller should add to its replay cache. Present on every
  /// outcome except [SlackGateOutcome.reject], so that an authentic
  /// replay-of-ignore does not become a trigger if someone changes the wake
  /// set mid-flight.
  final String? digest;

  const SlackGateDecision(
    this.outcome,
    this.reason, {
    this.event,
    this.challenge,
    this.digest,
  });

  bool get shouldBroadcast => outcome == SlackGateOutcome.trigger;
}

class SlackSourceSpec {
  /// Slack's "Signing Secret" from the app's Basic Information page. Empty is
  /// a configuration error — the gate refuses rather than opens.
  final String signingSecret;

  /// Workspaces this gate accepts events from. Empty means "accept any
  /// workspace that signs correctly", which is only ever right in tests.
  final Set<String> teamIdAllowlist;

  /// Inner event types from an `event_callback` that should wake listeners.
  /// Anything else (including a well-known-but-uninteresting kind) is
  /// [SlackGateOutcome.ignore]d.
  final Set<SlackEventType> wakeEventTypes;

  /// Slash commands that should wake listeners.
  final Set<String> wakeCommands;

  const SlackSourceSpec({
    required this.signingSecret,
    this.teamIdAllowlist = const {},
    this.wakeEventTypes = const {
      SlackEventType.appMention,
      SlackEventType.message,
      SlackEventType.reactionAdded,
      SlackEventType.reactionRemoved,
    },
    this.wakeCommands = const {'/model', '/connect', '/forget'},
  });
}

/// The hex HMAC-SHA256 Slack expects: `v0=` + hex(hmac(secret, "v0:{ts}:{body}")).
/// Returned WITHOUT the `v0=` prefix; the caller compares the suffixes.
String slackSignBody(String secret, String timestamp, List<int> body) {
  final mac = Hmac(sha256, utf8.encode(secret));
  final input = <int>[...utf8.encode('v0:$timestamp:'), ...body];
  return mac.convert(input).toString();
}

/// Constant-time comparison. A `==` on a hex digest leaks, through timing, how
/// many leading characters a guess got right, which turns forging a signature
/// into a per-character search instead of a 2^256 one. Length is compared
/// first and separately because differing lengths cannot be compared in
/// constant time anyway, and length is not the secret.
///
/// Inlined (rather than imported from intersyntactic's `webhook_gate.dart`):
/// this package depends on `crypto` alone.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

SlackGateDecision slackGate({
  required SlackSourceSpec spec,
  required Map<String, String> headers,
  required List<int> body,
  required String contentType,
  required DateTime now,
  bool Function(String digest)? hasSeen,
  Duration maxTimestampSkew = const Duration(minutes: 5),
  int maxBodyBytes = 1024 * 1024,
}) {
  // FAIL CLOSED on a missing secret. Matches `webhook_gate.dart`: a deploy
  // that forgot to set an env var becomes a refuser, not a public endpoint.
  if (spec.signingSecret.isEmpty) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'slack signing secret not configured',
    );
  }

  if (body.length > maxBodyBytes) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'body ${body.length}b over cap',
    );
  }

  final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value};

  final timestamp = lower['x-slack-request-timestamp'];
  if (timestamp == null || timestamp.isEmpty) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'missing x-slack-request-timestamp',
    );
  }
  final tsSeconds = int.tryParse(timestamp);
  if (tsSeconds == null) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'x-slack-request-timestamp is not an integer',
    );
  }

  // Per Slack's docs: refuse timestamps more than 5 minutes off. Both
  // directions matter: a future timestamp is as suspicious as a past one, and
  // a clock stepped backwards must not open a replay window into the future.
  final skew = now.difference(
    DateTime.fromMillisecondsSinceEpoch(tsSeconds * 1000, isUtc: true),
  );
  if (skew.abs() > maxTimestampSkew) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'timestamp ${skew.inSeconds}s off',
    );
  }

  final presented = lower['x-slack-signature'];
  if (presented == null || presented.isEmpty) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'missing x-slack-signature',
    );
  }
  const prefix = 'v0=';
  if (!presented.startsWith(prefix)) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'signature prefix not recognised',
    );
  }
  final expected = slackSignBody(spec.signingSecret, timestamp, body);
  final offered = presented.substring(prefix.length).toLowerCase();
  if (!constantTimeEquals(expected, offered)) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'signature mismatch',
    );
  }

  // Authentic from here. The signature itself is the dedupe key: it is bound
  // to the body AND the signed timestamp, so a replay reproduces it exactly
  // and a tampered body never gets this far.
  final digest = expected;
  if (hasSeen != null && hasSeen(digest)) {
    return SlackGateDecision(SlackGateOutcome.ignore, 'replay', digest: digest);
  }

  // Both body shapes Slack sends have already been signed, so a lying
  // content type only turns a valid delivery into a refusal.
  final mime = contentType.split(';').first.trim().toLowerCase();
  if (_SlackBodyType.parse(mime) == null) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'unexpected content type "$mime"',
      digest: digest,
    );
  }

  final SlackEvent event;
  switch (readSlackDelivery(Uint8List.fromList(body))) {
    case SlackMalformed(:final reason):
      return SlackGateDecision(SlackGateOutcome.reject, reason, digest: digest);
    case SlackNotCovered(:final reason):
      return SlackGateDecision(
        SlackGateOutcome.ignore,
        'not covered: $reason',
        digest: digest,
      );
    case SlackHandshake(:final challenge):
      return SlackGateDecision(
        SlackGateOutcome.urlVerification,
        'handshake',
        challenge: challenge,
        digest: digest,
      );
    case SlackDeliveredEvent(event: final e):
      event = e;
  }

  // Workspace allowlist. Checked AFTER the signature, so timing cannot be
  // used to probe which workspaces are allowed.
  if (spec.teamIdAllowlist.isNotEmpty &&
      !spec.teamIdAllowlist.contains(event.workspace)) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'team "${event.workspace}" not in allowlist',
      digest: digest,
    );
  }

  (bool, String) ofType(SlackEventType type) =>
      (spec.wakeEventTypes.contains(type), 'event "${type.wireName}"');
  final (wakes, name) = switch (event) {
    SlackCommand(:final command) => (
      spec.wakeCommands.contains(command),
      'command "$command"',
    ),
    SlackMessage(mention: true) => ofType(SlackEventType.appMention),
    SlackMessage() => ofType(SlackEventType.message),
    SlackReactionAdded() => ofType(SlackEventType.reactionAdded),
    SlackReactionRemoved() => ofType(SlackEventType.reactionRemoved),
  };
  return wakes
      ? SlackGateDecision(
          SlackGateOutcome.trigger,
          name,
          event: event,
          digest: digest,
        )
      : SlackGateDecision(
          SlackGateOutcome.ignore,
          'quiet $name',
          digest: digest,
        );
}

/// The media types Slack posts a body as.
enum _SlackBodyType {
  json('application/json'),
  form('application/x-www-form-urlencoded');

  const _SlackBodyType(this.mime);

  final String mime;

  static _SlackBodyType? parse(String mime) {
    for (final t in values) {
      if (t.mime == mime) return t;
    }
    return null;
  }
}
