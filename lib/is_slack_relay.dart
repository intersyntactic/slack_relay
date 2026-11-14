/// Slack's ingress and transport: a pure gate plus the HTTP relay that
/// drives it. No knowledge of mirrors, node shapes, or kickoff records —
/// that domain logic belongs downstream, in whichever module consumes
/// [SlackRelay.onEvent] (is_slack_module, for intersyntactic).
library;

export 'src/slack_event.dart';
export 'src/slack_gate.dart';
export 'src/slack_relay.dart';
