class Config {
  static const bool showBatchEval = false;

  /// Whether to query the online Lichess Tablebase API (tablebase.lichess.ovh).
  static bool enableRemoteTablebase = true;

  /// Whether to query the local tablebase sidecar server.
  static bool enableLocalTablebase = true;

  /// Base URL of the local tablebase sidecar server.
  static String localTablebaseUrl = 'http://127.0.0.1:8080';
}
