import 'dart:io';
import 'dart:typed_data';

/// Represents an entry in a Polyglot format opening book.
class PolyglotEntry {
  final BigInt key;
  final int pgMove;
  final int weight;
  final int learn;

  PolyglotEntry({
    required this.key,
    required this.pgMove,
    required this.weight,
    required this.learn,
  });

  /// Decodes the move into UCI string format (e.g. 'e2e4', 'b5d7', 'e7e8q').
  String get uci {
    final toFile = pgMove & 7;
    final toRank = (pgMove >> 3) & 7;
    final fromFile = (pgMove >> 6) & 7;
    final fromRank = (pgMove >> 9) & 7;
    final promo = (pgMove >> 12) & 7;

    final fromSq =
        '${String.fromCharCode('a'.codeUnitAt(0) + fromFile)}${fromRank + 1}';
    final toSq =
        '${String.fromCharCode('a'.codeUnitAt(0) + toFile)}${toRank + 1}';

    String promoStr = '';
    if (promo == 1) {
      promoStr = 'n';
    } else if (promo == 2) {
      promoStr = 'b';
    } else if (promo == 3) {
      promoStr = 'r';
    } else if (promo == 4) {
      promoStr = 'q';
    } else if (promo == 5) {
      promoStr = 'k';
    }

    return '$fromSq$toSq$promoStr';
  }

  /// Score in moves (MATE_VALUE - weight).
  int get dtwMoves => 32767 - weight;

  /// Score in plies.
  int get dtwPlies => (32767 - weight) * 2;

  /// Subtree nodes count.
  int get nodes => learn;
}

/// Fast reader and binary-search indexer for Polyglot binary books.
class PolyglotBook {
  final ByteData _bd;
  final int numEntries;

  PolyglotBook(Uint8List bytes)
      : _bd = ByteData.sublistView(bytes),
        numEntries = bytes.length ~/ 16;

  static PolyglotBook fromFile(String path) {
    return PolyglotBook(File(path).readAsBytesSync());
  }

  /// Probes the book for a given 64-bit Zobrist key.
  /// Returns the first matching [PolyglotEntry] or null if not found.
  PolyglotEntry? probe(BigInt key) {
    int low = 0;
    int high = numEntries - 1;

    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final midKey =
          BigInt.from(_bd.getUint64(mid * 16, Endian.big)).toUnsigned(64);
      if (midKey == key) {
        final pgMove = _bd.getUint16(mid * 16 + 8, Endian.big);
        final weight = _bd.getInt16(mid * 16 + 10, Endian.big);
        final learn = _bd.getUint32(mid * 16 + 12, Endian.big);
        return PolyglotEntry(
          key: key,
          pgMove: pgMove,
          weight: weight,
          learn: learn,
        );
      } else if (midKey < key) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return null;
  }
}
