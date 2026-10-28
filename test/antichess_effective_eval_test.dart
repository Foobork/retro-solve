import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/graph/cached_graph.dart';
import 'package:retro_solve/persistence/database_service.dart';
import 'package:retro_solve/persistence/db_init.dart';

void main() {
  setUpAll(() async {
    final dbPath = resolvePlatformDbPath('data/Antichess.db');
    await DatabaseService.instance.init(dbPath);
  });

  tearDownAll(() async {
    await DatabaseService.instance.close();
  });

  test('f7 child effectiveEval chooses defender maximum resistance instead of stale shorter assigned', () async {
    final graph = CachedGraph();

    // Position after f7 (Black to move, defending in White win)
    const childBfen = '1r6/2n2P2/1pk5/8/4P3/8/P1PK4/2R5 b - -';
    final vertex = await graph.loadVertex(childBfen);

    expect(vertex, isNotNull);
    expect(vertex!.effectiveEval?.dtw, equals(99));
    expect(vertex.effectiveEval?.format(isMove: true), equals('+M50'));
  });

  test('Parent 1r6/2n5/1pk2P2/8/4P3/8/P1PK4/2R5 w - - has computed DTW=100 (+M50)', () async {
    final graph = CachedGraph();

    const parentBfen = '1r6/2n5/1pk2P2/8/4P3/8/P1PK4/2R5 w - -';
    final vertex = await graph.loadVertex(parentBfen);

    expect(vertex, isNotNull);
    expect(vertex!.effectiveEval?.dtw, equals(100));
    expect(vertex.effectiveEval?.format(isMove: false), equals('+M50'));
  });

  test('f6 child in 1r6/2nk4/1p6/5P2/4P3/8/P1PK4/2R5 w - - evaluates to DTW=101 (+M51)', () async {
    final graph = CachedGraph();

    // Position after f6 (Black to move, child 2601926)
    const childBfen = '1r6/2nk4/1p3P2/8/4P3/8/P1PK4/2R5 b - -';
    final childVertex = await graph.loadVertex(childBfen);

    expect(childVertex, isNotNull);
    expect(childVertex!.effectiveEval?.dtw, equals(101));
    expect(childVertex.effectiveEval?.format(isMove: true), equals('+M51'));

    // Parent position (White to move, parent 2601901)
    const parentBfen = '1r6/2nk4/1p6/5P2/4P3/8/P1PK4/2R5 w - -';
    final parentVertex = await graph.loadVertex(parentBfen);

    expect(parentVertex, isNotNull);
    expect(parentVertex!.effectiveEval?.dtw, equals(102));
    expect(parentVertex.effectiveEval?.format(isMove: false), equals('+M51'));
  });

  test('Position 8/1k2P3/np2K3/8/8/P7/2P1R3/8 b - - has consistent defenses Ka8, Ka7 (+M35) and Kb8 (+M34)', () async {
    final graph = CachedGraph();

    // Ka8
    final vKa8 = await graph.loadVertex('k7/4P3/np2K3/8/8/P7/2P1R3/8 w - -');
    expect(vKa8?.effectiveEval?.dtw, equals(68));
    expect(vKa8?.effectiveEval?.format(isMove: true), equals('+M35'));

    // Ka7
    final vKa7 = await graph.loadVertex('8/k3P3/np2K3/8/8/P7/2P1R3/8 w - -');
    expect(vKa7?.effectiveEval?.dtw, equals(68));
    expect(vKa7?.effectiveEval?.format(isMove: true), equals('+M35'));

    // Kb8
    final vKb8 = await graph.loadVertex('1k6/4P3/np2K3/8/8/P7/2P1R3/8 w - -');
    expect(vKb8?.effectiveEval?.dtw, equals(66));
    expect(vKb8?.effectiveEval?.format(isMove: true), equals('+M34'));

    // Parent
    final vParent = await graph.loadVertex('8/1k2P3/np2K3/8/8/P7/2P1R3/8 b - -');
    expect(vParent?.effectiveEval?.dtw, equals(69));
    expect(vParent?.effectiveEval?.format(isMove: false), equals('+M35'));
  });

  test('Position 8/k7/3K4/1p6/1P1K4/P7/8/8 w - - move K6d5 evaluates consistently to +M13', () async {
    final graph = CachedGraph();

    // Child after K6d5 (Black to move, ID 4787194)
    final vChild = await graph.loadVertex('8/k7/8/1p1K4/1P1K4/P7/8/8 b - -');
    expect(vChild?.effectiveEval?.dtw, equals(25));
    expect(vChild?.effectiveEval?.format(isMove: true), equals('+M13'));

    // Parent (White to move, ID 4787167)
    final vParent = await graph.loadVertex('8/k7/3K4/1p6/1P1K4/P7/8/8 w - -');
    expect(vParent?.effectiveEval?.dtw, equals(26));
    expect(vParent?.effectiveEval?.format(isMove: false), equals('+M13'));
  });

  test('Position k7/8/3K4/1p1K4/1P6/P7/8/8 w - - (pos 57) evaluates consistently to +M15', () async {
    final graph = CachedGraph();

    // Position 57 parent (White to move, ID 4787141)
    const parentBfen = 'k7/8/3K4/1p1K4/1P6/P7/8/8 w - -';
    final vParent = await graph.loadVertex(parentBfen);
    expect(vParent, isNotNull);
    expect(vParent!.effectiveEval?.dtw, equals(30));
    expect(vParent.effectiveEval?.format(isMove: false), equals('+M15'));

    // Move Kd4 child (Black to move, ID 4787159)
    const childBfen = 'k7/8/3K4/1p6/1P1K4/P7/8/8 b - -';
    final vChild = await graph.loadVertex(childBfen);
    expect(vChild, isNotNull);
    expect(vChild!.effectiveEval?.dtw, equals(29));
    expect(vChild.effectiveEval?.format(isMove: true), equals('+M15'));

    // Defenses from child 4787159
    // Kb8 (ID 4787165)
    final vKb8 = await graph.loadVertex('1k6/8/3K4/1p6/1P1K4/P7/8/8 w - -');
    expect(vKb8?.effectiveEval?.dtw, equals(28));
    expect(vKb8?.effectiveEval?.format(isMove: true), equals('+M15'));

    // Ka7 (ID 4787167)
    final vKa7 = await graph.loadVertex('8/k7/3K4/1p6/1P1K4/P7/8/8 w - -');
    expect(vKa7?.effectiveEval?.dtw, equals(26));
    expect(vKa7?.effectiveEval?.format(isMove: true), equals('+M14'));

    // Parent incoming 56... Kd5 (ID 4787127)
    final vIncoming = await graph.loadVertex('8/k7/3K4/1p1K4/1P6/P7/8/8 b - -');
    expect(vIncoming?.effectiveEval?.dtw, equals(31));
    expect(vIncoming?.effectiveEval?.format(isMove: false), equals('+M16'));
  });
}
