class WatkinsIndexEntry {
  final int hash;
  final int nodeU;
  final int dtw;
  final int bestMoveRaw;

  const WatkinsIndexEntry({
    required this.hash,
    required this.nodeU,
    required this.dtw,
    required this.bestMoveRaw,
  });

  String? get bestMoveUci => null;
}

class WatkinsZobrist {
  static int hashBfen(String bfen) => 0;
}

class WatkinsProofIndexManager {
  static final WatkinsProofIndexManager instance =
      WatkinsProofIndexManager._();

  WatkinsProofIndexManager._();

  bool get hasIndices => false;

  void ensureLoaded({List<String> searchDirs = const ['.', 'data']}) {}

  void refresh({List<String> searchDirs = const ['.', 'data']}) {}

  WatkinsIndexEntry? lookupBfen(String bfen) => null;

  WatkinsIndexEntry? lookupHash(int hash) => null;
}
