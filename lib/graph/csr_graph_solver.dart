import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:sqflite_common/sqlite_api.dart';
import '../persistence/db_init.dart';

/// Result summary returned by [CsrGraphSolver].
class CsrSolveResult {
  final int totalPositions;
  final int totalEdges;
  final int sccCount;
  final int updatedPositions;
  final Duration duration;

  const CsrSolveResult({
    required this.totalPositions,
    required this.totalEdges,
    required this.sccCount,
    required this.updatedPositions,
    required this.duration,
  });

  @override
  String toString() {
    return 'CsrSolveResult(positions: $totalPositions, edges: $totalEdges, SCCs: $sccCount, updated: $updatedPositions, time: ${duration.inMilliseconds}ms)';
  }
}

/// Out-of-core flat typed-memory Tarjan solver.
///
/// Uses Compressed Sparse Row (CSR) flat Int32List arrays to solve arbitrary
/// directed graphs with millions of positions in minimal constant memory (< 1 GB RAM for 133M edges).
class CsrGraphSolver {
  static int _encodeGameResult(int? val) {
    if (val == null) return 0;
    if (val == 1) return 1; // whiteWins
    if (val == 0) return 2; // draw
    if (val == -1) return 3; // blackWins
    return 0;
  }

  static int? _decodeGameResult(int code) {
    if (code == 1) return 1;
    if (code == 2) return 0;
    if (code == 3) return -1;
    return null;
  }

  /// Solves the database at [dbPath] in a background isolate.
  static Future<CsrSolveResult> solveInIsolate(
    String dbPath, {
    void Function(double progress, String status)? onProgress,
  }) async {
    final receivePort = ReceivePort();
    final completer = Completer<CsrSolveResult>();

    final isolate = await Isolate.spawn<_CsrWorkerParams>(
      _workerEntry,
      _CsrWorkerParams(dbPath, receivePort.sendPort),
    );

    receivePort.listen((message) {
      if (message is _CsrProgressMessage) {
        onProgress?.call(message.progress, message.status);
      } else if (message is _CsrResultMessage) {
        completer.complete(message.result);
        receivePort.close();
        isolate.kill();
      } else if (message is _CsrErrorMessage) {
        completer.completeError(Exception(message.error), StackTrace.fromString(message.stackTrace));
        receivePort.close();
        isolate.kill();
      }
    });

    return completer.future;
  }

