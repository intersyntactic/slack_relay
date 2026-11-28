# Changelog

## 0.7.0

- **Breaking:** on checked_json ^0.4.0, is_docking_station_api ^0.11.0 and
  is_relay ^0.8.0. `slackEventSource` is the docking station's type, which
  is why this is breaking; nothing here names a type that moved to
  is_conversation_vocabulary, or `MessageSaid`.
- A JSON body that names a key twice (at any depth, keys compared once
  unescaped) or holds an integer past 2^53 - 1 is now `SlackMalformed`.
  Before, `jsonDecode` kept the last of a repeated key without a word, so a
  signed body could carry two `team_id`s and be read by the second.
- Dev: is_logbook_client ^0.4.0.

## 0.6.0

- **Breaking:** on is_docking_station_api ^0.8.0 and is_relay ^0.5.0. The
  docking station's reply types now come from
  is_conversation_reply_vocabulary. Nothing here names a reply type, and `RelayedEventSource`, `encodeRelayedEvent` and
  `RelayedEvent.read` are the same from 0.7.0 to 0.8.0. It is breaking only
  because `slackEventSource` is the docking station's type, and it lets a
  consumer leave the old is_reply_vocabulary behind.

## 0.5.0

- **Breaking:** on is_docking_station_api ^0.7.0 and is_relay ^0.3.0.
  Nothing here changed: `RelayedEventSource`, `encodeRelayedEvent` and
  `RelayedEvent.read` are the same from 0.4.0 to 0.7.0, and so is the
  logbook's JSON for a relayed event. It is breaking only because
  `slackEventSource` is the docking station's type, so a consumer has to be
  on the same range. That lets is_slack_module use 0.7.0's
  `RepliesInSlackConversation`.

## 0.4.0

- **Breaking:** `constantTimeEquals` is no longer exported from here; it
  is is_relay's (^0.2.0), the same function.
- **Breaking:** on is_relay. `SlackDeliveryCheck` implements
  `ChecksDeliveries`, and is_relay's `RelayServer` serves it, records each
  delivery and answers. Removed: `SlackRelay` and its `onEvent`, `slackGate`
  and its decision types, `SlackSourceSpec`, the signature-digest replay
  cache, the wake filter, and the relay's own logbook write. The logbook is
  the relay's only way out.
- Every authentic delivery from an allowed workspace is recorded:
  `url_verification` (answered `{"challenge"}`), slash commands, and event
  types no `SlackEvent` covers. The translator decides what each means.
- `SlackSigningSecret`, which can't be empty, and `SlackWorkspaces`, the
  allowlist, which can't be empty either: there is no "any workspace". Its
  set is copied and can't be changed after the check is built.
- `bin/slack_relay.dart` warns when it binds plain HTTP off loopback.
- `SlackNotCovered.workspace`, so the allowlist applies to deliveries no
  `SlackEvent` covers.
- `bin/slack_relay.dart` runs a relay from `SLACK_SIGNING_SECRET`,
  `SLACK_TEAM_IDS` and `LOGBOOK_SOCKET`.
- Fixed: a signed form body with a raw character above 127 (`text=café`)
  threw an `ArgumentError` out of `Uri.splitQueryString`, which ends an
  is_relay process. Form bodies are now decoded by hand, which can't throw,
  and the percent-encoding pre-check that guarded only one of its two
  throwing paths is gone.
- `Content-Type` decides nothing: it is outside the signature.
- Fixed: an `X-Slack-Request-Timestamp` past year 9999 threw a
  `RangeError` before the signature was checked. The timestamp is now
  compared in whole seconds within a bounded range.

## 0.3.2

- Fixed: a signed form body with a raw character above 127 (`text=café`)
  made the gate throw an `ArgumentError` out of `Uri.splitQueryString`,
  which `SlackRelay`'s `on Exception` didn't catch. Form bodies are now
  decoded by hand, which can't throw, as in 0.4.0.

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
