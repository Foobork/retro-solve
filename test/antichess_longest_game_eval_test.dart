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

  test('Check aligned DTWs on key checkpoints of 79-move game', () async {
    final graph = CachedGraph();

    // Checkpoint 1: 49. cxb4 (before) -> DTW=62, Pos=+M31
    final v49 = await graph.loadVertex('8/1k2P3/1p2K3/8/1n6/P1P5/8/8 w - -');
    expect(v49?.effectiveEval?.dtw, equals(62));
    expect(v49?.effectiveEval?.format(), equals('+M31'));

    // Checkpoint 2: 49... Kb8 (before) -> DTW=61, Pos=+M31
    final v49b = await graph.loadVertex('8/1k2P3/1p2K3/8/1P6/P7/8/8 b - -');
    expect(v49b?.effectiveEval?.dtw, equals(61));
    expect(v49b?.effectiveEval?.format(), equals('+M31'));

    // Checkpoint 3: 50. b5 (before) -> DTW=60, Pos=+M30
    final v50 = await graph.loadVertex('1k6/4P3/1p2K3/8/1P6/P7/8/8 w - -');
    expect(v50?.effectiveEval?.dtw, equals(60));
    expect(v50?.effectiveEval?.format(), equals('+M30'));

    // Checkpoint 4: 50... Kb7 (before) -> DTW=59, Pos=+M30
    final v50b = await graph.loadVertex('1k6/4P3/1p2K3/1P6/8/P7/8/8 b - -');
    expect(v50b?.effectiveEval?.dtw, equals(59));
    expect(v50b?.effectiveEval?.format(), equals('+M30'));

    // Checkpoint 6: 2. Bb5 (before) -> DTW=156, Pos=+M78
    final v2 = await graph.loadVertex('rnbqkbnr/pp1ppppp/8/2p5/8/4P3/PPPP1PPP/RNBQKBNR w - -');
    expect(v2?.effectiveEval?.dtw, equals(156));
    expect(v2?.effectiveEval?.format(), equals('+M78'));

    // Checkpoint 7: 79. Rf8 (before) -> DTW=2, Pos=+M1
    final v79 = await graph.loadVertex('6k1/8/5R2/8/8/8/8/8 w - -');
    expect(v79?.effectiveEval?.dtw, equals(2));
    expect(v79?.effectiveEval?.format(), equals('+M1'));

    // Checkpoint 8: 79... Kxf8 (before) -> DTW=1, Pos=+M1
    final v79b = await graph.loadVertex('5Rk1/8/8/8/8/8/8/8 b - -');
    expect(v79b?.effectiveEval?.dtw, equals(1));
    expect(v79b?.effectiveEval?.format(), equals('+M1'));
  });
}