  /// Solves the database directly in the current isolate (for testing or CLI tools).
  static Future<CsrSolveResult> solveDirect(
    Database db, {
    void Function(double progress, String status)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    onProgress?.call(0.05, 'Scanning graph dimensions...');
    final maxIdRow = await db.rawQuery('SELECT MAX(id) as max_id, COUNT(1) as cnt FROM positions;');
    final maxId = (maxIdRow.first['max_id'] as num?)?.toInt() ?? 0;
    final posCount = (maxIdRow.first['cnt'] as num?)?.toInt() ?? 0;

    final edgeCountRow = await db.rawQuery('SELECT COUNT(1) as cnt FROM edges;');
    final edgeCount = (edgeCountRow.first['cnt'] as num?)?.toInt() ?? 0;

    if (posCount == 0 || edgeCount == 0) {
      return CsrSolveResult(
        totalPositions: posCount,
        totalEdges: edgeCount,
        sccCount: 0,
        updatedPositions: 0,
        duration: stopwatch.elapsed,
      );
    }

    onProgress?.call(0.15, 'Allocating flat typed memory ($posCount nodes, $edgeCount edges)...');
    final rowPtrs = Int32List(maxId + 2);
    final colIndices = Int32List(edgeCount);

    final assignedRes = Int8List(maxId + 1);
    final assignedDtw = Int16List(maxId + 1);
    final assignedDtz = Int16List(maxId + 1);
    final assignedCp = Int16List(maxId + 1);

    final computedRes = Int8List(maxId + 1);
    final computedDtw = Int16List(maxId + 1);
    final computedDtz = Int16List(maxId + 1);
    final computedCp = Int16List(maxId + 1);

    final origComputedRes = Int8List(maxId + 1);
    final origComputedDtw = Int16List(maxId + 1);
    final origComputedDtz = Int16List(maxId + 1);
    final origComputedCp = Int16List(maxId + 1);

    assignedDtw.fillRange(0, maxId + 1, -1);
    computedDtw.fillRange(0, maxId + 1, -1);
    origComputedDtw.fillRange(0, maxId + 1, -1);

    final isWhiteToMove = Uint8List(maxId + 1);
    final pieceCount = Uint8List(maxId + 1);

    onProgress?.call(0.25, 'Loading position metadata...');
    int lastPosId = 0;
    const posBatch = 100000;
    while (true) {
      final rows = await db.rawQuery('''
        SELECT id, bfen, assigned_result, assigned_dtw, assigned_dtz, assigned_cp,
               computed_result, computed_dtw, computed_dtz, computed_cp
        FROM positions
        WHERE id > ?
        ORDER BY id
        LIMIT ?;
      ''', [lastPosId, posBatch]);
      if (rows.isEmpty) break;

      for (final row in rows) {
        final id = row['id'] as int;
        lastPosId = id;

        final aRes = row['assigned_result'] as int?;
        if (aRes != null) assignedRes[id] = _encodeGameResult(aRes);
        final aDtw = row['assigned_dtw'] as int?;
        if (aDtw != null) assignedDtw[id] = aDtw;
        final aDtz = row['assigned_dtz'] as int?;
        if (aDtz != null) assignedDtz[id] = aDtz;
        final aCp = row['assigned_cp'] as int?;
        if (aCp != null) assignedCp[id] = aCp;

        final cRes = row['computed_result'] as int?;
        if (cRes != null) {
          final encoded = _encodeGameResult(cRes);
          computedRes[id] = encoded;
          origComputedRes[id] = encoded;
        }
        final cDtw = row['computed_dtw'] as int?;
        if (cDtw != null) {
          computedDtw[id] = cDtw;
          origComputedDtw[id] = cDtw;
        }
        final cDtz = row['computed_dtz'] as int?;
        if (cDtz != null) {
          computedDtz[id] = cDtz;
          origComputedDtz[id] = cDtz;
        }
        final cCp = row['computed_cp'] as int?;
        if (cCp != null) {
          computedCp[id] = cCp;
          origComputedCp[id] = cCp;
        }

        final bfen = row['bfen'] as String;
        final parts = bfen.split(' ');
        if (parts.length > 1) {
          isWhiteToMove[id] = (parts[1] == 'w') ? 1 : 0;
        } else {
          isWhiteToMove[id] = bfen.contains(' w ') ? 1 : 0;
        }
        final boardPart = parts.isNotEmpty ? parts[0] : bfen;
        pieceCount[id] = boardPart.replaceAll(RegExp(r'[^a-zA-Z]'), '').length;
      }
      if (rows.length < posBatch) break;
    }

    onProgress?.call(0.40, 'Streaming edge transitions into CSR...');
    int edgeIndex = 0;
    int currSource = 0;
    int lastSourceId = 0;
    int lastTargetId = 0;
    const edgeBatch = 200000;

    while (true) {
      List<Map<String, Object?>> rows;
      if (lastSourceId == 0) {
        rows = await db.rawQuery('''
          SELECT source_id, target_id FROM edges
          ORDER BY source_id, target_id
          LIMIT ?;
        ''', [edgeBatch]);
      } else {
        rows = await db.rawQuery('''
          SELECT source_id, target_id FROM edges
          WHERE (source_id > ?) OR (source_id = ? AND target_id > ?)
          ORDER BY source_id, target_id
          LIMIT ?;
        ''', [lastSourceId, lastSourceId, lastTargetId, edgeBatch]);
      }
      if (rows.isEmpty) break;

      for (final row in rows) {
        final s = row['source_id'] as int;
        final t = row['target_id'] as int;
        lastSourceId = s;
        lastTargetId = t;

        while (currSource < s) {
          rowPtrs[++currSource] = edgeIndex;
        }
        if (edgeIndex < colIndices.length) {
          colIndices[edgeIndex++] = t;
        }
      }
      if (rows.length < edgeBatch) break;
    }
    while (currSource <= maxId) {
      rowPtrs[++currSource] = edgeIndex;
    }

    onProgress?.call(0.60, 'Solving strongly connected components (Iterative Tarjan)...');

    // Auxiliary Tarjan arrays
    final indices = Int32List(maxId + 1)..fillRange(0, maxId + 1, -1);
    final lowlinks = Int32List(maxId + 1);
    final onStack = Uint8List(maxId + 1);

    final tarjanStack = Int32List(maxId + 1);
    int stackTop = 0;

    final callNode = Int32List(maxId + 1);
    final callEdge = Int32List(maxId + 1);
    int callTop = 0;

    int currentIndex = 0;
    int sccCount = 0;

    final sccBuffer = Int32List(maxId + 1);

    for (int root = 1; root <= maxId; root++) {
      if (indices[root] != -1) continue;

      callNode[0] = root;
      callEdge[0] = rowPtrs[root];
      indices[root] = lowlinks[root] = currentIndex++;
      tarjanStack[stackTop++] = root;
      onStack[root] = 1;
      callTop = 1;

      while (callTop > 0) {
        final v = callNode[callTop - 1];
        final edgeIdx = callEdge[callTop - 1];
        final edgeEnd = rowPtrs[v + 1];

        if (edgeIdx < edgeEnd) {
          final w = colIndices[edgeIdx];
          callEdge[callTop - 1] = edgeIdx + 1;

          if (indices[w] == -1) {
            indices[w] = lowlinks[w] = currentIndex++;
            tarjanStack[stackTop++] = w;
            onStack[w] = 1;
            callNode[callTop] = w;
            callEdge[callTop] = rowPtrs[w];
            callTop++;
          } else if (onStack[w] == 1) {
            if (indices[w] < lowlinks[v]) {
              lowlinks[v] = indices[w];
            }
          }
        } else {
          callTop--;
          if (callTop > 0) {
            final parent = callNode[callTop - 1];
            if (lowlinks[v] < lowlinks[parent]) {
              lowlinks[parent] = lowlinks[v];
            }
          }

          if (lowlinks[v] == indices[v]) {
            sccCount++;
            int sccLen = 0;
            while (stackTop > 0) {
              final node = tarjanStack[--stackTop];
              onStack[node] = 0;
              sccBuffer[sccLen++] = node;
              if (node == v) break;
            }

            // Solve this SCC
            _solveFlatScc(
              sccBuffer,
              sccLen,
              rowPtrs,
              colIndices,
              assignedRes,
              assignedDtw,
              assignedDtz,
              assignedCp,
              computedRes,
              computedDtw,
              computedDtz,
              computedCp,
              isWhiteToMove,
              pieceCount,
            );
          }
        }
      }
    }

    onProgress?.call(0.85, 'Writing updated evaluations back to SQLite...');
    int updatedCount = 0;
    final dirtyIds = <int>[];
    for (int i = 1; i <= maxId; i++) {
      if (computedRes[i] != origComputedRes[i] ||
          computedDtw[i] != origComputedDtw[i] ||
          computedDtz[i] != origComputedDtz[i] ||
          computedCp[i] != origComputedCp[i]) {
        dirtyIds.add(i);
      }
    }

    for (int i = 0; i < dirtyIds.length; i += 2000) {
      final chunk = dirtyIds.skip(i).take(2000);
      final batch = db.batch();
      for (final id in chunk) {
        final cRes = _decodeGameResult(computedRes[id]);
        final cDtw = computedDtw[id] >= 0 ? computedDtw[id] : null;
        final cDtz = computedDtz[id] != 0 ? computedDtz[id] : null;
        final cCp = (computedRes[id] != 2 && computedCp[id] != 0) ? computedCp[id] : null;

        batch.rawUpdate('''
          UPDATE positions
          SET computed_result = ?, computed_dtw = ?, computed_dtz = ?, computed_cp = ?
          WHERE id = ?;
        ''', [cRes, cDtw, cDtz, cCp, id]);
        updatedCount++;
      }
      await batch.commit(noResult: true);
    }

    stopwatch.stop();
    onProgress?.call(1.0, 'Solve complete. Processed $posCount positions, updated $updatedCount in ${stopwatch.elapsedMilliseconds}ms.');

    return CsrSolveResult(
      totalPositions: posCount,
      totalEdges: edgeCount,
      sccCount: sccCount,
      updatedPositions: updatedCount,
      duration: stopwatch.elapsed,
    );
  }

  static void _solveFlatScc(
    Int32List scc,
    int sccLen,
    Int32List rowPtrs,
    Int32List colIndices,
    Int8List assignedRes,
    Int16List assignedDtw,
    Int16List assignedDtz,
    Int16List assignedCp,
    Int8List computedRes,
    Int16List computedDtw,
    Int16List computedDtz,
    Int16List computedCp,
    Uint8List isWhiteToMove,
    Uint8List pieceCount,
  ) {
    for (int i = 0; i < sccLen; i++) {
      final node = scc[i];
      if (assignedRes[node] != 0 || assignedCp[node] != 0) {
        computedRes[node] = assignedRes[node];
        computedDtw[node] = assignedDtw[node];
        computedDtz[node] = assignedDtz[node];
        computedCp[node] = assignedCp[node];
      } else {
        computedRes[node] = 0;
        computedDtw[node] = -1;
        computedDtz[node] = 0;
        computedCp[node] = 0;
      }
    }

    bool changed = true;
    int iterations = 0;
    final maxIterations = sccLen > 1 ? max(sccLen * 2, 20) : 5;

    while (changed) {
      changed = false;
      iterations++;
      if (iterations >= maxIterations) break;

      for (int i = 0; i < sccLen; i++) {
        final node = scc[i];
        final isWhite = isWhiteToMove[node] == 1;

        int bestRes = 0;
        int bestDtw = -1;
        int bestDtz = 0;
        int bestCp = 0;
        bool hasBest = false;

        final edgeStart = rowPtrs[node];
        final edgeEnd = rowPtrs[node + 1];

        for (int e = edgeStart; e < edgeEnd; e++) {
          final child = colIndices[e];
          final childRes = computedRes[child] != 0 ? computedRes[child] : assignedRes[child];
          final childCp = computedCp[child] != 0 ? computedCp[child] : assignedCp[child];

          if (childRes == 0 && childCp == 0) continue;

          final rawChildDtw = (computedRes[child] != 0 && (computedRes[child] == 1 || computedRes[child] == 3))
              ? computedDtw[child]
              : assignedDtw[child];
          final rawChildDtz = computedDtz[child] != 0 ? computedDtz[child] : assignedDtz[child];

          int candRes = childRes;
          int candDtw = (rawChildDtw >= 0) ? (rawChildDtw + 1) : -1;
          int candDtz = 0;
          if (rawChildDtz != 0) {
            if (pieceCount[child] < pieceCount[node]) {
              candDtz = 1;
            } else {
              candDtz = rawChildDtz + 1;
            }
          }
          int candCp = candRes == 2 ? 0 : childCp;

          if (!hasBest) {
            bestRes = candRes;
            bestDtw = candDtw;
            bestDtz = candDtz;
            bestCp = candCp;
            hasBest = true;
          } else {
            final cmp = _compareEvalValues(
              candRes, candDtw, candDtz, candCp,
              bestRes, bestDtw, bestDtz, bestCp,
              isWhite,
            );
            if (cmp < 0) {
              bestRes = candRes;
              bestDtw = candDtw;
              bestDtz = candDtz;
              bestCp = candCp;
            }
          }
        }

        if (!hasBest && (assignedRes[node] != 0 || assignedCp[node] != 0)) {
          bestRes = assignedRes[node];
          bestDtw = assignedDtw[node];
          bestDtz = assignedDtz[node];
          bestCp = assignedCp[node];
          hasBest = true;
        }

        if (bestRes == 2) {
          bestCp = 0;
        }

        if (hasBest) {
          if (computedRes[node] != bestRes ||
              computedDtw[node] != bestDtw ||
              computedDtz[node] != bestDtz ||
              computedCp[node] != bestCp) {
            computedRes[node] = bestRes;
            computedDtw[node] = bestDtw;
            computedDtz[node] = bestDtz;
            computedCp[node] = bestCp;
            changed = true;
          }
        }
      }
    }
  }

  static int _compareEvalValues(
    int aRes, int aDtw, int aDtz, int aCp,
    int bRes, int bDtw, int bDtz, int bCp,
    bool whiteToMove,
  ) {
    final targetWin = whiteToMove ? 1 : 3;
    final targetLoss = whiteToMove ? 3 : 1;

    final aWins = aRes == targetWin;
    final bWins = bRes == targetWin;
    if (aWins != bWins) {
      return aWins ? -1 : 1;
    }

    if (aWins && bWins) {
      final aImmediate = aDtw >= 0 && aDtw <= 2;
      final bImmediate = bDtw >= 0 && bDtw <= 2;
      if (aImmediate != bImmediate) {
        return aImmediate ? -1 : 1;
      }

      if (aDtw >= 0 && bDtw >= 0) {
        final cmp = aDtw.compareTo(bDtw);
        if (cmp != 0) return cmp;
      } else if (aDtw >= 0 && bDtw < 0) {
        return -1;
      } else if (aDtw < 0 && bDtw >= 0) {
        return 1;
      }

      if (aDtz != 0 && bDtz != 0) {
        final cmp = aDtz.compareTo(bDtz);
        if (cmp != 0) return cmp;
      }

      if (aCp != 0 && bCp != 0) {
        return whiteToMove ? bCp.compareTo(aCp) : aCp.compareTo(bCp);
      }
      return 0;
    }

    final aLoses = aRes == targetLoss;
    final bLoses = bRes == targetLoss;
    if (aLoses != bLoses) {
      return aLoses ? 1 : -1;
    }

    if (aLoses && bLoses) {
      if (aDtw >= 0 && bDtw >= 0) {
        final cmp = bDtw.compareTo(aDtw); // delay loss
        if (cmp != 0) return cmp;
      } else if (aDtw >= 0 && bDtw < 0) {
        return 1;
      } else if (aDtw < 0 && bDtw >= 0) {
        return -1;
      }

      if (aDtz != 0 && bDtz != 0) {
        final cmp = bDtz.compareTo(aDtz);
        if (cmp != 0) return cmp;
      }

      if (aCp != 0 && bCp != 0) {
        return whiteToMove ? bCp.compareTo(aCp) : aCp.compareTo(bCp);
      }
      return 0;
    }

    final aScore = _numericScore(aRes, aDtw, aDtz, aCp);
    final bScore = _numericScore(bRes, bDtw, bDtz, bCp);
    if (whiteToMove) {
      if (aScore > bScore) return -1;
      if (aScore < bScore) return 1;
    } else {
      if (aScore < bScore) return -1;
      if (aScore > bScore) return 1;
    }
    return 0;
  }

  static double _numericScore(int code, int dtw, int dtz, int cp) {
    if (code == 1) {
      // whiteWins
      if (dtw >= 0) return 1000.0 - dtw.toDouble();
      if (dtz > 0) return 950.0 - dtz.toDouble();
      return 950.0;
    } else if (code == 3) {
      // blackWins
      if (dtw >= 0) return -1000.0 + dtw.toDouble();
      if (dtz > 0) return -950.0 + dtz.toDouble();
      return -950.0;
    } else if (code == 2) {
      // draw
      return 0.0;
    }
    return cp.toDouble() / 100.0;
  }
}

// Background Isolate Messaging helpers
class _CsrWorkerParams {
  final String dbPath;
  final SendPort sendPort;
  _CsrWorkerParams(this.dbPath, this.sendPort);
}

class _CsrProgressMessage {
  final double progress;
  final String status;
  _CsrProgressMessage(this.progress, this.status);
}

class _CsrResultMessage {
  final CsrSolveResult result;
  _CsrResultMessage(this.result);
}

class _CsrErrorMessage {
  final String error;
  final String stackTrace;
  _CsrErrorMessage(this.error, this.stackTrace);
}

void _workerEntry(_CsrWorkerParams params) async {
  try {
    final factory = getPlatformDatabaseFactory();
    final db = await factory.openDatabase(params.dbPath);

    final result = await CsrGraphSolver.solveDirect(
      db,
      onProgress: (progress, status) {
        params.sendPort.send(_CsrProgressMessage(progress, status));
      },
    );

    await db.close();
    params.sendPort.send(_CsrResultMessage(result));
  } catch (e, st) {
    params.sendPort.send(_CsrErrorMessage(e.toString(), st.toString()));
  }
}
