import 'dart:convert';
import 'dart:typed_data';

import 'package:is_slack_relay/is_slack_relay.dart';
import 'package:test/test.dart';

Uint8List json(Map<String, Object?> payload) =>
    utf8.encode(jsonEncode(payload));

Uint8List eventCallback(
  Map<String, Object?> event, {
  Map<String, Object?> outer = const {},
}) => json({
  'type': 'event_callback',
  'team_id': 'T1',
  'authorizations': [
    {'user_id': 'UBOT', 'is_bot': true},
  ],
  ...outer,
  'event': event,
});

SlackMessage? message(Uint8List bytes) =>
    slackRecordedEvent(bytes) as SlackMessage?;

/// A signed-looking message whose event holds [open] and [close] 100,000
/// times over, deep enough to overflow a recursive copy.
String _nested(String open, String close) =>
    '{"type":"event_callback","team_id":"T1","event":{"type":"message",'
    '"channel":"C1","ts":"1.1","x":${open * 100000}1${close * 100000}}}';

void main() {
  group('typed fields', () {
    test('a CI bot message: bot_id, channel_type, subtype, delivered for', () {
      final m = message(
        eventCallback({
          'type': 'message',
          'subtype': 'bot_message',
          'bot_id': 'BCI',
          'channel': 'C1',
          'channel_type': 'channel',
          'text': 'deployed web 1.2.3 to staging',
          'ts': '1.1',
        }),
      )!;
      expect(m.botId, 'BCI');
      expect(m.user, isNull);
      expect(m.subtype, SlackMessageSubtype.botMessage);
      expect(m.channelType, SlackChannelType.channel);
      expect(m.deliveredForUser, 'UBOT');
      expect(m.mention, isFalse);
    });

    test('a person\'s plain message has no bot_id and no subtype', () {
      final m = message(
        eventCallback({
          'type': 'message',
          'channel': 'D1',
          'channel_type': 'im',
          'user': 'U1',
          'ts': '1.1',
        }),
      )!;
      expect(m.botId, isNull);
      expect(m.subtype, isNull);
      expect(m.channelType, SlackChannelType.im);
    });

    test('app_mention carries no channel_type', () {
      final m = message(
        eventCallback({
          'type': 'app_mention',
          'channel': 'C1',
          'user': 'U1',
          'ts': '1.1',
        }),
      )!;
      expect(m.mention, isTrue);
      expect(m.channelType, isNull);
    });

    test('a subtype not named here is unnamed, still in rawEvent', () {
      final m = message(
        eventCallback({
          'type': 'message',
          'subtype': 'something_new',
          'channel': 'C1',
          'ts': '1.1',
        }),
      )!;
      expect(m.subtype, SlackMessageSubtype.unnamed);
      expect(m.rawEvent['subtype'], 'something_new');
    });

    test('a channel_type not named here is null', () {
      final m = message(
        eventCallback({
          'type': 'message',
          'channel': 'C1',
          'channel_type': 'something_new',
          'ts': '1.1',
        }),
      )!;
      expect(m.channelType, isNull);
    });

    test('enterprise_id on an Enterprise Grid delivery', () {
      final m = message(
        eventCallback(
          {'type': 'message', 'channel': 'C1', 'user': 'U1', 'ts': '1.1'},
          outer: {'enterprise_id': 'E1'},
        ),
      )!;
      expect(m.enterprise, 'E1');
    });

    test('no enterprise, no authorizations: both null', () {
      final m = message(
        json({
          'type': 'event_callback',
          'team_id': 'T1',
          'event': {'type': 'message', 'channel': 'C1', 'ts': '1.1'},
        }),
      )!;
      expect(m.enterprise, isNull);
      expect(m.deliveredForUser, isNull);
    });

    test('a reaction carries delivered for and enterprise', () {
      final r = slackRecordedEvent(
        eventCallback(
          {
            'type': 'reaction_added',
            'user': 'U1',
            'reaction': 'white_check_mark',
            'event_ts': '2.2',
            'item': {'type': 'message', 'channel': 'C1', 'ts': '1.1'},
          },
          outer: {'enterprise_id': 'E1'},
        ),
      ) as SlackReactionAdded?;
      expect(r?.deliveredForUser, 'UBOT');
      expect(r?.enterprise, 'E1');
    });
  });

  group('body shapes, sniffed', () {
    test('a form body is a slash command, enterprise and all', () {
      final c = slackRecordedEvent(
        utf8.encode(
          'team_id=T1&enterprise_id=E1&channel_id=C1&user_id=U1'
          '&command=%2Fmodel&text=opus',
        ),
      ) as SlackCommand?;
      expect(c?.command, '/model');
      expect(c?.text, 'opus');
      expect(c?.enterprise, 'E1');
      expect(c?.deliveredForUser, isNull);
    });

    test('JSON with leading whitespace is still JSON', () {
      final bytes = Uint8List.fromList([
        ...utf8.encode('  \n'),
        ...eventCallback({'type': 'message', 'channel': 'C1', 'ts': '1.1'}),
      ]);
      expect(message(bytes), isNotNull);
    });
  });

  group('form bodies', () {
    SlackCommand? command(String text) => slackRecordedEvent(
      utf8.encode('team_id=T1&channel_id=C1&user_id=U1&command=%2Fmodel&$text'),
    ) as SlackCommand?;

    // Uri.splitQueryString threw an ArgumentError, an Error, on each of these.
    for (final raw in ['café', '👋 hi', 'ẞ']) {
      test('raw non-ASCII "$raw" is read, not thrown', () {
        expect(command('text=$raw')?.text, raw);
      });
    }

    test('%XX is a byte, and the bytes are UTF-8', () {
      expect(command('text=caf%C3%A9')?.text, 'café');
      expect(command('text=%F0%9F%91%8B')?.text, '👋');
    });

    test('+ is a space, and %2B a plus', () {
      expect(command('text=a+b%2Bc')?.text, 'a b+c');
    });

    test('= after the first stays in the value', () {
      expect(command('text=a=b')?.text, 'a=b');
    });

    test('a later field of one name wins, as splitQueryString had it', () {
      expect(command('text=first&text=second')?.text, 'second');
    });

    test('empty pairs and a field with no = are taken', () {
      expect(command('text=x&&flag')?.text, 'x');
    });
  });

  group('never throws', () {
    for (final (name, bytes) in [
      ('a % with one hex digit', utf8.encode('team_id=T1&text=%4')),
      ('a % in a name', utf8.encode('%zz=1&team_id=T1')),
      ('bad percent-encoding', utf8.encode('team_id=T1&text=%zz')),
      ('truncated percent', utf8.encode('team_id=%')),
      ('percent-decoded bytes not utf-8', utf8.encode('team_id=%E2%82')),
      ('not utf-8', Uint8List.fromList([0xff, 0xfe])),
      ('JSON that does not parse', utf8.encode('{"type":')),
      ('JSON not an object', utf8.encode('[1]')),
      ('JSON lists nested 100,000 deep', utf8.encode(_nested('[', ']'))),
      ('JSON objects nested 100,000 deep', utf8.encode(_nested('{"a":', '}'))),
    ]) {
      test('$name is malformed', () {
        expect(
          readSlackDelivery(Uint8List.fromList(bytes)),
          isA<SlackMalformed>(),
        );
        expect(slackRecordedEvent(Uint8List.fromList(bytes)), isNull);
      });
    }
  });

  group('JSON that jsonDecode would quietly misread', () {
    // Each is a valid message but for the one part named.
    const before = '{"type":"event_callback","team_id":"T1",';
    const event = '"event":{"type":"message","channel":"C1","ts":"1.1"';
    test('the same message without them is read', () {
      expect(
        readSlackDelivery(utf8.encode('$before$event}}')),
        isA<SlackDeliveredEvent>(),
      );
    });
    for (final (name, text) in [
      ('an outer key named twice', '$before"team_id":"T2",$event}}'),
      ('an event key named twice', '$before$event,"channel":"C2"}}'),
      (
        'a key named twice, once escaped',
        '$before"team\\u005fid":"T2",$event}}',
      ),
      ('an integer past 2^53 - 1', '$before"n":9007199254740993,$event}}'),
    ]) {
      test('$name is malformed', () {
        expect(readSlackDelivery(utf8.encode(text)), isA<SlackMalformed>());
      });
    }
  });

  group('anchoring and the other cases', () {
    test('a reply in a thread anchors on thread_ts, keeping its own ts', () {
      final m = message(
        eventCallback({
          'type': 'app_mention',
          'channel': 'C1',
          'user': 'U1',
          'ts': '2.2',
          'thread_ts': '1.1',
        }),
      )!;
      expect(m.threadTs, '1.1');
      expect(m.rawThreadTs, '1.1');
      expect(m.eventTs, '2.2');
    });

    test('a top-level message anchors on its own ts', () {
      final m = message(
        eventCallback({
          'type': 'message',
          'channel': 'C1',
          'user': 'U1',
          'ts': '2.2',
        }),
      )!;
      expect(m.threadTs, '2.2');
      expect(m.rawThreadTs, isNull);
    });

    test('a message with neither ts nor thread_ts is malformed', () {
      expect(
        readSlackDelivery(
          eventCallback({'type': 'message', 'channel': 'C1', 'user': 'U1'}),
        ),
        isA<SlackMalformed>(),
      );
    });

    test('reaction_removed is a SlackReactionRemoved', () {
      final r = slackRecordedEvent(
        eventCallback({
          'type': 'reaction_removed',
          'user': 'U1',
          'reaction': 'x',
          'event_ts': '3.3',
          'item': {'type': 'message', 'channel': 'C1', 'ts': '1.1'},
        }),
      ) as SlackReactionRemoved?;
      expect(r?.reaction, 'x');
      expect(r?.targetTs, '1.1');
      expect(r?.channel, 'C1');
    });

    test('url_verification with no challenge is malformed', () {
      expect(
        readSlackDelivery(json({'type': 'url_verification'})),
        isA<SlackMalformed>(),
      );
      expect(
        readSlackDelivery(json({'type': 'url_verification', 'challenge': ''})),
        isA<SlackMalformed>(),
      );
    });
  });

  group('not events', () {
    test('url_verification is a handshake, and no event', () {
      final bytes = json({'type': 'url_verification', 'challenge': 'xyz'});
      expect(
        readSlackDelivery(bytes),
        isA<SlackHandshake>().having((h) => h.challenge, 'challenge', 'xyz'),
      );
      expect(slackRecordedEvent(bytes), isNull);
    });

    test('an event type no SlackEvent covers is not covered', () {
      expect(
        readSlackDelivery(
          eventCallback({'type': 'channel_created', 'channel': {}}),
        ),
        isA<SlackNotCovered>(),
      );
    });

    test('a reaction on a file is not covered', () {
      expect(
        readSlackDelivery(
          eventCallback({
            'type': 'reaction_added',
            'user': 'U1',
            'reaction': 'x',
            'event_ts': '2.2',
            'item': {'type': 'file', 'file': 'F1'},
          }),
        ),
        isA<SlackNotCovered>(),
      );
    });
  });
}
