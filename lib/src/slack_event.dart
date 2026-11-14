/// Slack's record of one delivery, checked by the gate. Each case is named
/// for Slack's own event or command, since it is Slack's account of what
/// happened, not a reading of it — that's the consumer's job downstream.
///
/// It carries content: a message's text, a reaction's emoji, a slash
/// command's argument exist nowhere but the request that brought them, so
/// they come here, not as a pointer to fetch them by.
///
/// Deliberately carries no `actor`: unlike Teams (whose sender is an Entra
/// id this layer can turn into an actor id on its own), Slack's actor
/// construction is a domain concern that already lives in the consuming
/// module (`SlackActorId.forWorkspace`), and isn't duplicated here.
sealed class SlackEvent {
  const SlackEvent({required this.workspace, required this.channel});

  /// The workspace's team id.
  final String workspace;

  final String channel;
}

/// An `app_mention` or plain `message`. Covers every subtype Slack sends
/// under `message` — a plain send, `message_changed`, `message_deleted`, and
/// anything not yet named — since the gate forwards them faithfully rather
/// than resolving an edit or deletion against prior state, which needs a
/// mirror lookup this layer doesn't have.
final class SlackMessage extends SlackEvent {
  const SlackMessage({
    required super.workspace,
    required super.channel,
    required this.threadTs,
    this.mention = false,
    this.user,
    this.text,
    this.eventTs,
    this.subtype,
    this.rawThreadTs,
    this.rawEvent = const {},
  });

  /// The conversation anchor: `thread_ts` when already in a thread, the
  /// message's own `ts` when it is a top-level send that will seed one.
  final String threadTs;

  /// True for `app_mention`, false for a plain `message`.
  final bool mention;

  final String? user;
  final String? text;

  /// The message's own `ts` (not necessarily [threadTs]).
  final String? eventTs;

  /// `message_changed`, `message_deleted`, or null for a plain send.
  final String? subtype;

  /// `event.thread_ts` exactly as Slack sent it, before being folded into
  /// [threadTs]. Null when the message was top-level.
  final String? rawThreadTs;

  /// The full inner event, unread by the gate, for a subtype no typed field
  /// here covers — `message_changed`'s `message`/`previous_message`,
  /// `message_deleted`'s `deleted_ts`, and anything not yet named.
  final Map<String, dynamic> rawEvent;
}

/// A `reaction_added` on a message.
final class SlackReactionAdded extends SlackEvent {
  const SlackReactionAdded({
    required super.workspace,
    required super.channel,
    required this.user,
    required this.reaction,
    required this.targetTs,
    required this.eventTs,
    this.rawEvent = const {},
  });

  final String user;
  final String reaction;

  /// The `ts` of the message reacted to. No `thread_ts` travels with a
  /// reaction event — resolving the journey needs a mirror lookup by
  /// `(channel, targetTs)`, which is the consumer's job.
  final String targetTs;

  final String eventTs;
  final Map<String, dynamic> rawEvent;
}

/// A `reaction_removed` on a message.
final class SlackReactionRemoved extends SlackEvent {
  const SlackReactionRemoved({
    required super.workspace,
    required super.channel,
    required this.user,
    required this.reaction,
    required this.targetTs,
    required this.eventTs,
    this.rawEvent = const {},
  });

  final String user;
  final String reaction;
  final String targetTs;
  final String eventTs;
  final Map<String, dynamic> rawEvent;
}

/// A slash command Slack was configured to send.
final class SlackCommand extends SlackEvent {
  const SlackCommand({
    required super.workspace,
    required super.channel,
    required this.user,
    required this.command,
    this.threadTs,
    this.text = '',
    this.triggerId,
    this.responseUrl,
  });

  final String user;
  final String command;

  /// Present only when Slack passes it; null for a top-level command.
  final String? threadTs;

  final String text;
  final String? triggerId;
  final String? responseUrl;
}
