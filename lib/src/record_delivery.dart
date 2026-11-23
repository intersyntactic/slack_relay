/// Recording an accepted delivery in the logbook before Slack is answered.
///
/// The entry is `slack-event`, written by the docking station's own
/// [encodeRelayedEvent] (`{"at", "bytes"}`, the bytes exactly as signed), so
/// its translator reads back what the gate read.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:is_docking_station_api/is_docking_station_api.dart'
    show RelayedEventSource, encodeRelayedEvent;
import 'package:is_logbook_client/is_logbook_client.dart';

/// Writes one entry to the logbook: `LogbookWriter(path).write` is one.
typedef WritesLogbookEntry = Future<WriteResult> Function(
  Kind kind,
  List<int> body,
);

final _slack = RelayedEventSource.parse('slack')!;

/// Records [bytes] as taken in [at]. True when the logbook holds the entry,
/// whether written now or already there; false, with why, when it may not,
/// so Slack is answered 5xx and sends it again.
Future<(bool recorded, String why)> recordDelivery(
  WritesLogbookEntry write, {
  required Uint8List bytes,
  required DateTime at,
  required Duration timeout,
}) async {
  final (kind, entry) = encodeRelayedEvent(_slack, at: at, bytes: bytes);
  final WriteResult result;
  try {
    result = await write(kind, entry).timeout(timeout);
  } on TimeoutException {
    return (false, 'no answer within $timeout');
  }
  return switch (result) {
    Written(:final entry) => (true, 'recorded ${entry.hex}'),
    AlreadyRecorded(:final entry) => (true, 'already recorded ${entry.hex}'),
    // A chain start has no tip to be behind; the writer is not one we know.
    NotTip(:final tip) => (false, 'refused not-tip ${tip.hex}'),
    WriteRefused(:final why) => (false, 'refused $why'),
    WriteFailed(:final why) => (false, 'failed $why'),
    Unanswered(:final why) => (false, 'unanswered: $why'),
  };
}
