class Config {
  static const bool showBatchEval = false;

  /// Name of the Fairy-Stockfish engine executable.
  static String engineBinaryName = 'fairySF_egtb_avx2.exe';

  /// Whether to query the online Lichess Tablebase API (tablebase.lichess.ovh).
  static bool enableRemoteTablebase = true;

  /// Whether to query the local tablebase sidecar server.
  static bool enableLocalTablebase = true;

  /// Whether to automatically launch the local tablebase sidecar server if not already running.
  static bool autoLaunchTablebaseServer = true;

  /// Base URL of the local tablebase sidecar server.
  static String localTablebaseUrl = 'http://127.0.0.1:8080';
}
