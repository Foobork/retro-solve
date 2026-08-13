// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:js_interop';
import 'package:retro_solve/graph/graph.dart';
import 'package:web/web.dart' as web;

Future<void> exportGraph(String filename) async {
  final buffer = StringBuffer();
  for (var entry in graph.v.entries) {
    if (entry.value.computed == null) continue;
    var assigned = entry.value.assigned?.toString() ?? "-";
    var computed = entry.value.computed.toString();
    buffer.writeln("${entry.key} $assigned $computed");
  }
  final bytes = utf8.encode(buffer.toString());
  final jsArray = [bytes.toJS].toJS;
  final blob = web.Blob(jsArray);
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename.split('/').last;
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  print("exportGraph done (browser download)");
}
