import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/persistence/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('Backsolve propagates in-memory evaluations', () {
    resetGraph(useCache: false);
    final game = AntichessChess();
    game.load('2k2b2/p1p2p2/2p5/8/P7/8/1p5r/5K2 w - - 0 1');

    final rootBfen = game.bfen;
    for (var move in game.generateMoves()) {
      game.makeMove(move);
      graph.addLink(rootBfen, game.bfen);
      game.undo();
    }

    // White plays Ke1
    game.move('Ke1');
    final ke1Bfen = game.bfen;
    for (var move in game.generateMoves()) {
      game.makeMove(move);
      graph.addLink(ke1Bfen, game.bfen);
      game.undo();
    }

    // Engine evaluates ke1Bfen to -2.30 (White perspective: cp = -230)
    graph.assign(ke1Bfen, const PositionEval(cp: -230));
    graph.solveBfen(ke1Bfen);

    // Black plays Kd7
    game.move('Kd7');
    final kd7Bfen = game.bfen;
    for (var move in game.generateMoves()) {
      game.makeMove(move);
      graph.addLink(kd7Bfen, game.bfen);
      game.undo();
    }

    // Engine evaluates kd7Bfen to -4.61 (White perspective: cp = -461)
    graph.assign(kd7Bfen, const PositionEval(cp: -461));
    graph.solveBfen(kd7Bfen);

    expect(graph.v[kd7Bfen]?.effectiveEval?.format(), '-4.61');
    expect(graph.v[ke1Bfen]?.effectiveEval?.format(), '-4.61');
    expect(graph.v[rootBfen]?.effectiveEval?.format(), '-4.61');
  });

  test('Backsolve propagates through CachedGraph + SQLite', () async {
    final db = DatabaseService.instance;
    await db.init(inMemoryDatabasePath);

    resetGraph(useCache: true);
    graph.onNodeUpdated = (bfen, assigned, computed) {
      db.upsertNode(bfen, assigned, computed);
    };
    graph.onEdgeAdded = (source, target) {
      db.upsertEdge(source, target);
    };

    final game = AntichessChess();
    game.load('2k2b2/p1p2p2/2p5/8/P7/8/1p5r/5K2 w - - 0 1');

    final rootBfen = game.bfen;
    for (var move in game.generateMoves()) {
      game.makeMove(move);
      graph.addLink(rootBfen, game.bfen);
      game.undo();
    }
    await (graph as CachedGraph).solveBfenAsync(rootBfen);

    // White plays Ke1
    game.move('Ke1');
    final ke1Bfen = game.bfen;
    for (var move in game.generateMoves()) {
      game.makeMove(move);
      graph.addLink(ke1Bfen, game.bfen);
      game.undo();
    }
    graph.assign(ke1Bfen, const PositionEval(cp: -230));
    await (graph as CachedGraph).solveBfenAsync(ke1Bfen);

    // Black plays Kd7
    game.move('Kd7');
    final kd7Bfen = game.bfen;
    for (var move in game.generateMoves()) {
      game.makeMove(move);
      graph.addLink(kd7Bfen, game.bfen);
      game.undo();
    }
    graph.assign(kd7Bfen, const PositionEval(cp: -461));
    await (graph as CachedGraph).solveBfenAsync(kd7Bfen);

    expect(graph.v[kd7Bfen]?.effectiveEval?.format(), '-4.61');
    expect(graph.v[ke1Bfen]?.effectiveEval?.format(), '-4.61');
    expect(graph.v[rootBfen]?.effectiveEval?.format(), '-4.61');

    await db.close();
  });

  test('Global solve via solveGlobal updates CachedGraph and SQLite database', () async {
    final db = DatabaseService.instance;
    await db.init(inMemoryDatabasePath);

    final game = AntichessChess();
    game.load('2k2b2/p1p2p2/2p5/8/P7/8/1p5r/5K2 w - - 0 1');
    final rootBfen = game.bfen;
    game.move('Ke1');
    final ke1Bfen = game.bfen;
    game.move('Kd7');
    final kd7Bfen = game.bfen;

    // Populate DB directly as if from previous session or import
    await db.upsertNode(rootBfen, null, null);
    await db.upsertNode(ke1Bfen, const PositionEval(cp: -230), null);
    await db.upsertNode(kd7Bfen, const PositionEval(cp: -461), null);
    await db.upsertEdge(rootBfen, ke1Bfen);
    await db.upsertEdge(ke1Bfen, kd7Bfen);
    await db.flush();

    resetGraph(useCache: true);
    graph.onNodeUpdated = (bfen, assigned, computed) {
      db.upsertNode(bfen, assigned, computed);
    };
    graph.onEdgeAdded = (source, target) {
      db.upsertEdge(source, target);
    };

    // User is at root
    await (graph as CachedGraph).prefetchPositionAndMoves(rootBfen, [ke1Bfen]);
    expect(graph.v[ke1Bfen]?.effectiveEval?.format(), '-2.30');

    // User triggers Solve
    await (graph as CachedGraph).solveGlobal();

    expect(graph.v[ke1Bfen]?.effectiveEval?.format(), '-4.61');
    expect(graph.v[rootBfen]?.effectiveEval?.format(), '-4.61');

    await db.close();
  });
}
