import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/persistence/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LruMap Unit Tests', () {
    test('LruMap stores and retrieves entries in O(1)', () {
      final map = LruMap<String, int>(capacity: 3);
      map['a'] = 1;
      map['b'] = 2;
      map['c'] = 3;

      expect(map['a'], equals(1));
      expect(map['b'], equals(2));
      expect(map['c'], equals(3));
      expect(map.length, equals(3));
    });

    test('LruMap evicts least recently used entry when capacity is exceeded', () {
      final map = LruMap<String, int>(capacity: 3);
      map['a'] = 1;
      map['b'] = 2;
      map['c'] = 3;

      // Access 'a' to promote it to most recently used
      final _ = map['a'];

      // Insert 'd', which should evict 'b' (the oldest untouched entry)
      map['d'] = 4;

      expect(map.containsKey('b'), isFalse);
      expect(map['a'], equals(1));
      expect(map['c'], equals(3));
      expect(map['d'], equals(4));
      expect(map.length, equals(3));
    });

    test('LruMap updates existing key in place and promotes to MRU', () {
      final map = LruMap<String, int>(capacity: 2);
      map['a'] = 1;
      map['b'] = 2;
      map['a'] = 10; // Overwrite 'a'

      map['c'] = 3; // Should evict 'b'

      expect(map.containsKey('b'), isFalse);
      expect(map['a'], equals(10));
      expect(map['c'], equals(3));
    });
  });

  group('CachedGraph & Out-of-Core SQLite Propagation Tests', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rs_cached_graph_test_');
      dbPath = '${tempDir.path}/cached_test.db';
      await DatabaseService.instance.init(dbPath);
    });

    tearDown(() async {
      try {
        await DatabaseService.instance.close();
      } catch (_) {}
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('CachedGraph evicts distant nodes while keeping memory bounded', () {
      final cachedGraph = CachedGraph(cacheCapacity: 10);
      for (int i = 0; i < 25; i++) {
        cachedGraph.addVertex('node_$i w');
      }
      expect(cachedGraph.v.length, equals(10));
      expect(cachedGraph.v.containsKey('node_0 w'), isFalse);
      expect(cachedGraph.v.containsKey('node_24 w'), isTrue);
    });

    test('CachedGraph loadVertex loads evaluations and bidirectional links from SQLite', () async {
      final db = DatabaseService.instance;
      const parentBfen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
      const childBfen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';

      db.upsertNode(parentBfen, null, const PositionEval(cp: 30));
      db.upsertNode(childBfen, const PositionEval(result: GameResult.draw, cp: 0), null);
      db.upsertEdge(parentBfen, childBfen);
      await db.flush();

      // Fresh CachedGraph with empty in-memory cache
      final cachedGraph = CachedGraph(dbService: db, cacheCapacity: 100);
      expect(cachedGraph.v.isEmpty, isTrue);

      final loadedParent = await cachedGraph.loadVertex(parentBfen);
      expect(loadedParent, isNotNull);
      expect(loadedParent!.bfen, equals(parentBfen));
      expect(loadedParent.computed?.cp, equals(30));
      expect(loadedParent.links.contains(childBfen), isTrue);

      final loadedChild = await cachedGraph.loadVertex(childBfen);
      expect(loadedChild, isNotNull);
      expect(loadedChild!.bfen, equals(childBfen));
      expect(loadedChild.assigned?.result, equals(GameResult.draw));
      expect(loadedChild.backLinks.contains(parentBfen), isTrue);
    });

    test('CachedGraph prefetchPositions loads multiple positions in a single batch', () async {
      final db = DatabaseService.instance;
      const bfen1 = 'pos_1 w - -';
      const bfen2 = 'pos_2 b - -';
      const bfen3 = 'pos_3 w - -';

      db.upsertNode(bfen1, const PositionEval(cp: 100), null);
      db.upsertNode(bfen2, const PositionEval(cp: -100), null);
      db.upsertNode(bfen3, const PositionEval(cp: 50), null);
      await db.flush();

      final cachedGraph = CachedGraph(dbService: db, cacheCapacity: 100);
      await cachedGraph.prefetchPositions([bfen1, bfen2, bfen3]);

      expect(cachedGraph.v.length, equals(3));
      expect(cachedGraph.v[bfen1]?.assigned?.cp, equals(100));
      expect(cachedGraph.v[bfen2]?.assigned?.cp, equals(-100));
      expect(cachedGraph.v[bfen3]?.assigned?.cp, equals(50));
    });

    test('solveBfenAsync walks SQLite reverse index (idx_edges_target) across uncached ancestors', () async {
      final db = DatabaseService.instance;

      // Create a 2-ply line in SQLite:
      // Root (White) -> Move1 (Black) -> Move2 (Terminal Win for White: +999.0)
      const rootBfen = 'root w - -';
      const move1Bfen = 'move1 b - -';
      const terminalBfen = 'terminal w - -';

      db.upsertNode(rootBfen, null, null);
      db.upsertNode(move1Bfen, null, null);
      db.upsertNode(terminalBfen, const PositionEval(result: GameResult.whiteWins, dtw: 0), null);

      db.upsertEdge(rootBfen, move1Bfen);
      db.upsertEdge(move1Bfen, terminalBfen);
      await db.flush();

      // Fresh CachedGraph with only terminalBfen in memory (root and move1 are OUT OF CORE in SQLite)
      final cachedGraph = CachedGraph(dbService: db, cacheCapacity: 100);
      await cachedGraph.loadVertex(terminalBfen);

      expect(cachedGraph.v.containsKey(rootBfen), isFalse);
      expect(cachedGraph.v.containsKey(move1Bfen), isFalse);

      // Trigger asynchronous retrograde solve starting from terminal node
      await cachedGraph.solveBfenAsync(terminalBfen);

      // The solver should have discovered ancestors via idx_edges_target
      expect(cachedGraph.v.containsKey(move1Bfen), isTrue);
      expect(cachedGraph.v.containsKey(rootBfen), isTrue);

      // Terminal is White win in 0 plies.
      // move1 (Black to move) must choose move leading to White win in 0 -> Black is losing in 1 ply (dtw: 1)
      expect(cachedGraph.v[move1Bfen]?.computed?.result, equals(GameResult.whiteWins));
      expect(cachedGraph.v[move1Bfen]?.computed?.dtw, equals(1));

      // root (White to move) plays move1 -> White is winning in 2 plies (dtw: 2)
      expect(cachedGraph.v[rootBfen]?.computed?.result, equals(GameResult.whiteWins));
      expect(cachedGraph.v[rootBfen]?.computed?.dtw, equals(2));
    });

    test('prefetchPositions leaves unevaluated frontier nodes with inDatabase=false and null evals', () async {
      final db = DatabaseService.instance;
      const rootBfen = 'root_pos w - -';
      const frontierBfen = 'frontier_pos b - -';

      // Simulate root having an edge to an unevaluated frontier node in SQLite
      db.upsertEdge(rootBfen, frontierBfen);
      await db.flush();

      final cachedGraph = CachedGraph(dbService: db, cacheCapacity: 100);
      await cachedGraph.prefetchPositions([rootBfen, frontierBfen]);

      final frontierVertex = cachedGraph.v[frontierBfen];
      expect(frontierVertex, isNotNull);
      expect(frontierVertex!.inDatabase, isFalse);
      expect(frontierVertex.effectiveEval, isNull);
      expect(frontierVertex.links.isEmpty, isTrue);
    });
  });
}
