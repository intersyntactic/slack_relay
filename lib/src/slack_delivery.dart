/// Reading one Slack delivery's bytes, once its signature has been checked
/// or once it has come back out of the logbook. Pure: no signature, no
/// clock, no wake set, and no knowledge of how the bytes were stored.
///
/// The bytes carry no content type, so the shape is sniffed: a body whose
/// first non-space byte is `{` is JSON (Events API), anything else is a
/// form (slash commands). Slack sends only those two.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';

import 'slack_event.dart';

/// What one delivery's bytes say.
sealed class SlackDelivery {
  const SlackDelivery();
}

/// An event or command a [SlackEvent] covers.
final class SlackDeliveredEvent extends SlackDelivery {
  const SlackDeliveredEvent(this.event);
  final SlackEvent event;
}

/// The one-time `url_verification` handshake: answer with [challenge].
final class SlackHandshake extends SlackDelivery {
  const SlackHandshake(this.challenge);
  final String challenge;
}

/// Well-formed, but not something a [SlackEvent] covers: another payload
/// type, another event type, a reaction on a file. [reason] is for a log.
final class SlackNotCovered extends SlackDelivery {
  const SlackNotCovered(this.workspace, this.reason);

  /// The workspace's team id: every delivery but the handshake names one.
  final String workspace;

  final String reason;
}

/// Not a delivery Slack sends: bad JSON, no team, a field missing. [reason]
/// is for a log, never a response body.
final class SlackMalformed extends SlackDelivery {
  const SlackMalformed(this.reason);
  final String reason;
}

/// Reads [bytes] as Slack sent them. Never throws.
SlackDelivery readSlackDelivery(Uint8List bytes) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return const SlackMalformed('body is not utf-8');
  }
  final Map<String, Object?> payload;
  if (text.trimLeft().startsWith('{')) {
    try {
      payload = JsonObject.decode(text).asUncheckedMap();
    } on FormatException {
      return const SlackMalformed(
        'json body is not an object, does not parse, names a key twice, '
        'has an integer past 2^53 - 1, or nests past 512 levels',
      );
    }
  } else {
    final fields = _formFields(bytes);
    if (fields == null) {
      return const SlackMalformed('form body is not form-encoded utf-8');
    }
    payload = fields;
  }

  final type = _PayloadType.of(payload);
  // No team_id on the handshake: the app may not be installed anywhere yet.
  if (type == _PayloadType.urlVerification) {
    return switch (payload) {
      {'challenge': final String challenge} when challenge.isNotEmpty =>
        SlackHandshake(challenge),
      _ => const SlackMalformed('url_verification missing challenge'),
    };
  }

  final team = _teamIdOf(payload);
  if (team == null) return const SlackMalformed('no team_id in payload');
  final enterprise = _nonEmpty(payload, 'enterprise_id');

  return switch (type) {
    _PayloadType.eventCallback => _event(payload, team, enterprise),
    _PayloadType.command => _command(payload, team, enterprise),
    _PayloadType.urlVerification ||
    null => SlackNotCovered(team, 'payload type "${payload['type']}"'),
  };
}

/// The event or command in [bytes], or null for anything else. For a
/// consumer reading recorded deliveries back: the same parse the gate runs.
SlackEvent? slackRecordedEvent(Uint8List bytes) =>
    switch (readSlackDelivery(bytes)) {
      SlackDeliveredEvent(:final event) => event,
      SlackHandshake() || SlackNotCovered() || SlackMalformed() => null,
    };

/// The payload shapes a [SlackEvent] can be read from.
enum _PayloadType {
  urlVerification,
  eventCallback,

  /// A slash command's form, which has no `type`, only a `command`.
  command;

  static _PayloadType? of(Map<String, Object?> payload) => switch (payload) {
    {'type': 'url_verification'} => urlVerification,
    {'type': 'event_callback'} => eventCallback,
    {'command': String _} => command,
    _ => null,
  };
}

