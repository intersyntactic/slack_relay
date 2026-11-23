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
  const SlackEvent({
    required this.workspace,
    required this.channel,
    this.enterprise,
    this.deliveredForUser,
  });

  /// The workspace's team id.
  final String workspace;

  final String channel;

  /// The Enterprise Grid org's id, when the workspace is in one.
  final String? enterprise;

  /// The user the delivery was for: the outer payload's
  /// `authorizations[].user_id`, which for a bot install is the app's own bot
  /// user. Lets a consumer tell its own bot's messages from another bot's.
  /// Null for a slash command, which carries no authorizations.
  final String? deliveredForUser;
}

/// The Slack event types a [SlackEvent] can be read from.
enum SlackEventType {
  appMention('app_mention'),
  message('message'),
  reactionAdded('reaction_added'),
  reactionRemoved('reaction_removed');

  const SlackEventType(this.wireName);

  /// The `event.type` Slack sends.
  final String wireName;

  /// The type Slack calls [wireName]; null for one no [SlackEvent] covers.
  static SlackEventType? parse(String wireName) {
    for (final t in values) {
      if (t.wireName == wireName) return t;
    }
    return null;
  }
}

/// Where a message was posted, as Slack's `channel_type` says.
enum SlackChannelType {
  /// A public channel.
  channel('channel'),

  /// A private channel.
  group('group'),

  /// A direct message with one person.
  im('im'),

  /// A group direct message.
  mpim('mpim'),

  /// The app's own Messages tab.
  appHome('app_home');

  const SlackChannelType(this.wireName);

  final String wireName;

  /// The type Slack calls [wireName]; null for one not named here.
  static SlackChannelType? parse(String wireName) {
    for (final t in values) {
      if (t.wireName == wireName) return t;
    }
    return null;
  }
}

/// A message's `subtype`, the kinds Slack documents. A subtype Slack sends
/// that isn't named here is [unnamed]; its wire name is still in
/// [SlackMessage.rawEvent].
enum SlackMessageSubtype {
  botMessage('bot_message'),
  meMessage('me_message'),
  messageChanged('message_changed'),
  messageDeleted('message_deleted'),
  messageReplied('message_replied'),
  threadBroadcast('thread_broadcast'),
  fileShare('file_share'),
  channelJoin('channel_join'),
  channelLeave('channel_leave'),
  channelTopic('channel_topic'),
  channelPurpose('channel_purpose'),
  channelName('channel_name'),
  channelArchive('channel_archive'),
  channelUnarchive('channel_unarchive'),
  channelConvertToPrivate('channel_convert_to_private'),
  channelConvertToPublic('channel_convert_to_public'),
  channelPostingPermissions('channel_posting_permissions'),
  groupJoin('group_join'),
  groupLeave('group_leave'),
  groupTopic('group_topic'),
  groupPurpose('group_purpose'),
  groupName('group_name'),
  groupArchive('group_archive'),
  groupUnarchive('group_unarchive'),
  pinnedItem('pinned_item'),
  unpinnedItem('unpinned_item'),
  reminderAdd('reminder_add'),
  ekmAccessDenied('ekm_access_denied'),
  assistantAppThread('assistant_app_thread'),
  huddleThread('huddle_thread'),
  unnamed('');

  const SlackMessageSubtype(this.wireName);

  /// The `subtype` Slack sends; empty for [unnamed].
  final String wireName;

  /// The subtype Slack calls [wireName], [unnamed] for one not named here.
  static SlackMessageSubtype parse(String wireName) {
    for (final t in values) {
      if (t != unnamed && t.wireName == wireName) return t;
    }
    return unnamed;
  }
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
    super.enterprise,
    super.deliveredForUser,
    this.mention = false,
    this.user,
    this.botId,
    this.channelType,
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

  /// The `bot_id` of the bot that posted it; null when a person did.
  final String? botId;

  /// Null on `app_mention`, which Slack sends without one, and for a type
  /// [SlackChannelType] doesn't name.
  final SlackChannelType? channelType;

  final String? text;

  /// The message's own `ts` (not necessarily [threadTs]).
  final String? eventTs;

  /// Null for a plain send.
  final SlackMessageSubtype? subtype;

  /// `event.thread_ts` exactly as Slack sent it, before being folded into
  /// [threadTs]. Null when the message was top-level.
  final String? rawThreadTs;

  /// The full inner event, unread by the gate, for a subtype no typed field
  /// here covers — `message_changed`'s `message`/`previous_message`,
  /// `message_deleted`'s `deleted_ts`, and anything not yet named.
  final Map<String, Object?> rawEvent;
}

/// A `reaction_added` on a message.
final class SlackReactionAdded extends SlackEvent {
  const SlackReactionAdded({
    required super.workspace,
    required super.channel,
    super.enterprise,
    super.deliveredForUser,
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
  final Map<String, Object?> rawEvent;
}

/// A `reaction_removed` on a message.
final class SlackReactionRemoved extends SlackEvent {
  const SlackReactionRemoved({
    required super.workspace,
    required super.channel,
    super.enterprise,
    super.deliveredForUser,
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
  final Map<String, Object?> rawEvent;
}

/// A slash command Slack was configured to send.
final class SlackCommand extends SlackEvent {
  const SlackCommand({
    required super.workspace,
    required super.channel,
    super.enterprise,
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
