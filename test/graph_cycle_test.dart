// ignore_for_file: avoid_print

import 'package:retro_solve/graph/graph.dart';
import 'package:test/test.dart';

void main() {
  test('2-move-pair cycle (A→B→C→D→A) with differing evals should converge', () {
    // A(white)→B(black)→C(white)→D(black)→A(white)
    // If solve() loops forever, this test will timeout.
    final g = Graph();
    g.addFullVertex('A w', 1.0, null);
    g.addFullVertex('B b', 0.5, null);
    g.addFullVertex('C w', 0.2, null);
    g.addFullVertex('D b', 0.8, null);
    g.addLink('A w', 'B b');
    g.addLink('B b', 'C w');
    g.addLink('C w', 'D b');
    g.addLink('D b', 'A w');

    // Should complete; if it loops forever the test times out after 5s
    g.solve();

    print('A.computed = ${g.v['A w']?.computed}');
    print('B.computed = ${g.v['B b']?.computed}');
    print('C.computed = ${g.v['C w']?.computed}');
    print('D.computed = ${g.v['D b']?.computed}');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('simple 2-node cycle (A→B→A) converges', () {
    // A(white)→B(black)→A: should stabilize because values just echo
    final g = Graph();
    g.addFullVertex('A w', 1.0, null);
    g.addFullVertex('B b', 0.5, null);
    g.addLink('A w', 'B b');
    g.addLink('B b', 'A w');

    g.solve();

    print('A.computed = ${g.v['A w']?.computed}');
    print('B.computed = ${g.v['B b']?.computed}');
  }, timeout: const Timeout(Duration(seconds: 5)));
}
