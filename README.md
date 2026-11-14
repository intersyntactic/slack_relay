# is_slack_relay

The HTTP front of a Slack app: ingress and transport, not domain logic.

Slack's Event Subscriptions and Slash Commands both point at one URL. This
package checks each delivery — signature, timestamp window, replay — and
hands the authentic, wake-worthy ones on as a plain `Map<String, dynamic>`
doorbell. It carries no knowledge of mirrors, node shapes, or kickoff
records; that domain logic belongs downstream, in whichever module consumes
it (`is_slack_module`, for intersyntactic).

```dart
import 'dart:io';

import 'package:is_slack_relay/is_slack_relay.dart';

final relay = SlackRelay(
  spec: SlackSourceSpec(
    signingSecret: Platform.environment['SLACK_SIGNING_SECRET']!,
    teamIdAllowlist: {'T0123'},
  ),
  onDoorbell: (bell) async {
    // bell['event'] is 'slack_mention', 'slack_message', 'slack_command', ...
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
  window, consults a caller-owned `hasSeen` closure for replay, and parses
  the Slack payload into a doorbell `message`. No socket, no clock of its
  own, no Slack dependency beyond `crypto` — every case is testable with
  plain values.
- `SlackRelay`: the HTTP front end built on the gate. It binds one route
  (`/webhook/slack`), caps and times out the request body, owns the
  replay-dedupe cache the gate's `hasSeen` needs, answers Slack within its
  budget (200 + challenge echo for `urlVerification`, 200 then a
  backgrounded dispatch for `trigger`, 200 for `ignore`, 401 for `reject`,
  404 for any other path), and calls `onDoorbell` with whatever the gate
  decided to trigger on.

## Why split from the module that uses it

Same shape as `is_github_relay` has from its own consumers: ingress and
transport (verifying a sender, deduping, answering on time) is a different
concern from domain logic (turning a doorbell into node shapes, mirrors,
kickoff records), and the two don't need to version together. A module
with Slack domain logic depends on this package, not the other way around.

## Depending on it

```yaml
dependencies:
  is_slack_relay: ^0.1.0
```