/// A form body's fields: `&`-separated `name=value`, `+` for a space,
/// `%XX` for a byte, the bytes UTF-8; a later field of one name wins. Null for
/// a body that isn't one. Read by hand rather than with Uri.splitQueryString,
/// which throws an Error (not an Exception) on a bad `%` or a raw character
/// above 127, and an Error ends a relay.
Map<String, String>? _formFields(Uint8List body) {
  final fields = <String, String>{};
  var start = 0;
  for (var i = 0; i <= body.length; i++) {
    if (i < body.length && body[i] != 0x26) continue; // '&'
    if (i > start) {
      final pair = Uint8List.sublistView(body, start, i);
      final eq = pair.indexOf(0x3d); // '='
      final name = _formDecode(
        eq < 0 ? pair : Uint8List.sublistView(pair, 0, eq),
      );
      final value = eq < 0
          ? ''
          : _formDecode(Uint8List.sublistView(pair, eq + 1));
      if (name == null || value == null) return null;
      fields[name] = value;
    }
    start = i + 1;
  }
  return fields;
}

/// One form component, decoded; null for a bad `%` or bytes not UTF-8.
String? _formDecode(Uint8List encoded) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < encoded.length; i++) {
    final b = encoded[i];
    if (b == 0x2b) {
      out.addByte(0x20); // '+' is a space
    } else if (b == 0x25) {
      if (i + 2 >= encoded.length) return null;
      final hi = _hexDigit(encoded[i + 1]);
      final lo = _hexDigit(encoded[i + 2]);
      if (hi == null || lo == null) return null;
      out.addByte(hi << 4 | lo);
      i += 2;
    } else {
      out.addByte(b);
    }
  }
  try {
    return utf8.decode(out.takeBytes());
  } on FormatException {
    return null;
  }
}

int? _hexDigit(int c) => switch (c) {
  >= 0x30 && <= 0x39 => c - 0x30,
  >= 0x41 && <= 0x46 => c - 0x37,
  >= 0x61 && <= 0x66 => c - 0x57,
  _ => null,
};

/// [map]'s [key] when it is a non-empty string, otherwise null.
String? _nonEmpty(Map<Object?, Object?> map, String key) => switch (map[key]) {
  final String value when value.isNotEmpty => value,
  _ => null,
};

String? _teamIdOf(Map<String, Object?> payload) =>
    _nonEmpty(payload, 'team_id') ??
    switch (payload) {
      {'team': final Map<Object?, Object?> team} => _nonEmpty(team, 'id'),
      _ => null,
    };

/// The first authorization's `user_id`. Slack sends one authorization per
/// delivery; the full list is fetched from `apps.event.authorizations.list`.
String? _deliveredForUserOf(Map<String, Object?> payload) => switch (payload) {
  {'authorizations': [final Map<Object?, Object?> first, ...]} => _nonEmpty(
    first,
    'user_id',
  ),
  _ => null,
};

SlackDelivery _event(
  Map<String, Object?> payload,
  String team,
  String? enterprise,
) {
  final event = JsonObject.parse(payload['event'])?.asUncheckedMap();
  if (event == null) {
    return const SlackMalformed('event_callback has no event object');
  }
  final type = switch (event) {
    {'type': final String wire} => SlackEventType.parse(wire),
    _ => null,
  };
  final deliveredForUser = _deliveredForUserOf(payload);
  switch (type) {
    case null:
      return SlackNotCovered(team, 'event type "${event['type']}"');
    case SlackEventType.reactionAdded || SlackEventType.reactionRemoved:
      return _reaction(event, type, team, enterprise, deliveredForUser);
    case SlackEventType.appMention || SlackEventType.message:
      break;
  }
  final channel = _nonEmpty(event, 'channel');
  if (channel == null) return const SlackMalformed('event missing channel');
  final ts = _nonEmpty(event, 'ts');
  final threadTs = _nonEmpty(event, 'thread_ts');
  // The conversation anchor: thread_ts when the event is already in a
  // thread, the message's own ts when it is top-level and will seed one.
  final anchor = threadTs ?? ts;
  if (anchor == null) {
    return const SlackMalformed('event missing ts and thread_ts');
  }
  return SlackDeliveredEvent(
    SlackMessage(
      workspace: team,
      channel: channel,
      threadTs: anchor,
      enterprise: enterprise,
      deliveredForUser: deliveredForUser,
      mention: type == SlackEventType.appMention,
      user: switch (event) {
        {'user': final String user} => user,
        _ => null,
      },
      botId: _nonEmpty(event, 'bot_id'),
      channelType: switch (event) {
        {'channel_type': final String wire} => SlackChannelType.parse(wire),
        _ => null,
      },
      text: switch (event) {
        {'text': final String text} => text,
        _ => null,
      },
      eventTs: ts,
      subtype: switch (event) {
        {'subtype': final String wire} => SlackMessageSubtype.parse(wire),
        _ => null,
      },
      rawThreadTs: threadTs,
      rawEvent: event,
    ),
  );
}

