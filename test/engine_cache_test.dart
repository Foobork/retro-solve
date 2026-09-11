import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/engine_service.dart';
import 'package:test/test.dart';

void main() {
  group('EngineCache Key Canonicalization', () {
    test('strips halfmove and fullmove counters from standard 6-token FEN', () {
      final key1 = EngineCache.canonicalKey(
        DatasetVariant.standard,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
      final key2 = EngineCache.canonicalKey(
        DatasetVariant.standard,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 4 12',
      );
      expect(key1, equals('standard:rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -'));
      expect(key1, equals(key2));
    });

    test('handles BFEN with 4 tokens', () {
      final keyBfen = EngineCache.canonicalKey(
        DatasetVariant.standard,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -',
      );
      final keyFen = EngineCache.canonicalKey(
        DatasetVariant.standard,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
      expect(keyBfen, equals(keyFen));
    });

    test('preserves 3-check check counts while stripping move counters', () {
      final key1 = EngineCache.canonicalKey(
        DatasetVariant.threeCheck,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - +3+3 0 1',
      );
      final key2 = EngineCache.canonicalKey(
        DatasetVariant.threeCheck,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - +3+3 2 5',
      );
      expect(key1, equals('threeCheck:rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - +3+3'));
      expect(key1, equals(key2));
    });

    test('different variants produce distinct keys for identical board state', () {
      final kothKey = EngineCache.canonicalKey(
        DatasetVariant.koth,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
      final standardKey = EngineCache.canonicalKey(
        DatasetVariant.standard,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
      expect(kothKey, isNot(equals(standardKey)));
    });
  });

  group('EngineCache Storage and Retrieval', () {
    late EngineCache cache;

    setUp(() {
      cache = EngineCache(maxEntries: 3, minCacheDepth: 12);
    });

    test('stores and retrieves evaluations meeting minDepth', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
      final evals = [
        const EngineEvaluation(
          depth: 16,
          centipawns: 25,
          candidateMove: 'e7e5',
          multipv: 1,
        ),
      ];

      cache.put(DatasetVariant.standard, fen, evals);
      expect(cache.size, equals(1));

      final retrieved = cache.get(DatasetVariant.standard, fen, minDepth: 16);
      expect(retrieved, isNotNull);
      expect(retrieved!.first.candidateMove, equals('e7e5'));
      expect(retrieved.first.depth, equals(16));
    });

    test('ignores evaluations below minCacheDepth without mate', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
      final evals = [
        const EngineEvaluation(
          depth: 5,
          centipawns: 25,
          candidateMove: 'e7e5',
        ),
      ];

      cache.put(DatasetVariant.standard, fen, evals);
      expect(cache.size, equals(0));
      expect(cache.get(DatasetVariant.standard, fen, minDepth: 5), isNull);
    });

    test('caches forced mate even if depth is below minCacheDepth', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      final evals = [
        const EngineEvaluation(
          depth: 2,
          mate: 1,
          candidateMove: 'Qh5',
        ),
      ];

      cache.put(DatasetVariant.standard, fen, evals);
      expect(cache.size, equals(1));

      final retrieved = cache.get(DatasetVariant.standard, fen, minDepth: 16);
      expect(retrieved, isNotNull);
      expect(retrieved!.first.mate, equals(1));
    });

    test('returns null if cached depth is shallower than requested minDepth', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
      final evals = [
        const EngineEvaluation(
          depth: 13,
          centipawns: 30,
          candidateMove: 'e7e5',
        ),
      ];

      cache.put(DatasetVariant.standard, fen, evals);
      expect(cache.get(DatasetVariant.standard, fen, minDepth: 16), isNull);
      expect(cache.get(DatasetVariant.standard, fen, minDepth: 13), isNotNull);
    });

    test('upgrades shallower evaluation with deeper evaluation but rejects downgrades', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
      final evalDepth13 = [
        const EngineEvaluation(depth: 13, centipawns: 30, candidateMove: 'c7c5'),
      ];
      final evalDepth16 = [
        const EngineEvaluation(depth: 16, centipawns: 35, candidateMove: 'e7e5'),
      ];
      final evalDepth12 = [
        const EngineEvaluation(depth: 12, centipawns: 10, candidateMove: 'd7d5'),
      ];

      cache.put(DatasetVariant.standard, fen, evalDepth13);
      expect(cache.get(DatasetVariant.standard, fen, minDepth: 13)!.first.candidateMove, equals('c7c5'));

      // Upgrade to 16
      cache.put(DatasetVariant.standard, fen, evalDepth16);
      expect(cache.get(DatasetVariant.standard, fen, minDepth: 16)!.first.candidateMove, equals('e7e5'));

      // Downgrade attempt to 12 should be rejected
      cache.put(DatasetVariant.standard, fen, evalDepth12);
      expect(cache.get(DatasetVariant.standard, fen, minDepth: 16)!.first.candidateMove, equals('e7e5'));
    });

    test('upgrades shallower mate evaluation with deeper mate evaluation and rejects downgrades', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      final mateDepth11 = [
        const EngineEvaluation(depth: 11, mate: 18, candidateMove: 'g1e2'),
      ];
      final mateDepth16 = [
        const EngineEvaluation(depth: 16, mate: 18, candidateMove: 'g1e2'),
      ];

      cache.put(DatasetVariant.antichess, fen, mateDepth11);
      expect(cache.get(DatasetVariant.antichess, fen)!.first.depth, equals(11));

      // Deeper mate at depth 16 should upgrade depth 11
      cache.put(DatasetVariant.antichess, fen, mateDepth16);
      expect(cache.get(DatasetVariant.antichess, fen)!.first.depth, equals(16));

      // Shallower mate at depth 11 should be rejected
      cache.put(DatasetVariant.antichess, fen, mateDepth11);
      expect(cache.get(DatasetVariant.antichess, fen)!.first.depth, equals(16));
    });

    test('evicts least recently used entry when maxEntries exceeded', () {
      cache = EngineCache(maxEntries: 2, minCacheDepth: 12);
      const pos1 = '8/8/8/8/8/8/8/K1k5 w - - 0 1';
      const pos2 = '8/8/8/8/8/8/8/K2k4 w - - 0 1';
      const pos3 = '8/8/8/8/8/8/8/K3k3 w - - 0 1';

      cache.put(DatasetVariant.standard, pos1, [const EngineEvaluation(depth: 16, mate: 1)]);
      cache.put(DatasetVariant.standard, pos2, [const EngineEvaluation(depth: 16, mate: 2)]);
      expect(cache.size, equals(2));

      // Access pos1 so pos2 becomes LRU
      expect(cache.get(DatasetVariant.standard, pos1), isNotNull);

      // Add pos3 -> pos2 should be evicted
      cache.put(DatasetVariant.standard, pos3, [const EngineEvaluation(depth: 16, mate: 3)]);
      expect(cache.size, equals(2));
      expect(cache.get(DatasetVariant.standard, pos1), isNotNull);
      expect(cache.get(DatasetVariant.standard, pos2), isNull);
      expect(cache.get(DatasetVariant.standard, pos3), isNotNull);
    });

    test('clearVariant removes only targeted variant entries', () {
      const pos1 = '8/8/8/8/8/8/8/K1k5 w - - 0 1';
      cache.put(DatasetVariant.standard, pos1, [const EngineEvaluation(depth: 16, mate: 1)]);
      cache.put(DatasetVariant.koth, pos1, [const EngineEvaluation(depth: 16, mate: 1)]);
      expect(cache.size, equals(2));

      cache.clearVariant(DatasetVariant.standard);
      expect(cache.size, equals(1));
      expect(cache.get(DatasetVariant.standard, pos1), isNull);
      expect(cache.get(DatasetVariant.koth, pos1), isNotNull);
    });

    test('rejects caching candidate moves that do not match side to move in FEN', () {
      const blackToMoveFen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
      // Attempt to cache White moves (e2e4, g1f3) when it's Black's turn
      final corruptedEvals = [
        const EngineEvaluation(
          depth: 16,
          centipawns: 30,
          candidateMove: 'e2e4',
        ),
      ];

      cache.put(DatasetVariant.standard, blackToMoveFen, corruptedEvals);
      expect(cache.size, equals(0));
      expect(cache.get(DatasetVariant.standard, blackToMoveFen), isNull);

      // Now cache legitimate Black moves
      final validEvals = [
        const EngineEvaluation(
          depth: 16,
          centipawns: -30,
          candidateMove: 'e7e5',
        ),
      ];
      cache.put(DatasetVariant.standard, blackToMoveFen, validEvals);
      expect(cache.size, equals(1));
      expect(cache.get(DatasetVariant.standard, blackToMoveFen), isNotNull);
      expect(cache.get(DatasetVariant.standard, blackToMoveFen)!.first.candidateMove, equals('e7e5'));
    });
  });

  group('EngineCache.isMoveColorConsistentWithFen', () {
    const rootFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    const blackFen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

    test('accepts White moves when White to move', () {
      expect(EngineCache.isMoveColorConsistentWithFen(rootFen, 'e2e4'), isTrue);
      expect(EngineCache.isMoveColorConsistentWithFen(rootFen, 'g1f3'), isTrue);
      expect(EngineCache.isMoveColorConsistentWithFen(rootFen, 'd2d4'), isTrue);
      expect(EngineCache.isMoveColorConsistentWithFen(rootFen, 'b1c3'), isTrue);
    });

    test('rejects Black moves when White to move', () {
      expect(EngineCache.isMoveColorConsistentWithFen(rootFen, 'e7e5'), isFalse);
      expect(EngineCache.isMoveColorConsistentWithFen(rootFen, 'g8f6'), isFalse);
    });

    test('accepts Black moves when Black to move', () {
      expect(EngineCache.isMoveColorConsistentWithFen(blackFen, 'e7e5'), isTrue);
      expect(EngineCache.isMoveColorConsistentWithFen(blackFen, 'c7c5'), isTrue);
      expect(EngineCache.isMoveColorConsistentWithFen(blackFen, 'g8f6'), isTrue);
    });

    test('rejects White moves when Black to move', () {
      // e2 is empty now (pawn moved to e4)
      expect(EngineCache.isMoveColorConsistentWithFen(blackFen, 'e2e4'), isFalse);
      // g1 has White knight
      expect(EngineCache.isMoveColorConsistentWithFen(blackFen, 'g1f3'), isFalse);
      // d2 has White pawn
      expect(EngineCache.isMoveColorConsistentWithFen(blackFen, 'd2d4'), isFalse);
    });

    test('handles crazyhouse drops correctly based on piece case', () {
      const chWhiteFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
      const chBlackFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] b KQkq - 0 1';

      expect(EngineCache.isMoveColorConsistentWithFen(chWhiteFen, 'P@e4'), isTrue);
      expect(EngineCache.isMoveColorConsistentWithFen(chWhiteFen, 'p@e4'), isFalse);

      expect(EngineCache.isMoveColorConsistentWithFen(chBlackFen, 'p@e5'), isTrue);
      expect(EngineCache.isMoveColorConsistentWithFen(chBlackFen, 'P@e5'), isFalse);
    });
  });
}
