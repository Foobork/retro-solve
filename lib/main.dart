import 'package:flutter/material.dart';

import 'retro_solve.dart';
import 'dataset_variant.dart';
import 'engine/fairy_stockfish_service.dart';
import 'graph/graph_import.dart';
import 'graph/graph.dart';
import 'persistence/database_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final variant = await DatasetVariantStore.load();
  
  graph.onNodeUpdated = (bfen, assigned, computed) {
    DatabaseService.instance.upsertNode(bfen, assigned, computed);
  };
  graph.onEdgeAdded = (source, target) {
    DatabaseService.instance.upsertEdge(source, target);
  };

  await importGraph(variant.dataPath);
  final engineService = FairyStockfishService(initialVariant: variant);
  await engineService.start();
  runApp(RetroSolve(initialVariant: variant, engineService: engineService));
}
