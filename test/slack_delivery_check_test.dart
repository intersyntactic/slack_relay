import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show RelayedEvent;
import 'package:is_logbook_client/is_logbook_client.dart' show Kind, ObjectId;
import 'package:is_relay/is_relay.dart';
import 'package:is_slack_relay/is_slack_relay.dart';
import 'package:test/test.dart';

final secret = SlackSigningSecret.parse('correct horse battery staple')!;
const team = 'T123';
final now = DateTime.utc(2026, 11, 24, 12);
final ts = '${now.millisecondsSinceEpoch ~/ 1000}';

SlackDeliveryCheck check({Set<String> workspaces = const {team}}) =>
    SlackDeliveryCheck(
      secret: secret,
      workspaces: SlackWorkspaces.of(workspaces)!,
    );

Uint8List json(Map<String, Object?> payload) =>
    utf8.encode(jsonEncode(payload));

Uint8List mention({String workspace = team}) => json({
  'type': 'event_callback',
  'team_id': workspace,
  'event': {
    'type': 'app_mention',
    'channel': 'C1',
    'user': 'U1',
    'text': 'deployed, please test',
    'ts': '1700000000.000100',
  },
});

Map<String, String> signed(
  List<int> body, {
  String? timestamp,
  String contentType = 'application/json',
}) {
  final t = timestamp ?? ts;
  return {
    'X-Slack-Request-Timestamp': t,
    'X-Slack-Signature': 'v0=${secret.sign(t, body)}',
    'Content-Type': contentType,
  };
}

HeaderCheck<SlackSignedHeaders> headers(Map<String, String> h) =>
    check().checkHeaders(DeliveryHeaders(h), now);

/// The verdict on [body] signed as Slack signs it, through both checks.
BodyVerdict verdict(
  Uint8List body, {
  SlackDeliveryCheck? using,
  String contentType = 'application/json',
}) {
  final c = using ?? check();
  return switch (c.checkHeaders(
    DeliveryHeaders(signed(body, contentType: contentType)),
    now,
  )) {
    HeadersVouch(:final vouched) => c.checkBody(vouched, body),
    HeadersRefused(:final reason) => fail('headers refused: $reason'),
  };
}

Matcher refusedHeaders(RefusalStatus status) =>
    isA<HeadersRefused<Object>>().having((r) => r.status, 'status', status);

Matcher refused(RefusalStatus status) =>
    isA<Refuse>().having((r) => r.status, 'status', status);

