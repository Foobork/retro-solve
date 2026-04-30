// ignore_for_file: avoid_print
import 'lib/chess/chess.dart';

void main() {
  const bfen = '1k1r1b1r/ppp2ppp/1qn2n2/3Pp3/2Q1PP2/2NK3B/PP3P1P/R1B4R b - -';
  final parts = bfen.split(' ');
  final fullFen = parts.length >= 4 ? "$bfen 0 1" : bfen;
  
  print("Testing FEN: $fullFen");
  var game = Chess();
  try {
    bool success = game.load(fullFen);
    print("Success: $success");
    print("Moves: ${game.generateMoves().length}");
  } catch(e) {
    print("Error: $e");
  }
}
