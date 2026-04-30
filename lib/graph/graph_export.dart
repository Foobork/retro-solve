// ignore_for_file: avoid_print

import 'dart:io';

import 'package:retro_solve/graph/graph.dart';

void exportGraph(String filename) {
  print("exportGraph $filename");
  var file = File(filename).openSync(mode: FileMode.write);
  for (var entry in graph.v.entries) {
    if (entry.value.computed == null) continue;
    var assigned = entry.value.assigned?.toString() ?? "-";
    var computed = entry.value.computed.toString();
    file.writeStringSync("${entry.key} $assigned $computed\n");
  }
  file.closeSync();
  print("exportGraph done");
}
