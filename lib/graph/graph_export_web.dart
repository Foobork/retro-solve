// ignore_for_file: avoid_print, avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;
import 'package:retro_solve/graph/graph.dart';

Future<void> exportGraph(String filename) async {
  final buffer = StringBuffer();
  for (var entry in graph.v.entries) {
    if (entry.value.computed == null) continue;
    var assigned = entry.value.assigned?.toString() ?? "-";
    var computed = entry.value.computed.toString();
    buffer.writeln("${entry.key} $assigned $computed");
  }
  final bytes = utf8.encode(buffer.toString());
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute("download", filename.split('/').last)
    ..click();
  html.Url.revokeObjectUrl(url);
  print("exportGraph done (browser download)");
}
