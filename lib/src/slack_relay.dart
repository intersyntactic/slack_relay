/// The HTTP front of a Slack app: the one endpoint Slack posts to.
///
/// It reads the body under a cap and a deadline, asks [slackGate], answers
/// at once, and only then hands the [SlackEvent] to [SlackRelay.onEvent],
/// so nothing the receiver does can make Slack wait past its 3 seconds and
/// retry. It owns the replay-dedupe cache the gate's `hasSeen` closure
/// needs, since the gate itself is pure and keeps no state — and nothing
/// of mirrors, node shapes, or kickoff records, which is domain logic that
/// lives downstream (in is_slack_module, for intersyntactic).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'record_delivery.dart';
import 'slack_event.dart';
import 'slack_gate.dart';

final class SlackRelay {
  SlackRelay({
    required this.spec,
    required this.record,
    this.recordTimeout = const Duration(seconds: 2),
    this.onEvent = _logEvent,
    DateTime Function()? now,
    this.bodyTimeout = const Duration(seconds: 10),
    this.maxBodyBytes = 1024 * 1024,
    this.seenFor = const Duration(minutes: 10),
    this.seenMax = 1000,
    this.log = _stderr,
  }) : _now = now ?? DateTime.now;

  /// Where Slack posts: Event Subscriptions and Slash Commands both point
  /// here. One route, one gate, two body shapes.
  static const path = '/webhook/slack';

  final SlackSourceSpec spec;

  /// Where each accepted delivery is recorded before Slack is answered:
  /// `LogbookWriter(socket).write` for the writer at `LOGBOOK_SOCKET`. Only
  /// once the logbook holds it is Slack answered 200; otherwise 503, and
  /// Slack sends it again. Null records nothing, which is only right for a
  /// relay that feeds no logbook.
  final WritesLogbookEntry? record;

  /// How long to wait for [record]. Slack gives up on a request after 3s.
  final Duration recordTimeout;

  /// What becomes of an arrival once Slack has its ACK. Defaults to a log
  /// line, so the relay runs end to end before a receiver is wired in.
  final Future<void> Function(SlackEvent event) onEvent;

  final Duration bodyTimeout;
  final int maxBodyBytes;

  /// How long a signature digest is remembered as seen. Slack's signing
  /// window is 5 minutes; ten covers its retries with room to spare.
  final Duration seenFor;

  /// A ceiling on the seen set, so a flood cannot grow it without bound.
  final int seenMax;

  final void Function(String line) log;

  final DateTime Function() _now;

  /// Seen digest to first sight, oldest first.
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  Future<void> handle(HttpRequest req) async {
    try {
      switch ((req.uri.path, req.method)) {
        case (path, 'POST'):
          await _webhook(req);
        case (path, _):
          await _end(req, HttpStatus.methodNotAllowed);
        default:
          await _end(req, HttpStatus.notFound);
      }
    } on Exception catch (e) {
      log('slack relay: $e');
      try {
        await _end(req, HttpStatus.internalServerError);
      } on Exception {
        // The response was already under way; there is no one left to tell.
      }
    }
  }

  Future<void> _webhook(HttpRequest req) async {
    if (req.contentLength > maxBodyBytes) {
      return _end(req, HttpStatus.requestEntityTooLarge);
    }
    final body = <int>[];
    var tooLarge = false;
    try {
      // One deadline for the whole body, not a gap between chunks: a sender
      // trickling a byte at a time must not hold the connection open.
      await () async {
        await for (final chunk in req) {
          if (body.length + chunk.length > maxBodyBytes) {
            tooLarge = true;
            return;
          }
          body.addAll(chunk);
        }
      }().timeout(bodyTimeout);
    } on TimeoutException {
      log('slack relay: body too slow');
      return _end(req, HttpStatus.requestTimeout);
    }
    if (tooLarge) return _end(req, HttpStatus.requestEntityTooLarge);

    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name] = values.first);
    final contentType = req.headers.contentType?.toString() ?? '';
    final now = _now();
    // No await from here to _markSeen: two copies of one delivery arriving
    // together cannot both get past hasSeen.
    final d = slackGate(
      spec: spec,
      headers: headers,
      body: body,
      contentType: contentType,
      now: now,
      hasSeen: _hasSeen,
      maxBodyBytes: maxBodyBytes,
    );
    if (d.digest case final digest?) _markSeen(digest, now);
    // The reason, never the content: the log is not a copy of anyone's words.
    log('slack relay: ${d.outcome.name}: ${d.reason}');

    switch (d.outcome) {
      case SlackGateOutcome.urlVerification:
        // Slack expects the bare challenge in the body with 200. No
        // signature on the response.
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.text;
        req.response.write(d.challenge ?? '');
        await req.response.close();
      case SlackGateOutcome.trigger:
        if (record case final write?) {
          final (recorded, why) = await recordDelivery(
            write,
            bytes: Uint8List.fromList(body),
            at: now.toUtc(),
            timeout: recordTimeout,
          );
          log('slack relay: logbook: $why');
          if (!recorded) {
            // Forget the digest, so a resend of these exact bytes is not
            // taken for a replay of one that was never recorded.
            if (d.digest case final digest?) _seen.remove(digest);
            return _end(req, HttpStatus.serviceUnavailable);
          }
        }
        // ACK, then run the handler in the background. Slack times out
        // after 3s and retries up to 3x; the handler often needs longer
        // than that.
        await _end(req, HttpStatus.ok);
        unawaited(_dispatch(d.event!));
      case SlackGateOutcome.ignore:
        await _end(req, HttpStatus.ok);
      case SlackGateOutcome.reject:
        // No reason in the response body: it would be a hint to whoever is
        // guessing. The log holds the reason.
        await _end(req, HttpStatus.unauthorized);
    }
  }

  Future<void> _dispatch(SlackEvent event) async {
    try {
      await onEvent(event);
    } on Exception catch (e) {
      log('slack relay: event handler: $e');
    }
  }

  bool _hasSeen(String digest) {
    final at = _seen[digest];
    if (at == null) return false;
    if (_now().difference(at) > seenFor) {
      _seen.remove(digest);
      return false;
    }
    return true;
  }

  void _markSeen(String digest, DateTime at) {
    // Move-to-front for LRU.
    _seen.remove(digest);
    _seen[digest] = at;
    while (_seen.length > seenMax) {
      _seen.remove(_seen.keys.first);
    }
    final cutoff = at.subtract(seenFor);
    while (_seen.isNotEmpty && _seen.values.first.isBefore(cutoff)) {
      _seen.remove(_seen.keys.first);
    }
  }

  static Future<void> _end(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }

  static void _stderr(String line) => stderr.writeln(line);

  /// The event kind only, never the content.
  static Future<void> _logEvent(SlackEvent event) async {
    stderr.writeln('slack relay: event ${event.runtimeType}');
  }
}
