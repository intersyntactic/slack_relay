/// Runs the Slack relay: checks each delivery, records it in the logbook,
/// and only then answers Slack.
///
/// Run behind a TLS proxy, which must time out header reads (dart:io doesn't)
/// and must log neither headers nor bodies.
///
///   SLACK_SIGNING_SECRET=...  the app's signing secret
///   SLACK_TEAM_IDS=T1,T2      the workspaces taken from
///   LOGBOOK_SOCKET=/run/...   the logbook writer's socket; its sender table
///                             must let this user send `slack-event`
///   PORT=8086                 optional
///   HOST=127.0.0.1            optional; loopback, for a proxy on this machine
///
/// Slack: Event Subscriptions and Slash Commands both at
/// `https://<host>/webhook/slack`.
library;

import 'dart:io';

import 'package:is_relay/is_relay.dart';
import 'package:is_slack_relay/is_slack_relay.dart';

Future<void> main() async {
  final env = Platform.environment;
  void abort(String why) {
    stderr.writeln('abort: $why');
    exit(78);
  }

  final secret = SlackSigningSecret.parse(env['SLACK_SIGNING_SECRET'] ?? '');
  if (secret == null) return abort('SLACK_SIGNING_SECRET is not set');
  final workspaces = SlackWorkspaces.parse(env['SLACK_TEAM_IDS'] ?? '');
  if (workspaces == null) return abort('SLACK_TEAM_IDS names no workspace');
  final logbook = LogbookSocket.parse(env['LOGBOOK_SOCKET'] ?? '');
  if (logbook == null) return abort('LOGBOOK_SOCKET is not an absolute path');
  final rawPort = env['PORT'] ?? '';
  final port = rawPort.isEmpty ? 8086 : int.tryParse(rawPort);
  if (port == null || port < 1 || port > 65535) {
    return abort('PORT "$rawPort" is not a port number');
  }
  final rawHost = env['HOST'] ?? '';
  final address = InternetAddress.tryParse(
    rawHost.isEmpty ? '127.0.0.1' : rawHost,
  );
  if (address == null) return abort('HOST "$rawHost" is not an IP address');

  final relay = RelayServer(
    check: SlackDeliveryCheck(secret: secret, workspaces: workspaces),
    logbook: logbook,
    path: slackRelayPath,
    budget: slackRelayBudget,
    // A busy workspace's events, with room for a burst after a quiet spell.
    rate: WriteRateBound(perMinute: 600, burst: 100),
  );
  final server = await HttpServer.bind(address, port);
  stdout.writeln('slack relay on ${address.address}:${server.port}');
  if (!address.isLoopback) {
    // Plain HTTP: signed Slack bodies cross the wire in clear unless a TLS
    // proxy is the only thing that can reach this port.
    stderr.writeln(
      'warning: serving plain HTTP on ${address.address}, not loopback',
    );
  }
  await relay.serve(server);
}
