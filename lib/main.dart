import 'package:flutter/material.dart';

import 'dataset_variant.dart';
import 'engine/fairy_stockfish_service.dart';
import 'retro_solve.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final variant = await DatasetVariantStore.load();
  final engineService = FairyStockfishService(initialVariant: variant);
  runApp(RetroSolve(
    initialVariant: variant,
    engineService: engineService,
    autoImportGraph: true,
  ));
}
