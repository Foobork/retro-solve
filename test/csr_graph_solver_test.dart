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

  test('CsrGraphSolver propagates assigned_cp 0 (0.00 / draw) and does not treat 0 as null', () async {
    final dbService = DatabaseService.instance;

    // Black to move has two choices:
    // Move A: cp = 0 (0.00 / draw)
    // Move B: cp = 76 (+0.76 for White, bad for Black)
    const parentBfen = '8/7Q/q1k2K2/8/8/8/1rNnNBR1/1rbn1BR1 b - -'; // Kf6 position
    const move0Bfen = 'child_move_0 w - -';
    const move76Bfen = 'child_move_76 w - -';

    dbService.upsertNode(parentBfen, null, null);
    dbService.upsertNode(move0Bfen, const PositionEval(cp: 0), null);
    dbService.upsertNode(move76Bfen, const PositionEval(cp: 76), null);

    dbService.upsertEdge(parentBfen, move0Bfen);
    dbService.upsertEdge(parentBfen, move76Bfen);
    await dbService.flush();

    await dbService.solveGlobalCsr();

    final parentRow = await dbService.getNode(parentBfen);
    expect(parentRow, isNotNull);
    // Black should prefer cp = 0 over cp = +76
    expect(parentRow!['computed_cp'], equals(0));
    expect(parentRow['computed_result'], isNull);

    final move0Row = await dbService.getNode(move0Bfen);
    // Position with assigned_cp = 0 should have computed_cp = 0 persisted
    expect(move0Row!['computed_cp'], equals(0));
  });

  test('CsrGraphSolver root with White to move chooses between moves leading to 0 correctly', () async {
    final dbService = DatabaseService.instance;

    const rootBfen = '8/7Q/q1k5/4K3/8/8/1rNnNBR1/1rbn1BR1 w - -';
    const kf6Bfen = '8/7Q/q1k2K2/8/8/8/1rNnNBR1/1rbn1BR1 b - -';
    const rg8Bfen = '8/7Q/q1k5/4K3/8/8/1rNnNBR1/1rbn1BRR b - -';

    const kf6Child0 = 'kf6_child_0 w - -';
    const kf6Child76 = 'kf6_child_76 w - -';
    const rg8Child0 = 'rg8_child_0 w - -';

    dbService.upsertNode(rootBfen, null, null);
    dbService.upsertNode(kf6Bfen, null, null);
    dbService.upsertNode(rg8Bfen, null, null);

    dbService.upsertNode(kf6Child0, const PositionEval(cp: 0), null);
    dbService.upsertNode(kf6Child76, const PositionEval(cp: 76), null);
    dbService.upsertNode(rg8Child0, const PositionEval(cp: 0), null);

    dbService.upsertEdge(rootBfen, kf6Bfen);
    dbService.upsertEdge(rootBfen, rg8Bfen);

    dbService.upsertEdge(kf6Bfen, kf6Child0);
    dbService.upsertEdge(kf6Bfen, kf6Child76);

    dbService.upsertEdge(rg8Bfen, rg8Child0);
    await dbService.flush();

    await dbService.solveGlobalCsr();

    final kf6Row = await dbService.getNode(kf6Bfen);
    expect(kf6Row!['computed_cp'], equals(0));

    final rootRow = await dbService.getNode(rootBfen);
    expect(rootRow!['computed_cp'], equals(0));
  });

  test('CsrGraphSolver does not mark position as lost if unrated alternatives exist', () async {
    final dbService = DatabaseService.instance;

    // Black to move has two choices:
    // Move A: loss (White win in 1)
    // Move B: unrated alternative
    const parentBfen = 'rnbqkbnr/ppp1pppp/3p4/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq -';
    const losingChildBfen = 'losing_child w - -';
    const unratedChildBfen = 'unrated_child w - -';

    dbService.upsertNode(parentBfen, null, null);
    dbService.upsertNode(
      losingChildBfen,
      const PositionEval(result: GameResult.whiteWins, dtw: 1),
      null,
    );
    dbService.upsertNode(unratedChildBfen, null, null);

    dbService.upsertEdge(parentBfen, losingChildBfen);
    dbService.upsertEdge(parentBfen, unratedChildBfen);
    await dbService.flush();

    await dbService.solveGlobalCsr();

    final parentRow = await dbService.getNode(parentBfen);
    expect(parentRow!['computed_result'], isNull);
    expect(parentRow['computed_dtw'], isNull);
  });

  test('CsrGraphSolver marks position as lost when ALL alternatives are proven losses', () async {
    final dbService = DatabaseService.instance;

    // Black to move has two choices:
    // Move A: loss (White win in 1)
    // Move B: loss (White win in 3)
    const parentBfen = 'rnbqkbnr/ppp1pppp/3p4/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq -';
    const losingChild1 = 'losing_child_1 w - -';
    const losingChild2 = 'losing_child_2 w - -';

    dbService.upsertNode(parentBfen, null, null);
    dbService.upsertNode(
      losingChild1,
      const PositionEval(result: GameResult.whiteWins, dtw: 1),
      null,
    );
    dbService.upsertNode(
      losingChild2,
      const PositionEval(result: GameResult.whiteWins, dtw: 3),
      null,
    );

    dbService.upsertEdge(parentBfen, losingChild1);
    dbService.upsertEdge(parentBfen, losingChild2);
    await dbService.flush();

    await dbService.solveGlobalCsr();

    final parentRow = await dbService.getNode(parentBfen);
    // Black is forced to lose, choosing the move that delays loss (dtw: 3 + 1 = 4)
    expect(parentRow!['computed_result'], equals(GameResult.whiteWins.value));
    expect(parentRow['computed_dtw'], equals(4));
  });
}

