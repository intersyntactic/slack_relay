# Changelog

## 0.3.1

- Fixed: an `X-Slack-Request-Timestamp` past year 275760 made the gate
  throw a `RangeError` before the signature was checked, which
  `SlackRelay`'s `on Exception` didn't catch. Timestamps outside 0 to year
  9999 are now rejected.

## 0.3.0

- `readSlackDelivery(Uint8List)` and `slackRecordedEvent(Uint8List)`: the
  pure parse, taken out of `slackGate`. The gate calls it after verifying,
  and a consumer calls it on bytes read back from the logbook. The shape is
  sniffed (JSON if it starts with `{`, otherwise a form), so it needs no
  content type. A bad percent-encoding in a form body is now refused.
  Before, it threw an `ArgumentError` out of the gate.
- New typed fields: `SlackEvent.deliveredForUser` (from
  `authorizations[].user_id`) and `SlackEvent.enterprise`
  (`enterprise_id`), plus `SlackMessage.botId` and
  `SlackMessage.channelType` (`SlackChannelType`).
- **Breaking:** `SlackMessage.subtype` is a `SlackMessageSubtype` enum,
  with `unnamed` for a subtype it doesn't name.
- **Breaking:** `SlackSourceSpec.wakeEventTypes` is a
  `Set<SlackEventType>`.
- **Breaking:** `rawEvent` is `Map<String, Object?>`.
- **Breaking:** `SlackRelay` takes a required `record`
  (`LogbookWriter(socket).write`, or null). Every triggered delivery is
  recorded as `slack-event` before Slack is answered, and anything but a
  written or already-recorded entry is answered 503.
- Loads `is_lint_rules`.

## 0.2.0

- **Breaking:** what the gate hands on is a typed `SlackEvent`, not a
  "doorbell" map. "Doorbell" came from relays whose notice carries nothing
  and sends the reader off to fetch; Slack's carries the person's words
  inline, same as a slash command's argument, so the name said the opposite
  of the one thing that matters about it (mirrors `is_teams_module`'s same
  rename, in flight on its own `refactor/arrival` branch as this landed).
  `SlackGateDecision.message` is now `.event`; `SlackRelay.onDoorbell` is
  now `.onEvent`.
- `SlackEvent` (sealed): `SlackMessage` (app_mention and plain message, any
  subtype), `SlackReactionAdded`, `SlackReactionRemoved`, `SlackCommand`.
  Typed fields instead of a `Map<String, dynamic>`; same information as
  before, read once in the gate instead of downstream. Deliberately has no
  `actor` — that stays a domain concern in the consuming module.

## 0.1.0

- Extracted from `is_slack_module`'s `slack_gate.dart` and the generic half
  of its `SlackBot`, into its own package, on the same ingress/domain split
  `is_github_relay` already has from its consumers.
- `slackGate`: moved verbatim — pure signature/timestamp/replay checking,
  no change in behaviour.
- `SlackRelay`: new. Owns the HTTP bind, body cap and timeout, replay cache,
  and per-outcome ACKs that `SlackBot` used to own directly; hands decisions
  on to a generic `onDoorbell` callback instead of a mirror/receiver.
