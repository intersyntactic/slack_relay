import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_slack_relay/is_slack_relay.dart';
import 'package:test/test.dart';

const secret = 'correct horse battery staple';
const team = 'T123';

/// Opens an HttpServer on an ephemeral port, drives [relay] from it, and
/// tears down automatically at the end of the test's zone.
Future<Uri> _serve(SlackRelay relay) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  // Run the request loop in the background; failures surface through the
  // relay's own log, not the test.
  unawaited(() async {
    await for (final req in server) {
      unawaited(relay.handle(req));
    }
  }());
  return Uri.parse('http://127.0.0.1:${server.port}');
}

Future<HttpClientResponse> _post(
  Uri base,
  String path, {
  required String contentType,
  required List<int> body,
  required Map<String, String> headers,
}) async {
  final client = HttpClient();
  addTearDown(client.close);
  final req = await client.postUrl(base.replace(path: path));
  req.headers.contentType = ContentType.parse(contentType);
  headers.forEach(req.headers.set);
  req.add(body);
  return req.close();
}

String _sig(String ts, List<int> body) =>
    'v0=${slackSignBody(secret, ts, body)}';

String _ts(DateTime at) => (at.millisecondsSinceEpoch ~/ 1000).toString();

void main() {
  group('SlackRelay HTTP roundtrip', () {
    test('url_verification echoes the challenge', () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final relay = SlackRelay(
        spec: const SlackSourceSpec(signingSecret: secret),
        now: () => at,
      );
      final base = await _serve(relay);
      final body = utf8.encode(jsonEncode({
        'type': 'url_verification',
        'challenge': 'xyz',
      }));
      final ts = _ts(at);
      final res = await _post(
        base,
        '/webhook/slack',
        contentType: 'application/json',
        body: body,
        headers: {
          'X-Slack-Request-Timestamp': ts,
          'X-Slack-Signature': _sig(ts, body),
        },
      );
      expect(res.statusCode, 200);
      expect(await res.transform(utf8.decoder).join(), 'xyz');
    });

    test('a correctly signed app_mention is 200 and calls onEvent',
        () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final events = <SlackEvent>[];
      final dispatched = Completer<void>();
      final relay = SlackRelay(
        spec: SlackSourceSpec(
          signingSecret: secret,
          teamIdAllowlist: const {team},
        ),
        now: () => at,
        onEvent: (event) async {
          events.add(event);
          if (!dispatched.isCompleted) dispatched.complete();
        },
      );
      final base = await _serve(relay);
      final body = utf8.encode(jsonEncode({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'app_mention',
          'channel': 'C1',
          'user': 'U1',
          'text': 'hi bot',
          'ts': '1700000000.000100',
        },
      }));
      final ts = _ts(at);
      final res = await _post(
        base,
        '/webhook/slack',
        contentType: 'application/json',
        body: body,
        headers: {
          'X-Slack-Request-Timestamp': ts,
          'X-Slack-Signature': _sig(ts, body),
        },
      );
      expect(res.statusCode, 200);
      await dispatched.future.timeout(const Duration(seconds: 2));
      expect(events, hasLength(1));
      final event = events.single as SlackMessage;
      expect(event.mention, isTrue);
      expect(event.channel, 'C1');
    });

    test('a wrong signature answers 401 and does not call onEvent',
        () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final events = <SlackEvent>[];
      final relay = SlackRelay(
        spec: const SlackSourceSpec(signingSecret: secret),
        now: () => at,
        onEvent: (event) async => events.add(event),
      );
      final base = await _serve(relay);
      final body = utf8.encode(jsonEncode({'type': 'event_callback'}));
      final res = await _post(
        base,
        '/webhook/slack',
        contentType: 'application/json',
        body: body,
        headers: {
          'X-Slack-Request-Timestamp': _ts(at),
          'X-Slack-Signature': 'v0=0000',
        },
      );
      expect(res.statusCode, 401);
      // Give the (should-not-fire) handler a tick to run if the ACK path is
      // broken; if it hasn't fired by now, the gate held.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events, isEmpty);
    });

    test(
        'a replay of a correctly signed event is accepted but not re-dispatched',
        () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final events = <SlackEvent>[];
      final relay = SlackRelay(
        spec: SlackSourceSpec(
          signingSecret: secret,
          teamIdAllowlist: const {team},
        ),
        now: () => at,
        onEvent: (event) async => events.add(event),
      );
      final base = await _serve(relay);
      final body = utf8.encode(jsonEncode({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'app_mention',
          'channel': 'C1',
          'user': 'U1',
          'ts': '1700000000.000100',
        },
      }));
      final ts = _ts(at);
      final headers = {
        'X-Slack-Request-Timestamp': ts,
        'X-Slack-Signature': _sig(ts, body),
      };
      final first = await _post(base, '/webhook/slack',
          contentType: 'application/json', body: body, headers: headers);
      expect(first.statusCode, 200);
      // Give the first dispatch time to land before replaying.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final second = await _post(base, '/webhook/slack',
          contentType: 'application/json', body: body, headers: headers);
      expect(second.statusCode, 200);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events, hasLength(1),
          reason: 'replay should ACK 200 but not re-run the pipeline');
    });

    test('a path other than /webhook/slack is 404', () async {
      final relay = SlackRelay(
        spec: const SlackSourceSpec(signingSecret: secret),
      );
      final base = await _serve(relay);
      final res = await _post(
        base,
        '/elsewhere',
        contentType: 'application/json',
        body: const [],
        headers: const {},
      );
      expect(res.statusCode, 404);
    });
  });
}