/// Reaction events put the target under `event.item` and carry no
/// `thread_ts`: placing one needs a lookup by `(channel, targetTs)`, which
/// is the consumer's.
SlackDelivery _reaction(
  Map<String, Object?> event,
  SlackEventType type,
  String team,
  String? enterprise,
  String? deliveredForUser,
) {
  final Map<Object?, Object?> item;
  switch (event) {
    case {'item': final Map<Object?, Object?> i}:
      item = i;
    default:
      return const SlackMalformed('reaction event missing item');
  }
  // Only message reactions are covered; `file`/`file_comment` items are not.
  final onMessage = switch (item) {
    {'type': 'message'} => true,
    _ => false,
  };
  if (!onMessage) {
    return SlackNotCovered(
      team,
      'reaction on non-message item "${item['type']}"',
    );
  }
  final channel = _nonEmpty(item, 'channel');
  if (channel == null) {
    return const SlackMalformed('reaction item missing channel or ts');
  }
  if (event case {
    'user': final String user,
    'reaction': final String reaction,
    'event_ts': final String eventTs,
  }) {
    if (item case {'ts': final String targetTs}) {
      return SlackDeliveredEvent(
        type == SlackEventType.reactionAdded
            ? SlackReactionAdded(
                workspace: team,
                channel: channel,
                enterprise: enterprise,
                deliveredForUser: deliveredForUser,
                user: user,
                reaction: reaction,
                targetTs: targetTs,
                eventTs: eventTs,
                rawEvent: event,
              )
            : SlackReactionRemoved(
                workspace: team,
                channel: channel,
                enterprise: enterprise,
                deliveredForUser: deliveredForUser,
                user: user,
                reaction: reaction,
                targetTs: targetTs,
                eventTs: eventTs,
                rawEvent: event,
              ),
      );
    }
    return const SlackMalformed('reaction item missing channel or ts');
  }
  return const SlackMalformed(
    'reaction event missing user, reaction or event_ts',
  );
}

SlackDelivery _command(
  Map<String, Object?> payload,
  String team,
  String? enterprise,
) {
  final command = _nonEmpty(payload, 'command');
  final channel = _nonEmpty(payload, 'channel_id');
  final user = switch (payload) {
    {'user_id': final String user} => user,
    _ => null,
  };
  if (command == null || channel == null || user == null) {
    return const SlackMalformed(
      'command missing command, channel_id or user_id',
    );
  }
  return SlackDeliveredEvent(
    SlackCommand(
      workspace: team,
      channel: channel,
      enterprise: enterprise,
      user: user,
      command: command,
      // Present only when Slack passes it; absent for a top-level command.
      threadTs: _nonEmpty(payload, 'thread_ts'),
      text: switch (payload) {
        {'text': final String text} => text,
        _ => '',
      },
      triggerId: _nonEmpty(payload, 'trigger_id'),
      responseUrl: _nonEmpty(payload, 'response_url'),
    ),
  );
}
