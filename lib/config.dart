class Config {
  static const bool showBatchEval = false;

  /// Whether to query the online Lichess Tablebase API (tablebase.lichess.ovh).
  /// Switched off by default to prevent network throttling and rate-limiting.
  static bool enableRemoteTablebase = false;
}
