# is_slack_relay

Slack's part of an [is_relay](https://pub.dev/packages/is_relay) relay: the
check run on each delivery, and the parse of a delivery's bytes.

Slack's Event Subscriptions and Slash Commands both post to one URL. A
`RelayServer` from is_relay takes each delivery and runs
`SlackDeliveryCheck` on it. Every authentic delivery is recorded in the
logbook as a `slack-event` entry, and only then is Slack answered. The
logbook is the relay's only way out. A translator downstream reads the entry
back with `slackRecordedEvent`, the same parse the check ran, and decides
what it means. This package knows nothing of mirrors, node shapes or kickoff
records: those belong to the consuming module (`is_slack_module`, for
intersyntactic).

## Running it

`bin/slack_relay.dart` runs one:

```sh
SLACK_SIGNING_SECRET=... SLACK_TEAM_IDS=T0123 \
LOGBOOK_SOCKET=/run/logbook/write.sock dart run is_slack_relay:slack_relay
```

Run it behind a TLS proxy. dart:io doesn't time out header reads, so the
proxy must, and it must log neither headers nor bodies. The logbook writer's
sender table must let the relay's user send `slack-event`, or every
delivery is answered 503.

Or build one yourself:

```dart
final relay = RelayServer(
  check: SlackDeliveryCheck(
    secret: SlackSigningSecret.parse(secretFromEnv)!,
    workspaces: SlackWorkspaces.parse('T0123')!, // never empty
  ),
  logbook: LogbookSocket.parse(socketFromEnv)!,
  path: slackRelayPath, // /webhook/slack
  budget: slackRelayBudget, // 2.5 s: Slack sends again after 3 s
  rate: WriteRateBound(perMinute: 600, burst: 100),
);
await relay.serve(await HttpServer.bind(InternetAddress.loopbackIPv4, 8086));
```

## What is here

- `SlackDeliveryCheck`, which implements is_relay's `ChecksDeliveries`.
  - **On the headers**, before any of the body is read, it refuses a
    missing or stale `X-Slack-Request-Timestamp` (more than 5 minutes off
    either way), a missing `v0=` signature, and a content type Slack
    doesn't send.
  - **On the body**, it compares the HMAC over `v0:<timestamp>:<body>` in
    constant time, then checks the workspace against the allowlist. Signed
    bytes that are no Slack delivery are refused 400.
  - **What gets recorded:** everything else, including event types no
    `SlackEvent` covers, slash commands, and `url_verification`, which is
    answered with its challenge once it is recorded.
  - **What it doesn't do:** filter by event type or remember what it has
    seen. The docking station takes each event key once.
- `readSlackDelivery` / `slackRecordedEvent`: the pure parse of one
  delivery's bytes. No signature, no content type: the shape is sniffed,
  JSON if it starts with `{`, a slash command's form otherwise. It never
  throws.
- `SlackEvent` (sealed; `SlackMessage`, `SlackReactionAdded`,
  `SlackReactionRemoved`, `SlackCommand`): Slack's own record of what
  happened, with typed fields so no consumer reads Slack's maps by key.
  It carries content directly (a message's text, a reaction's emoji, a
  command's argument), since none of it can be fetched back later. It
  carries no actor: building a Slack actor id is the consuming module's job
  (`SlackActorId`).

## Slack app configuration gotchas

Three failures hit while wiring up the first consumer, none obvious from
Slack's own error messages:

- **"This app can only be installed by an admin"** on an otherwise-ordinary
  workspace install. Caused by a stray `admin.invites:read` user scope in
  the manifest — that scope alone marks the whole app Enterprise-only.
  Remove it unless the app genuinely needs it.
- **The manifest editor silently drops `settings.event_subscriptions`** on
  an unrelated edit made through the UI (e.g. adding a bot scope). Slack
  doesn't warn; the subscribed events just stop arriving. Re-check (or
  reapply) the full event subscription list after any manifest-editor save,
  not just the field you meant to change.
- **The `@`-mention handle resolves from `features.bot_user.display_name`,
  not `display_information.name`.** The two are set in different places in
  the manifest and can drift apart; if `@yourbot` isn't matching, check
  `display_name` first.

## Depending on it

```yaml
dependencies:
  is_slack_relay: ^0.4.0
```
