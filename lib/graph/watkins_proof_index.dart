import 'dart:io';
import 'dart:typed_data';

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

  String? get bestMoveUci {
    if (bestMoveRaw == 0 || bestMoveRaw == 0xfedc || bestMoveRaw == 0x0edc) {
      return null;
    }
    var mv = bestMoveRaw;
    if ((mv >> 12) > 8 || (mv >> 12) == 7) {
      mv ^= 0xf000;
    }
    final fr = (mv >> 6) & 0x3f;
    final to = mv & 0x3f;
    final prom = (mv >> 12) & 0x7;
    const promChars = '01nbrqk7';

    final fromFile = String.fromCharCode(0x61 + (fr & 7));
    final fromRank = (1 + (fr >> 3)).toString();
    final toFile = String.fromCharCode(0x61 + (to & 7));
    final toRank = (1 + (to >> 3)).toString();

    var res = '$fromFile$fromRank$toFile$toRank';
    if (prom != 0 && prom < promChars.length) {
      res += promChars[prom];
    }
    return res;
  }
}

class WatkinsZobrist {
  static final Uint64List _pieceKeys = Uint64List(12 * 64);
  static late final int _blackToMoveKey;
  static final Uint64List _epFileKeys = Uint64List(8);
  static bool _initialized = false;

  static int _splitmix64(Uint64List stateBox) {
    int z = (stateBox[0] = stateBox[0] + 0x9e3779b97f4a7c15);
    z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >>> 27)) * 0x94d049bb133111eb;
    return z ^ (z >>> 31);
  }

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    final stateBox = Uint64List(1);
    stateBox[0] = 0x524554524F534F4C;
    for (int i = 0; i < 12 * 64; i++) {
      _pieceKeys[i] = _splitmix64(stateBox);
    }
    _blackToMoveKey = _splitmix64(stateBox);
    for (int i = 0; i < 8; i++) {
      _epFileKeys[i] = _splitmix64(stateBox);
    }
  }

  static int _charToPieceCode(int c) {
    final isBlack = (c >= 0x61 && c <= 0x7a);
    final lower = c | 0x20;
    int pt;
    switch (lower) {
      case 0x70: // 'p'
        pt = 1;
        break;
      case 0x6e: // 'n'
        pt = 2;
        break;
      case 0x62: // 'b'
        pt = 3;
        break;
      case 0x72: // 'r'
        pt = 4;
        break;
      case 0x71: // 'q'
        pt = 5;
        break;
      case 0x6b: // 'k'
        pt = 6;
        break;
      default:
        return 0;
    }
    return (isBlack ? 8 : 0) | pt;
  }

  /// Computes the canonical 64-bit Zobrist hash for an Antichess [bfen],
  /// matching `FastAntiBoard::full_hash()` in `watkins_indexer.cpp`.
  static int hashBfen(String bfen) {
    _ensureInitialized();
    final parts = bfen.split(' ');
    if (parts.length < 2) return 0;

    final boardStr = parts[0];
    final isBlack = parts[1] == 'b';

    final board = Uint8List(64);
    int rank = 7;
    int file = 0;
    int h = 0;

    for (int i = 0; i < boardStr.length; i++) {
      final c = boardStr.codeUnitAt(i);
      if (c == 0x2f) {
        rank--;
        file = 0;
      } else if (c >= 0x31 && c <= 0x38) {
        file += c - 0x30;
      } else {
        final p = _charToPieceCode(c);
        if (p != 0 && rank >= 0 && rank < 8 && file >= 0 && file < 8) {
          final sq = rank * 8 + file;
          board[sq] = p;
          final color = (p >> 3) & 1;
          final pt = p & 7;
          final zIdx = color * 6 + (pt - 1);
          h ^= _pieceKeys[zIdx * 64 + sq];
        }
        file++;
      }
    }

    if (isBlack) {
      h ^= _blackToMoveKey;
    }

    if (parts.length >= 4 && parts[3] != '-' && parts[3].length == 2) {
      final epFile = parts[3].codeUnitAt(0) - 0x61;
      final epRank = parts[3].codeUnitAt(1) - 0x31;
      if (epFile >= 0 && epFile < 8 && (epRank == 2 || epRank == 5)) {
        final pawnRankBase = isBlack ? 24 : 32;
        final neededPawn = isBlack ? 9 : 1;
        bool canEp = false;
        if (epFile > 0 && board[pawnRankBase + epFile - 1] == neededPawn) {
          canEp = true;
        }
        if (epFile < 7 && board[pawnRankBase + epFile + 1] == neededPawn) {
          canEp = true;
        }
        if (canEp) {
          h ^= _epFileKeys[epFile];
        }
      }
    }

    return h;
  }
}

class WatkinsProofIndexFile {
  static const int _headerBytes = 16 + 65537 * 8; // 524,312 bytes
  static const int _signBit = -0x8000000000000000;

  final String path;
  final RandomAccessFile _raf;
  final int numEntries;
  final Uint64List _bucketOffsets;
  int _cachedPrefix16 = -1;
  ByteData? _cachedBucketBd;
  int _cachedBucketCount = 0;

