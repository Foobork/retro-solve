import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/graph/csr_graph_solver.dart';
import 'package:retro_solve/graph/position_eval.dart';
import 'package:retro_solve/persistence/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rs_csr_test_');
    dbPath = '${tempDir.path}/csr_test.db';
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

  test('CsrGraphSolver solves directed lines in SQLite directly', () async {
    final dbService = DatabaseService.instance;

    const rootBfen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
    const move1Bfen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
    const mateBfen = 'terminal_mate w - -';

    dbService.upsertNode(rootBfen, null, null);
    dbService.upsertNode(move1Bfen, null, null);
    dbService.upsertNode(mateBfen, const PositionEval(result: GameResult.whiteWins, dtw: 0), null);

    dbService.upsertEdge(rootBfen, move1Bfen);
    dbService.upsertEdge(move1Bfen, mateBfen);
    await dbService.flush();

    final result = await dbService.solveGlobalCsr();

    expect(result.totalPositions, equals(3));
    expect(result.totalEdges, equals(2));
    expect(result.sccCount, equals(3));
    expect(result.updatedPositions, equals(3)); // root, move1, and terminal computed

    // Verify persisted rows in SQLite
    final updatedMove1 = await dbService.getNode(move1Bfen);
    expect(updatedMove1!['computed_result'], equals(GameResult.whiteWins.value));
    expect(updatedMove1['computed_dtw'], equals(1));

    final updatedRoot = await dbService.getNode(rootBfen);
    expect(updatedRoot!['computed_result'], equals(GameResult.whiteWins.value));
    expect(updatedRoot['computed_dtw'], equals(2));
  });

  test('CsrGraphSolver leaves cycles without forced wins as unproven (computed_result null)', () async {
    final dbService = DatabaseService.instance;

    const cycleNodeA = 'cycle_a w - -';
    const cycleNodeB = 'cycle_b b - -';

    dbService.upsertNode(cycleNodeA, null, null);
    dbService.upsertNode(cycleNodeB, null, null);
    dbService.upsertEdge(cycleNodeA, cycleNodeB);
    dbService.upsertEdge(cycleNodeB, cycleNodeA);
    await dbService.flush();

    final result = await dbService.solveGlobalCsr();

    expect(result.sccCount, equals(1)); // 2-node cycle = 1 SCC

    final nodeA = await dbService.getNode(cycleNodeA);
    expect(nodeA!['computed_result'], isNull);

    final nodeB = await dbService.getNode(cycleNodeB);
    expect(nodeB!['computed_result'], isNull);
  });

  test('CsrGraphSolver runs in background isolate with progress callbacks', () async {
    final dbService = DatabaseService.instance;

    const rootBfen = 'iso_root w - -';
    const childBfen = 'iso_child b - -';

    dbService.upsertNode(rootBfen, null, null);
    dbService.upsertNode(childBfen, const PositionEval(result: GameResult.blackWins, dtw: 0), null);
    dbService.upsertEdge(rootBfen, childBfen);
    await dbService.flush();
    await dbService.close(); // Close so isolate can open SQLite cleanly

    final progressUpdates = <String>[];
    final result = await CsrGraphSolver.solveInIsolate(
      dbPath,
      onProgress: (progress, status) {
        progressUpdates.add('$progress: $status');
      },
    );

    expect(result.totalPositions, equals(2));
    expect(result.totalEdges, equals(1));
    expect(result.updatedPositions, equals(2));
    expect(progressUpdates.isNotEmpty, isTrue);

    // Reopen to verify persisted value
    await dbService.init(dbPath);
    final rootRow = await dbService.getNode(rootBfen);
    expect(rootRow!['computed_result'], equals(GameResult.blackWins.value));
    expect(rootRow['computed_dtw'], equals(1));
  });

  test('CsrGraphSolver propagates decisive result without fabricating DTW when DTW is null', () async {
    final dbService = DatabaseService.instance;

    const parentBfen = '8/p1p5/5K2/8/2k5/8/8/1r6 b - -';
    const childBfen = '8/2p5/p4K2/8/2k5/8/8/1r6 w - -';

    dbService.upsertNode(parentBfen, const PositionEval(cp: -122), null);
    dbService.upsertNode(
      childBfen,
      const PositionEval(result: GameResult.blackWins),
      null,
    );
    dbService.upsertEdge(parentBfen, childBfen);
    await dbService.flush();

    await dbService.solveGlobalCsr();

    final parentRow = await dbService.getNode(parentBfen);
    expect(parentRow!['computed_result'], equals(GameResult.blackWins.value));
    expect(parentRow['computed_dtw'], isNull);
  });
}