void main() {
  test('sign matches an HMAC-SHA256 computed elsewhere', () {
    // From: printf 'v0:1531420618:<body>' | openssl dgst -sha256 -hmac <secret>
    expect(
      SlackSigningSecret.parse('test-signing-secret')!
          .sign('1531420618', utf8.encode('team_id=T1&text=caf%C3%A9 {"a":1}')),
      '0a784c6febdd31d7c51d49461cbd68974b844d307f4cd3a92f788afed5a2b5cf',
    );
  });

  test('an empty signing secret is no secret', () {
    expect(SlackSigningSecret.parse(''), isNull);
  });

  group('headers', () {
    final body = mention();

    test('a signed delivery is vouched for', () {
      expect(headers(signed(body)), isA<HeadersVouch<SlackSignedHeaders>>());
    });

    for (final (name, h) in [
      ('no timestamp', {...signed(body)}..remove('X-Slack-Request-Timestamp')),
      ('a timestamp that is not a number', signed(body, timestamp: 'soon')),
      ('a negative timestamp', signed(body, timestamp: '-1')),
      // Once a RangeError out of DateTime: an Error ends an is_relay server.
      ('a timestamp past year 9999', signed(body, timestamp: '99999999999999')),
      (
        'a timestamp at int64 max',
        signed(body, timestamp: '9223372036854775807'),
      ),
      (
        'a timestamp 6 minutes old',
        signed(body, timestamp: '${int.parse(ts) - 360}'),
      ),
      (
        'a timestamp 6 minutes ahead',
        signed(body, timestamp: '${int.parse(ts) + 360}'),
      ),
      ('no signature', {...signed(body)}..remove('X-Slack-Signature')),
      (
        'a signature without v0=',
        {...signed(body), 'X-Slack-Signature': 'v1=abc'},
      ),
    ]) {
      test('$name is refused 401 before the body', () {
        expect(headers(h), refusedHeaders(RefusalStatus.unauthorized));
      });
    }

    test('a timestamp 4 minutes old is in the window', () {
      expect(
        headers(signed(body, timestamp: '${int.parse(ts) - 240}')),
        isA<HeadersVouch<SlackSignedHeaders>>(),
      );
    });

    test('the content type is not what decides: a rewritten one is taken', () {
      // Outside the signature, so a proxy may change it; the signed bytes say
      // what the body is.
      final form = utf8.encode(
        'team_id=$team&channel_id=C1&user_id=U1&command=%2Fmodel&text=x',
      );
      expect(verdict(form, contentType: 'text/plain'), isA<Record>());
    });
  });

  group('body', () {
    test('an event from an allowed workspace is recorded', () {
      expect(verdict(mention()), isA<Record>());
    });

    test('a signature over other bytes is refused 401', () {
      final c = check();
      final body = mention();
      final vouched = (c.checkHeaders(
        DeliveryHeaders(signed(body)),
        now,
      ) as HeadersVouch<SlackSignedHeaders>).vouched;
      expect(
        c.checkBody(vouched, mention(workspace: 'T999')),
        refused(RefusalStatus.unauthorized),
      );
    });

    test('a signature in upper-case hex is the same signature', () {
      final c = check();
      final body = mention();
      final h = signed(body);
      h['X-Slack-Signature'] = h['X-Slack-Signature']!
          .toUpperCase()
          .replaceFirst('V0=', 'v0=');
      final vouched = (c.checkHeaders(
        DeliveryHeaders(h),
        now,
      ) as HeadersVouch<SlackSignedHeaders>).vouched;
      expect(c.checkBody(vouched, body), isA<Record>());
    });

    test('a workspace not allowed is refused 403', () {
      expect(
        verdict(mention(workspace: 'T999')),
        refused(RefusalStatus.forbidden),
      );
    });

    test('there is no empty allowlist to take any workspace', () {
      expect(SlackWorkspaces.of(const []), isNull);
      expect(SlackWorkspaces.of(const ['', '  ']), isNull);
      expect(SlackWorkspaces.parse(''), isNull);
      expect(SlackWorkspaces.parse(' , ,'), isNull);
    });

    test('a list of workspaces parses, blanks and spaces aside', () {
      final w = SlackWorkspaces.parse(' T1, ,T2 ')!;
      expect(w.contains('T1'), isTrue);
      expect(w.contains('T2'), isTrue);
      expect(w.contains(''), isFalse);
    });

    test('changing the list after the check is built changes nothing', () {
      final ids = {team};
      final c = check(workspaces: ids);
      ids
        ..clear()
        ..add('T999');
      expect(verdict(mention(), using: c), isA<Record>());
      expect(
        verdict(mention(workspace: 'T999'), using: c),
        refused(RefusalStatus.forbidden),
      );
    });

    test('an event type no SlackEvent covers is recorded all the same', () {
      expect(
        verdict(
          json({
            'type': 'event_callback',
            'team_id': team,
            'event': {'type': 'channel_created'},
          }),
        ),
        isA<Record>(),
      );
    });

    test('but not from a workspace not allowed', () {
      expect(
        verdict(
          json({
            'type': 'event_callback',
            'team_id': 'T999',
            'event': {'type': 'channel_created'},
          }),
        ),
        refused(RefusalStatus.forbidden),
      );
    });

    test('a slash command is recorded', () {
      expect(
        verdict(
          utf8.encode(
            'team_id=$team&channel_id=C1&user_id=U1&command=%2Fmodel&text=x',
          ),
          contentType: 'application/x-www-form-urlencoded',
        ),
        isA<Record>(),
      );
    });

    test('url_verification is recorded, answered with its challenge', () {
      final v = verdict(json({'type': 'url_verification', 'challenge': 'xyz'}));
      expect(
        v,
        isA<Record>().having(
          (r) => r.response,
          'response',
          JsonObject.of({'challenge': 'xyz'}),
        ),
      );
    });

    test('signed bytes that are no delivery are refused 400', () {
      expect(
        verdict(utf8.encode('{"type":')),
        refused(RefusalStatus.badRequest),
      );
      expect(
        verdict(
          utf8.encode('team_id=%zz'),
          contentType: 'application/x-www-form-urlencoded',
        ),
        refused(RefusalStatus.badRequest),
      );
    });
  });

  group('through a RelayServer', () {
    late _FakeLogbook logbook;
    late Uri url;

    setUp(() async {
      logbook = await _FakeLogbook.start();
      final relay = RelayServer(
        check: check(),
        logbook: logbook.socket,
        path: slackRelayPath,
        budget: slackRelayBudget,
        rate: WriteRateBound(perMinute: 600, burst: 100),
        log: (_) {},
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      addTearDown(logbook.stop);
      relay.serve(server).ignore();
      url = Uri.parse('http://127.0.0.1:${server.port}${slackRelayPath.value}');
    });

    Future<(int, String)> post(Uint8List body, Map<String, String> h) async {
      final client = HttpClient();
      addTearDown(client.close);
      final req = await client.postUrl(url);
      h.forEach(req.headers.set);
      req.add(body);
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    test('a mention is recorded as slack-event, and the translator\'s '
        'parse reads it back', () async {
      final body = mention();
      final (status, _) = await post(body, signed(body, timestamp: _nowTs()));
      expect(status, 200);
      final (kind, entry) = _FakeLogbook.parse(logbook.requests.single);
      expect(kind.name, 'slack-event');
      final recorded = RelayedEvent.read(ObjectId.of(entry), kind, entry)!;
      expect(recorded.bytes, body);
      final event = slackRecordedEvent(recorded.bytes) as SlackMessage?;
      expect(event?.text, 'deployed, please test');
      expect(event?.mention, isTrue);
    });

    test('url_verification answers its challenge once recorded', () async {
      final body = json({'type': 'url_verification', 'challenge': 'xyz'});
      final (status, response) = await post(
        body,
        signed(body, timestamp: _nowTs()),
      );
      expect(status, 200);
      expect(jsonDecode(response), {'challenge': 'xyz'});
      expect(logbook.requests, hasLength(1));
    });

    test('a forged signature is 401 and nothing is recorded', () async {
      final body = mention();
      final h = signed(body, timestamp: _nowTs())
        ..['X-Slack-Signature'] = 'v0=${'0' * 64}';
      final (status, _) = await post(body, h);
      expect(status, 401);
      expect(logbook.requests, isEmpty);
    });
  });
}

/// The RelayServer checks against the real clock.
String _nowTs() => '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';

/// A logbook write socket that answers `ok <id>` to each request.
final class _FakeLogbook {
  _FakeLogbook._(this._server, this.socket, this._dir);

  static Future<_FakeLogbook> start() async {
    final dir = await Directory.systemTemp.createTemp('slack_relay');
    final path = '${dir.path}/w.sock';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final logbook = _FakeLogbook._(server, LogbookSocket.parse(path)!, dir);
    server.listen(logbook._serve);
    return logbook;
  }

  final ServerSocket _server;
  final Directory _dir;
  final LogbookSocket socket;
  final requests = <Uint8List>[];

  Future<void> _serve(Socket s) async {
    final b = BytesBuilder();
    await s.forEach(b.add);
    final request = b.takeBytes();
    requests.add(request);
    s.write('ok ${ObjectId.of(request).hex}\n');
    await s.close();
  }

  static (Kind, Uint8List) parse(Uint8List request) {
    final first = request.indexOf(0x0a);
    final second = request.indexOf(0x0a, first + 1);
    return (
      Kind.parse(utf8.decode(request.sublist(0, first)))!,
      Uint8List.sublistView(request, second + 1),
    );
  }

  Future<void> stop() async {
    await _server.close();
    await _dir.delete(recursive: true);
  }
}
