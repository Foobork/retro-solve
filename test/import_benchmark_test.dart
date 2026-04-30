// ignore_for_file: avoid_print

import 'dart:io';

import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:test/test.dart';

/// Runs a timed phase and writes results to stderr (unaffected by solve prints).
Duration _time(String label, void Function() fn) {
  final sw = Stopwatch()..start();
  fn();
  sw.stop();
  stderr.writeln('  [$label] ${sw.elapsedMilliseconds} ms');
  return sw.elapsed;
}

void _benchmark(String label, String path) {
  test('benchmark: $label', () {
    if (!File(path).existsSync()) {
      stderr.writeln('  SKIP — file not found: $path');
      return;
    }

    stderr.writeln('\n=== $label ($path) ===');

    // ── Phase 1: raw file read ──────────────────────────────────────────────
    late List<String> lines;
    _time('File.readAsLinesSync', () {
      lines = File(path).readAsLinesSync();
    });
    stderr.writeln('  Lines: ${lines.length}');

    // ── Phase 2: parse + addFullVertex (no edge gen) ───────────────────────
    final g = Graph();
    final regex = RegExp(r'^(.* .* .* .*) (.*) (.*)$');

    double? parseEval(String? s) {
      if (s == null) return null;
      if (s == '-') return null;
      return double.tryParse(s);
    }

    _time('Parse + addFullVertex only', () {
      for (final line in lines) {
        final m = regex.firstMatch(line);
        if (m == null) continue;
        g.addFullVertex(
          m.group(1)!,
          parseEval(m.group(2)),
          parseEval(m.group(3)),
        );
      }
    });
    stderr.writeln('  Vertices: ${g.v.length}');

    // ── Phase 3: edge generation via Chess.generateMoves ───────────────────
    int totalEdges = 0;
    _time('Edge generation (generateMoves per vertex)', () {
      for (final bfen in g.v.keys.toList()) {
        final game = Chess();
        game.load('$bfen 0 1');
        final moves = game.generateMoves();
        final a = game.bfen;
        for (final move in moves) {
          game.makeMove(move);
          final b = game.bfen;
          game.undo();
          g.addLink(a, b);
          totalEdges++;
        }
      }
    });
    stderr.writeln('  Edges added: $totalEdges');
    stderr.writeln('  Total vertices after edges: ${g.v.length}');
  }, timeout: const Timeout(Duration(minutes: 30)), tags: 'long');
}

void main() {
  _benchmark('KOTH', 'data/KOTH.txt');
  _benchmark('Standard', 'data/Standard.txt');
}