  WatkinsProofIndexFile._({
    required this.path,
    required RandomAccessFile raf,
    required this.numEntries,
    required Uint64List bucketOffsets,
  })  : _raf = raf,
        _bucketOffsets = bucketOffsets;

  static WatkinsProofIndexFile? open(String idxPath) {
    final file = File(idxPath);
    if (!file.existsSync() || file.lengthSync() < _headerBytes) {
      return null;
    }
    final raf = file.openSync(mode: FileMode.read);
    final hdrBytes = Uint8List(_headerBytes);
    final read = raf.readIntoSync(hdrBytes);
    if (read < _headerBytes) {
      raf.closeSync();
      return null;
    }
    final bd = ByteData.sublistView(hdrBytes);
    final magic = bd.getUint32(0, Endian.little);
    final version = bd.getUint32(4, Endian.little);
    if (magic != 0x57494458 || version != 1) {
      raf.closeSync();
      return null;
    }
    final numEntries = bd.getUint64(8, Endian.little);
    final bucketOffsets = Uint64List(65537);
    for (int i = 0; i < 65537; i++) {
      bucketOffsets[i] = bd.getUint64(16 + i * 8, Endian.little);
    }
    return WatkinsProofIndexFile._(
      path: file.path,
      raf: raf,
      numEntries: numEntries,
      bucketOffsets: bucketOffsets,
    );
  }

  WatkinsIndexEntry? lookupHash(int hash) {
    final prefix16 = (hash >>> 48) & 0xFFFF;
    ByteData bd;
    int count;

    if (_cachedPrefix16 == prefix16 && _cachedBucketBd != null) {
      bd = _cachedBucketBd!;
      count = _cachedBucketCount;
    } else {
      final startIdx = _bucketOffsets[prefix16];
      final endIdx = _bucketOffsets[prefix16 + 1];
      count = endIdx - startIdx;
      if (count <= 0) return null;

      final byteCount = count * 16;
      final buf = Uint8List(byteCount);
      _raf.setPositionSync(_headerBytes + startIdx * 16);
      final got = _raf.readIntoSync(buf);
      if (got < byteCount) return null;

      bd = ByteData.sublistView(buf);
      _cachedPrefix16 = prefix16;
      _cachedBucketBd = bd;
      _cachedBucketCount = count;
    }

    final targetUnsigned = hash ^ _signBit;

    int lo = 0;
    int hi = count - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >>> 1;
      final midOffset = mid * 16;
      final midHash = bd.getUint64(midOffset, Endian.little);
      if (midHash == hash) {
        final nodeU = bd.getUint32(midOffset + 8, Endian.little);
        final dtw = bd.getUint16(midOffset + 12, Endian.little);
        final bestMove = bd.getUint16(midOffset + 14, Endian.little);
        return WatkinsIndexEntry(
          hash: hash,
          nodeU: nodeU,
          dtw: dtw,
          bestMoveRaw: bestMove,
        );
      }
      final midUnsigned = midHash ^ _signBit;
      if (midUnsigned < targetUnsigned) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  void close() {
    _raf.closeSync();
  }
}

class WatkinsProofIndexManager {
  static final WatkinsProofIndexManager instance =
      WatkinsProofIndexManager._();

  final List<WatkinsProofIndexFile> _indices = [];
  final Set<String> _loadedPaths = {};
  bool _scanned = false;

  WatkinsProofIndexManager._();

  void ensureLoaded({List<String> searchDirs = const ['.', 'data']}) {
    if (_scanned) return;
    _scanned = true;
    refresh(searchDirs: searchDirs);
  }

  void refresh({List<String> searchDirs = const ['.', 'data']}) {
    final dirsToScan = <String>{...searchDirs};

    var probe = Directory.current;
    for (int i = 0; i < 6; i++) {
      dirsToScan.add(probe.path);
      dirsToScan.add('${probe.path}/data');
      final parent = probe.parent;
      if (parent.path == probe.path) break;
      probe = parent;
    }

    try {
      var exeProbe = File(Platform.resolvedExecutable).parent;
      for (int i = 0; i < 6; i++) {
        dirsToScan.add(exeProbe.path);
        dirsToScan.add('${exeProbe.path}/data');
        final parent = exeProbe.parent;
        if (parent.path == exeProbe.path) break;
        exeProbe = parent;
      }
    } catch (_) {}

    for (final dirPath in dirsToScan) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.proof.idx')) {
          final absPath = entity.absolute.path;
          if (_loadedPaths.contains(absPath)) continue;
          final idx = WatkinsProofIndexFile.open(absPath);
          if (idx != null) {
            _indices.add(idx);
            _loadedPaths.add(absPath);
          }
        }
      }
    }
  }

  bool get hasIndices {
    ensureLoaded();
    return _indices.isNotEmpty;
  }

  WatkinsIndexEntry? lookupBfen(String bfen) {
    ensureLoaded();
    if (_indices.isEmpty) return null;
    final hash = WatkinsZobrist.hashBfen(bfen);
    return lookupHash(hash);
  }

  WatkinsIndexEntry? lookupHash(int hash) {
    ensureLoaded();
    for (int i = 0; i < _indices.length; i++) {
      final entry = _indices[i].lookupHash(hash);
      if (entry != null) return entry;
    }
    return null;
  }
}
