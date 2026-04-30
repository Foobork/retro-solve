// ignore_for_file: avoid_print
import 'dart:io';

import '../chess/chess.dart';

void main() async {
  var dataSet = "Standard";
//  var dataSet = "Tako";
  importFolder(dataSet);
  await exportPositions(dataSet);
  exit(0);
}

void importFolder(String dataSet) {
  int byName(FileSystemEntity a, FileSystemEntity b) {
    return a.path.compareTo(b.path);
  }

  var folder = Directory(dataSet);
  print(folder.absolute.path);
  var list = folder.listSync();
  list.sort(byName);
  for (var file in list) {
    if (file is File) importFile(file);
  }
}

Future exportPositions(String dataSet) async {
  var filename = "$dataSet.txt";
  print("Exporting $filename");
  var out = File(filename).openWrite();
  for (var e in positions.entries) {
    var evals = e.value.isEmpty ? "-" : e.value.join(",");
    out.writeln("${e.key} $evals");
  }
  await out.flush();
  await out.close();
  print("Export done");
}

// map a bfen to a set of evaluations
Map<String, Set<String>> positions = {};

// track a chess game
var game = Chess();

void importFile(File file) {
  print(file.path);
  var lines = file.readAsLinesSync();
  for (var lineNumber = 0; lineNumber < lines.length; lineNumber++) {
    var line = lines[lineNumber].trim();
    line = line.replaceAll(RegExp(r"\(.*\)"), "");
    line = line.replaceAll(RegExp(r"=>.*"), "");
    line = line.replaceAll("***", "");
    var tokens = line.split(RegExp(r"\s+"));
    try {
      for (var token in tokens) {
        processToken(token);
      }
    } catch (e) {
      print('${lineNumber + 1}: $line');
      print("\n${game.ascii}");
      var moves = game.generateMoves();
      print(moves.map((move) => game.moveToSan(move)));
      rethrow;
    }
  }
}

var eval = RegExp(r"^\[.*\]$");
var moveNumber = RegExp(r"^\d+\.(\.\.)?$");
var move = RegExp(r"^[NBRQK]?[a-h]?[1-8]?[a-h][1-8][NBRQ]?$");
var castles = RegExp(r"O-O(-O)?");

void processToken(String token) {
  if (token == "") {
    // empty
  } else if (moveNumber.hasMatch(token)) {
    processMoveNumber(token);
  } else if (move.hasMatch(token) || castles.hasMatch(token)) {
    processMove(token);
  } else if (eval.hasMatch(token)) {
    processEval(token);
  } else {
    throw Exception("Couldn't interpret $token");
  }
}

void processMove(String move) {
  bool result = game.move(move);
  if (result == false) throw Exception("Can't do $move");
  positions.putIfAbsent(game.bfen, () => {});
}

void processMoveNumber(String token) {
  int moveNumber = int.parse(token.replaceAll(".", ""));
  if (game.moveNumber < moveNumber) {
    throw Exception("Can't jump forward from ${game.moveNumber} to $moveNumber");
  }
  while (game.moveNumber > moveNumber) {
    game.undo();
  }
  PlayerColor turn = token.endsWith("...") ? black : white;
  if (game.turn == white && turn == black) {
    throw Exception("Can't jump forward to black's turn");
  }
  if (game.turn == black && turn == white) {
    game.undo();
  }
}

void processEval(String token) {
  var bfen = game.bfen;
  var evals = positions[bfen];
  if (evals == null) throw Exception("$bfen not found");
  evals.add(token);
  positions[bfen] = evals;
}
