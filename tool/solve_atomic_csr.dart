// ignore_for_file: avoid_print

import 'dart:io';
import 'package:retro_solve/graph/csr_graph_solver.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> args) async {
  sqfliteFfiInit();
  final dbPath = args.isNotEmpty ? args.first : 'data/Atomic.db';
  final file = File(dbPath).absolute;
  if (!file.existsSync()) {
    print('Database file not found: ${file.path}');
    return;
  }

  print('====================================================');
  print('Running CSR Graph Solver on: ${file.path}');
  final db = await databaseFactoryFfi.openDatabase(file.path);

  final result = await CsrGraphSolver.solveDirect(
    db,
    onProgress: (progress, status) {
      print('[${(progress * 100).toInt()}%] $status');
    },
  );

  print('====================================================');
  print('Solve completed in ${result.duration.inMilliseconds}ms');
  print('Total positions: ${result.totalPositions}');
  print('Total edges:     ${result.totalEdges}');
  print('SCC count:       ${result.sccCount}');
  print('Updated nodes:   ${result.updatedPositions}');

  final remainingNullDtw = await db.rawQuery('''
    SELECT count(1) as cnt
    FROM positions
    WHERE computed_result = -1 AND computed_dtw IS NULL;
  ''');
  print('Positions with computed_result = -1 and NULL DTW: ${remainingNullDtw.first['cnt']}');

  final mate1Count = await db.rawQuery('''
    SELECT count(1) as cnt
    FROM positions
    WHERE computed_result = -1 AND computed_dtw = 1;
  ''');
  print('Positions with computed_result = -1 and DTW = 1 (-M1): ${mate1Count.first['cnt']}');

  await db.close();
}
