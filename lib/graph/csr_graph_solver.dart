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
  /// Sentinel for null/unassigned centipawns in flat Int16List arrays.
  static const int kNullCp = -32768;

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
    final assignedCp = Int16List(maxId + 1);

    final computedRes = Int8List(maxId + 1);
    final computedDtw = Int16List(maxId + 1);
    final computedCp = Int16List(maxId + 1);

    final origComputedRes = Int8List(maxId + 1);
    final origComputedDtw = Int16List(maxId + 1);
    final origComputedCp = Int16List(maxId + 1);

    assignedDtw.fillRange(0, maxId + 1, -1);
    computedDtw.fillRange(0, maxId + 1, -1);
    origComputedDtw.fillRange(0, maxId + 1, -1);

    assignedCp.fillRange(0, maxId + 1, kNullCp);
    computedCp.fillRange(0, maxId + 1, kNullCp);
    origComputedCp.fillRange(0, maxId + 1, kNullCp);

    final isWhiteToMove = Uint8List(maxId + 1);

    try {
      await db.execute('PRAGMA cache_size = -64000;');
      await db.execute('PRAGMA mmap_size = 1073741824;');
      await db.execute('PRAGMA temp_store = MEMORY;');
    } catch (_) {}

    onProgress?.call(0.20, 'Loading position metadata...');
    int lastPosId = 0;
    const posBatch = 250000;
    while (true) {
      final rows = await db.rawQuery('''
        SELECT id, (INSTR(bfen, ' w ') > 0) AS is_white
        FROM positions
        WHERE id > ?
        ORDER BY id
        LIMIT ?;
      ''', [lastPosId, posBatch]);
      if (rows.isEmpty) break;

      for (int i = 0; i < rows.length; i++) {
        final row = rows[i];
        final id = row['id'] as int;
        isWhiteToMove[id] = row['is_white'] as int;
      }
      lastPosId = rows.last['id'] as int;

      final progress = 0.20 + 0.15 * (lastPosId / (maxId > 0 ? maxId : 1));
      onProgress?.call(progress, 'Loading position metadata (${(progress * 100).toInt()}%)...');

      if (rows.length < posBatch) break;
    }

    onProgress?.call(0.35, 'Loading evaluation metadata...');
    final metadataRows = await db.rawQuery('''
      SELECT id, assigned_result, assigned_dtw, assigned_cp,
             computed_result, computed_dtw, computed_cp
      FROM positions
      WHERE assigned_result IS NOT NULL
         OR assigned_dtw IS NOT NULL
         OR assigned_cp IS NOT NULL
         OR computed_result IS NOT NULL
         OR computed_dtw IS NOT NULL
         OR computed_cp IS NOT NULL;
    ''');
    for (int i = 0; i < metadataRows.length; i++) {
      final row = metadataRows[i];
      final id = row['id'] as int;

      final aRes = row['assigned_result'] as int?;
      if (aRes != null) assignedRes[id] = _encodeGameResult(aRes);
      final aDtw = row['assigned_dtw'] as int?;
      if (aDtw != null) assignedDtw[id] = aDtw;
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
      final cCp = row['computed_cp'] as int?;
      if (cCp != null) {
        computedCp[id] = cCp;
        origComputedCp[id] = cCp;
      }
    }

    onProgress?.call(0.40, 'Streaming edge transitions into CSR...');
    int edgeIndex = 0;
    int currSource = 0;
    int lastSourceId = 0;
    int lastTargetId = 0;
    const edgeBatch = 200000;

    while (true) {
      final List<Map<String, Object?>> rows;
      if (lastSourceId == 0) {
        rows = await db.rawQuery('''
          SELECT source_id, target_id FROM edges
          ORDER BY source_id, target_id
          LIMIT ?;
        ''', [edgeBatch]);
      } else {
        rows = await db.rawQuery('''
          SELECT source_id, target_id FROM edges
          WHERE (source_id, target_id) > (?, ?)
          ORDER BY source_id, target_id
          LIMIT ?;
        ''', [lastSourceId, lastTargetId, edgeBatch]);
      }
      if (rows.isEmpty) break;

      for (int i = 0; i < rows.length; i++) {
        final row = rows[i];
        final s = row['source_id'] as int;
        final t = row['target_id'] as int;

        while (currSource < s) {
          rowPtrs[++currSource] = edgeIndex;
        }
        if (edgeIndex < colIndices.length) {
          colIndices[edgeIndex++] = t;
        }
      }
      final lastRow = rows.last;
      lastSourceId = lastRow['source_id'] as int;
      lastTargetId = lastRow['target_id'] as int;

      final progress = 0.40 + 0.20 * (edgeIndex / (edgeCount > 0 ? edgeCount : 1));
      onProgress?.call(progress, 'Streaming edge transitions (${(progress * 100).toInt()}%)...');

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
              assignedCp,
              computedRes,
              computedDtw,
              computedCp,
              isWhiteToMove,
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
          computedCp[i] != origComputedCp[i]) {
        dirtyIds.add(i);
      }
    }

    const writeBatchSize = 2500;
    for (int i = 0; i < dirtyIds.length; i += writeBatchSize) {
      final end = (i + writeBatchSize < dirtyIds.length) ? i + writeBatchSize : dirtyIds.length;
      final batch = db.batch();
      for (int j = i; j < end; j++) {
        final id = dirtyIds[j];
        final cRes = _decodeGameResult(computedRes[id]);
        final cDtw = computedDtw[id] >= 0 ? computedDtw[id] : null;
        final cCp = (computedRes[id] != 2 && computedCp[id] != kNullCp) ? computedCp[id] : null;

        batch.rawUpdate('''
          UPDATE positions
          SET computed_result = ?, computed_dtw = ?, computed_cp = ?
          WHERE id = ?;
        ''', [cRes, cDtw, cCp, id]);
        updatedCount++;
      }
      await batch.commit(noResult: true);

      final progress = 0.85 + 0.15 * (end / dirtyIds.length);
      onProgress?.call(progress, 'Writing evaluations (${(progress * 100).toInt()}%)...');
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
    Int16List assignedCp,
    Int8List computedRes,
    Int16List computedDtw,
    Int16List computedCp,
    Uint8List isWhiteToMove,
  ) {
    for (int i = 0; i < sccLen; i++) {
      final node = scc[i];
      if (assignedRes[node] != 0 || assignedCp[node] != kNullCp) {
        computedRes[node] = assignedRes[node];
        computedDtw[node] = assignedDtw[node];
        computedCp[node] = assignedCp[node];
      } else {
        computedRes[node] = 0;
        computedDtw[node] = -1;
        computedCp[node] = kNullCp;
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

        final edgeStart = rowPtrs[node];
        final edgeEnd = rowPtrs[node + 1];
        final numEdges = edgeEnd - edgeStart;

        final targetWin = isWhite ? 1 : 3;
        final targetLoss = isWhite ? 3 : 1;

        int winningCount = 0;
        int minWinDtw = 999999;

        int losingCount = 0;
        int maxLoseDtw = -1;

        int bestNonDecisiveCp = kNullCp;
        bool hasDraw = false;

        for (int e = edgeStart; e < edgeEnd; e++) {
          final child = colIndices[e];
          final childRes = computedRes[child] != 0 ? computedRes[child] : assignedRes[child];
          final childCp = computedCp[child] != kNullCp ? computedCp[child] : assignedCp[child];

          if (childRes == targetWin) {
            winningCount++;
            final rawDtw = (computedRes[child] == targetWin) ? computedDtw[child] : assignedDtw[child];
            final candDtw = (rawDtw >= 0) ? rawDtw + 1 : -1;
            if (candDtw >= 0 && candDtw < minWinDtw) {
              minWinDtw = candDtw;
            }
          } else if (childRes == targetLoss) {
            losingCount++;
            final rawDtw = (computedRes[child] == targetLoss) ? computedDtw[child] : assignedDtw[child];
            final candDtw = (rawDtw >= 0) ? rawDtw + 1 : -1;
            if (candDtw > maxLoseDtw) {
              maxLoseDtw = candDtw;
            }
          } else if (childRes == 2) {
            hasDraw = true;
            if (bestNonDecisiveCp == kNullCp) {
              bestNonDecisiveCp = 0;
            } else {
              if (isWhite ? 0 > bestNonDecisiveCp : 0 < bestNonDecisiveCp) {
                bestNonDecisiveCp = 0;
              }
            }
          } else if (childCp != kNullCp) {
            if (bestNonDecisiveCp == kNullCp) {
              bestNonDecisiveCp = childCp;
            } else {
              if (isWhite ? childCp > bestNonDecisiveCp : childCp < bestNonDecisiveCp) {
                bestNonDecisiveCp = childCp;
              }
            }
          }
        }

        int bestRes = 0;
        int bestDtw = -1;
        int bestCp = kNullCp;
        bool hasBest = false;

        if (winningCount > 0) {
          // 1. Any winning move -> Side to move WINS
          bestRes = targetWin;
          bestDtw = minWinDtw == 999999 ? -1 : minWinDtw;
          bestCp = kNullCp;
          hasBest = true;
        } else if (numEdges > 0 && losingCount == numEdges) {
          // 2. ALL moves are proven losses -> Side to move is forced to LOSE
          bestRes = targetLoss;
          bestDtw = maxLoseDtw;
          bestCp = kNullCp;
          hasBest = true;
        } else if (numEdges > 0 && losingCount + (hasDraw ? 1 : 0) == numEdges && hasDraw) {
          // 3. All non-losing moves are draws -> Draw
          bestRes = 2;
          bestDtw = -1;
          bestCp = kNullCp;
          hasBest = true;
        } else {
          // 4. Position is undecided / unproven
          if (bestNonDecisiveCp != kNullCp) {
            bestRes = 0;
            bestDtw = -1;
            bestCp = bestNonDecisiveCp;
            hasBest = true;
          } else if (assignedRes[node] != 0 || assignedCp[node] != kNullCp) {
            bestRes = assignedRes[node];
            bestDtw = assignedDtw[node];
            bestCp = assignedCp[node];
            hasBest = true;
          }
        }

        if (bestRes == 2) {
          bestCp = kNullCp;
        }

        final finalRes = hasBest ? bestRes : 0;
        final finalDtw = hasBest ? bestDtw : -1;
        final finalCp = hasBest ? bestCp : kNullCp;

        if (computedRes[node] != finalRes ||
            computedDtw[node] != finalDtw ||
            computedCp[node] != finalCp) {
          computedRes[node] = finalRes;
          computedDtw[node] = finalDtw;
          computedCp[node] = finalCp;
          changed = true;
        }
      }
    }
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
