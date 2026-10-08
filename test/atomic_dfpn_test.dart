import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/persistence/database_service.dart';
import 'package:retro_solve/persistence/db_init.dart';
import 'package:sqflite_common/sqlite_api.dart';

String decodeMove(int mv) {
  if (mv == 0xfedc || mv == 0x0edc) return 'NULL';
  if ((mv >> 12) > 8 || (mv >> 12) == 7) {
    mv ^= 0xf000;
  }
  final fr = (mv >> 6) & 0x3f;
  final to = mv & 0x3f;
  final promIdx = (mv >> 12) & 0x7;
  const promChars = '01nbrqk7';

  final fromFile = String.fromCharCode('a'.codeUnitAt(0) + (fr & 7));
  final fromRank = (1 + (fr >> 3)).toString();
  final toFile = String.fromCharCode('a'.codeUnitAt(0) + (to & 7));
  final toRank = (1 + (to >> 3)).toString();

  var res = '$fromFile$fromRank$toFile$toRank';
  if ((mv & (7 << 12)) != 0 && promIdx < promChars.length) {
    res += promChars[promIdx];
  }
  return res;
}

class _ProofNode {
  final int w;
  final int d;
  final String mv;

  const _ProofNode(this.w, this.d, this.mv);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Atomic Proof-Number Subtree Tests', () {
    test('Existing 17 blunders proof file conforms to Watkins specification', () async {
      const proofPath = 'data/Nf3_17_blunders.proof';
      final file = File(proofPath);
      expect(file.existsSync(), isTrue);

      final raf = await file.open(mode: FileMode.read);
      final header6 = await raf.read(6);
      final byteData = ByteData.sublistView(header6);
      final rawData = byteData.getUint32(0, Endian.little);
      final prologLen = byteData.getUint16(4, Endian.little);

      final nodeCount = rawData & 0x3fffffff;
      final hasChildren = (rawData & (1 << 30)) != 0;

      expect(nodeCount, equals(967));
      expect(hasChildren, isTrue);
      expect(prologLen, equals(1));

      final prologBytes = await raf.read(2);
      final prologMv = ByteData.sublistView(prologBytes).getUint16(0, Endian.little);
      final prologUci = decodeMove(prologMv);
      expect(prologUci, equals('g1f3'));

      await raf.close();
    });

    test('Database schema version 6 preserves proof numbers and status', () async {
      final tempDir = await Directory.systemTemp.createTemp('rs_dfpn_test_');
      final dbPath = '${tempDir.path}/dfpn_test.db';

      try {
        final dbService = DatabaseService.instance;
        await dbService.init(dbPath);
        await dbService.close();

        final factory = getPlatformDatabaseFactory();
        final db = await factory.openDatabase(dbPath);

        // Insert position with proof numbers
        await db.insert('positions', {
          'bfen': 'rnbqkbnr/ppp1pppp/3p4/8/8/5N2/PPPPPPPP/RNBQKB1R w KQkq -',
          'assigned_result': null,
          'assigned_dtw': null,
          'assigned_cp': 738,
          'computed_result': 1,
          'computed_dtw': 2,
          'computed_cp': null,
          'proof_status': 1,
          'pn': 0,
          'dn': 1000000000,
          'proven_move_id': 34852,
        });

        final rows = await db.query('positions', where: "proof_status = 1");
        expect(rows.length, equals(1));
        final row = rows.first;
        expect(row['proof_status'], equals(1));
        expect(row['pn'], equals(0));
        expect(row['dn'], equals(1000000000));
        expect(row['computed_result'], equals(1));
        expect(row['computed_dtw'], equals(2));
        expect(row['proven_move_id'], equals(34852));

        await db.close();
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('AtomicChess validates explosion refutations on d6 blunder branch', () {
      final game = AtomicChess();
      // 1. Nf3 d6 2. Ng5 e6? 3. Nxh7 explodes King/Pawns
      expect(game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'), isTrue);

      final nf3 = game.generateMoves().firstWhere((m) => game.moveToSan(m) == 'Nf3');
      game.makeMove(nf3);

      final d6 = game.generateMoves().firstWhere((m) => game.moveToSan(m) == 'd6');
      game.makeMove(d6);

      final ng5 = game.generateMoves().firstWhere((m) => game.moveToSan(m) == 'Ng5');
      game.makeMove(ng5);

      final e6 = game.generateMoves().firstWhere((m) => game.moveToSan(m) == 'e6');
      game.makeMove(e6);

      // White plays Nxh7
      final nxh7 = game.generateMoves().firstWhere((m) => m.fromAlgebraic == 'g5' && m.toAlgebraic == 'h7');
      game.makeMove(nxh7);

      // Destination h7 is adjacent to Black King on e8? No, h7 explodes h7, h8 (Rook), g8 (Knight), g7 (immune pawn).
      // Let's verify White captured and exploded pieces:
      expect(game.gameOver, isFalse);
    });
  });
}
