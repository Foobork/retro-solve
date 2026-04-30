import 'package:logging/logging.dart';
import 'package:retro_solve/graph/graph.dart';

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.message}');
  });
  final logger = Logger('TestCycle');

  logger.info("Testing cycle handling in graph...");

  graph.v.clear();

  // Create an inescapable 4-node cycle: A -> B -> C -> D -> A
  // A (white), B (black), C (white), D (black)
  graph.addFullVertex("A w", null, null);
  graph.addFullVertex("B b", null, null);
  graph.addFullVertex("C w", null, null);
  graph.addFullVertex("D b", null, null);

  graph.addLink("A w", "B b");
  graph.addLink("B b", "C w");
  graph.addLink("C w", "D b");
  graph.addLink("D b", "A w");

  graph.solve();

  assert(graph.v["A w"]?.computed == 0.0);
  assert(graph.v["B b"]?.computed == 0.0);
  assert(graph.v["C w"]?.computed == 0.0);
  assert(graph.v["D b"]?.computed == 0.0);
  logger.info("Cycle test 1 passed! All values converged to 0.0");

  // Now, let's add an exit from C to E with an assured winning evaluation (+10.0)
  graph.addFullVertex("E b", 10.0, null);
  graph.addLink("C w", "E b");

  graph.solve();

  // C (white) chooses max(D, E) -> max(varies, 10.0) -> 10.0
  // B (black) has to go to C, so takes 10.0
  // A (white) has to go to B, so takes 10.0
  // D (black) has to go to A, so takes 10.0
  assert(graph.v["C w"]?.computed == 10.0, 'Expected C w to be 10.0, got ${graph.v["C w"]?.computed}');
  assert(graph.v["B b"]?.computed == 10.0, 'Expected B b to be 10.0, got ${graph.v["B b"]?.computed}');
  assert(graph.v["A w"]?.computed == 10.0, 'Expected A w to be 10.0, got ${graph.v["A w"]?.computed}');
  assert(graph.v["D b"]?.computed == 10.0, 'Expected D b to be 10.0, got ${graph.v["D b"]?.computed}');
  
  logger.info("Cycle test 2 passed! All values successfully backed up the 10.0 exit.");
}
