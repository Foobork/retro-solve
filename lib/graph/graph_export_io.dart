// ignore_for_file: avoid_print

import 'dart:io';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/persistence/database_service.dart';

Future<void> exportGraph(String filename) async {
  print("exportGraph $filename");
  final file = File(filename).openSync(mode: FileMode.write);

  if (DatabaseService.instance.isOpen) {
    int? lastId;
    const chunkSize = 50000;
    while (true) {
      final rows = await DatabaseService.instance.getPositionsForExport(
        afterId: lastId,
        limit: chunkSize,
      );
      if (rows.isEmpty) break;

      for (final row in rows) {
        final bfen = row['bfen'] as String;
        final assigned = DatabaseService.evalFromRow(row, 'assigned');
        final computed = DatabaseService.evalFromRow(row, 'computed');
        if (computed == null) continue;

        final assignedStr = assigned?.format() ?? "-";
        final computedStr = computed.format();
        file.writeStringSync("$bfen $assignedStr $computedStr\n");
        lastId = row['id'] as int;
      }
      if (rows.length < chunkSize) break;
    }
  } else {
    for (var entry in graph.v.entries) {
      if (entry.value.computed == null) continue;
      var assigned = entry.value.assigned?.format() ?? "-";
      var computed = entry.value.computed!.format();
      file.writeStringSync("${entry.key} $assigned $computed\n");
    }
  }

  file.closeSync();
  print("exportGraph done");
}
