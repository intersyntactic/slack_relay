/// Slack's check of a delivery, for an is_relay [RelayServer]: the signed
/// timestamp and the HMAC over `v0:<timestamp>:<body>`, then the workspace.
///
/// There is no wake filter and no replay cache. Every authentic delivery is
/// recorded, url_verification included, and the translator decides what each
/// one means; the docking station takes each event key once.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:crypto/crypto.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show RelayedEventSource;
import 'package:is_relay/is_relay.dart';

import 'slack_delivery.dart';

/// The source Slack deliveries are recorded as: kind `slack-event`.
final slackEventSource = RelayedEventSource.parse('slack')!;

/// The path Slack's Event Subscriptions and Slash Commands both post to.
final slackRelayPath = RelayPath.parse('/webhook/slack')!;

/// A whole request's time. Slack sends a delivery again after 3 s without
/// an answer.
const slackRelayBudget = Duration(milliseconds: 2500);

/// The app's signing secret, from its Basic Information page. Never empty:
/// an empty one would sign anything a guesser chose.
final class SlackSigningSecret {
  const SlackSigningSecret._(this._value);

  /// [s] as a secret, or null when it is empty.
  static SlackSigningSecret? parse(String s) =>
      s.isEmpty ? null : SlackSigningSecret._(s);

  final String _value;

  /// The hex HMAC-SHA256 Slack sends after `v0=`, over `v0:<timestamp>:` and
  /// [body].
  String sign(String timestamp, List<int> body) {
    final mac = Hmac(sha256, utf8.encode(_value));
    return mac.convert([...utf8.encode('v0:$timestamp:'), ...body]).toString();
  }

  @override
  String toString() => 'SlackSigningSecret(…)';
}

/// What the headers vouched for: a timestamp inside the window, and the
/// signature offered for it, still to be compared against the body. Only
/// [SlackDeliveryCheck.checkHeaders] makes one.
final class SlackSignedHeaders {
  const SlackSignedHeaders._(this._timestamp, this._signature);

  /// As sent: the HMAC is over these exact characters.
  final String _timestamp;

  /// The hex after `v0=`, lower-cased.
  final String _signature;
}

/// The workspaces (team ids) deliveries are taken from. Never empty: there is
/// no "any workspace", so a relay can't be built that takes every workspace
/// the app is installed in.
final class SlackWorkspaces {
  const SlackWorkspaces._(this._ids);

  /// [ids], blanks aside, or null when none is left.
  static SlackWorkspaces? of(Iterable<String> ids) {
    final kept = {
      for (final id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    };
    return kept.isEmpty ? null : SlackWorkspaces._(Set.unmodifiable(kept));
  }

  /// A comma-separated list, as `SLACK_TEAM_IDS` holds it.
  static SlackWorkspaces? parse(String commaSeparated) =>
      of(commaSeparated.split(','));

  final Set<String> _ids;

  bool contains(String workspace) => _ids.contains(workspace);
}

final class SlackDeliveryCheck implements ChecksDeliveries<SlackSignedHeaders> {
  SlackDeliveryCheck({
    required this.secret,
    required this.workspaces,
    this.maxTimestampSkew = const Duration(minutes: 5),
  });

  final SlackSigningSecret secret;

  final SlackWorkspaces workspaces;

  /// How far the signed timestamp may be from now, either way. Slack's
  /// docs say 5 minutes; it bounds how long a captured delivery can be
  /// replayed at all.
  final Duration maxTimestampSkew;

  @override
  RelayedEventSource get source => slackEventSource;

  @override
  HeaderCheck<SlackSignedHeaders> checkHeaders(
    DeliveryHeaders headers,
    DateTime now,
  ) {
    final timestamp = headers['x-slack-request-timestamp'];
    if (timestamp == null || timestamp.isEmpty) {
      return const HeadersRefused(
        RefusalStatus.unauthorized,
        'no x-slack-request-timestamp',
      );
    }
    final seconds = int.tryParse(timestamp);
    // Compared in whole seconds within a bounded range: a timestamp turned
    // into a DateTime, or multiplied out, can throw or overflow.
    if (seconds == null || seconds < 0 || seconds > _latestSeconds) {
      return const HeadersRefused(
        RefusalStatus.unauthorized,
        'x-slack-request-timestamp is not a time',
      );
    }
    final skew = now.millisecondsSinceEpoch ~/ 1000 - seconds;
    if (skew.abs() > maxTimestampSkew.inSeconds) {
      return HeadersRefused(
        RefusalStatus.unauthorized,
        'timestamp ${skew}s off',
      );
    }
    final presented = headers['x-slack-signature'];
    if (presented == null || !presented.startsWith('v0=')) {
      return const HeadersRefused(
        RefusalStatus.unauthorized,
        'no v0= x-slack-signature',
      );
    }
    final contentType = headers['content-type'] ?? '';
    if (_SlackBodyType.parse(contentType) == null) {
      return const HeadersRefused(
        RefusalStatus.badRequest,
        'not a content type Slack sends',
      );
    }
    return HeadersVouch(
      SlackSignedHeaders._(timestamp, presented.substring(3).toLowerCase()),
    );
  }

  @override
  BodyVerdict checkBody(SlackSignedHeaders vouched, Uint8List body) {
    final expected = secret.sign(vouched._timestamp, body);
    if (!constantTimeEquals(expected, vouched._signature)) {
      return const Refuse(RefusalStatus.unauthorized, 'signature mismatch');
    }
    // Authentic from here: the workspace, then record.
    final String workspace;
    switch (readSlackDelivery(body)) {
      case SlackHandshake(:final challenge):
        // No team on the handshake: the app may be installed nowhere yet.
        return Record(response: JsonObject.of({'challenge': challenge}));
      case SlackMalformed(:final reason):
        return Refuse(RefusalStatus.badRequest, reason);
      case SlackNotCovered(workspace: final w):
        workspace = w;
      case SlackDeliveredEvent(:final event):
        workspace = event.workspace;
    }
    if (!workspaces.contains(workspace)) {
      return const Refuse(RefusalStatus.forbidden, 'workspace not allowed');
    }
    return const Record();
  }

  /// Seconds since the epoch in the year 9999: later is no timestamp.
  static const _latestSeconds = 253402300799;
}

/// Constant-time comparison: a `==` on a hex digest leaks through timing how
/// many leading characters a guess got right. Lengths are compared first;
/// length is not the secret.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// The media types Slack posts a body as.
enum _SlackBodyType {
  json('application/json'),
  form('application/x-www-form-urlencoded');

  const _SlackBodyType(this.mime);

  final String mime;

  /// The type a `content-type` header names, parameters and case aside.
  static _SlackBodyType? parse(String contentType) {
    final mime = contentType.split(';').first.trim().toLowerCase();
    for (final t in values) {
      if (t.mime == mime) return t;
    }
    return null;
  }
}
