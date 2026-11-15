# is_slack_relay

The HTTP front of a Slack app: ingress and transport, not domain logic.

Slack's Event Subscriptions and Slash Commands both point at one URL. This
package checks each delivery — signature, timestamp window, replay — and
hands the authentic, wake-worthy ones on as a typed `SlackEvent`. It carries
no knowledge of mirrors, node shapes, or kickoff records; that domain logic
belongs downstream, in whichever module consumes it (`is_slack_module`, for
intersyntactic).

```dart
import 'dart:io';

import 'package:is_slack_relay/is_slack_relay.dart';

final relay = SlackRelay(
  spec: SlackSourceSpec(
    signingSecret: Platform.environment['SLACK_SIGNING_SECRET']!,
    teamIdAllowlist: {'T0123'},
  ),
  onEvent: (event) async {
    switch (event) {
      case SlackMessage(:final text):
        // an app_mention (event.mention) or a plain message
      case SlackReactionAdded():
      case SlackReactionRemoved():
      case SlackCommand(:final command):
    }
  },
);
final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8086);
await for (final req in server) {
  unawaited(relay.handle(req));
}
```

## What is here

- `slackGate` (`SlackSourceSpec`, `SlackGateDecision`, `SlackGateOutcome`):
  the pure decision function. Given headers, a body, a content type, and
  the current time, it verifies the HMAC signature, checks the timestamp
  window, consults a caller-owned `hasSeen` closure for replay, and reads
  the Slack payload into a `SlackEvent`. No socket, no clock of its own, no
  Slack dependency beyond `crypto` — every case is testable with plain
  values.
- `SlackEvent` (sealed; `SlackMessage`, `SlackReactionAdded`,
  `SlackReactionRemoved`, `SlackCommand`): Slack's own record of what
  happened, each case named for Slack's event or command. Carries content —
  a message's text, a reaction's emoji, a command's argument — directly,
  since none of it can be fetched back later. Deliberately carries no actor:
  unlike a platform whose sender maps straight onto an id this layer could
  mint, Slack's actor construction stays a domain concern
  (`SlackActorId.forWorkspace`, in `is_slack_module`), not duplicated here.
- `SlackRelay`: the HTTP front end built on the gate. It binds one route
  (`/webhook/slack`), caps and times out the request body, owns the
  replay-dedupe cache the gate's `hasSeen` needs, answers Slack within its
  budget (200 + challenge echo for `urlVerification`, 200 then a
  backgrounded dispatch for `trigger`, 200 for `ignore`, 401 for `reject`,
  404 for any other path), and calls `onEvent` with whatever the gate
  decided to trigger on.

## Why split from the module that uses it

Same shape as `is_github_relay` has from its own consumers: ingress and
transport (verifying a sender, deduping, answering on time) is a different
concern from domain logic (turning a doorbell into node shapes, mirrors,
kickoff records), and the two don't need to version together. A module
with Slack domain logic depends on this package, not the other way around.

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
  is_slack_relay: ^0.2.0
```
