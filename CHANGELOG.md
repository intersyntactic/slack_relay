# Changelog

## 0.1.0

- Extracted from `is_slack_module`'s `slack_gate.dart` and the generic half
  of its `SlackBot`, into its own package, on the same ingress/domain split
  `is_github_relay` already has from its consumers.
- `slackGate`: moved verbatim — pure signature/timestamp/replay checking,
  no change in behaviour.
- `SlackRelay`: new. Owns the HTTP bind, body cap and timeout, replay cache,
  and per-outcome ACKs that `SlackBot` used to own directly; hands decisions
  on to a generic `onDoorbell` callback instead of a mirror/receiver.
