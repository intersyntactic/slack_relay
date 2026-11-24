/// Slack's part of a relay: the check an is_relay [RelayServer] runs on each
/// delivery, and the pure parse of a delivery's bytes, which the translator
/// downstream runs on what the logbook holds. No knowledge of mirrors, node
/// shapes or kickoff records: that belongs to the consuming module
/// (is_slack_module, for intersyntactic).
library;

export 'src/slack_delivery.dart';
export 'src/slack_delivery_check.dart';
export 'src/slack_event.dart';
