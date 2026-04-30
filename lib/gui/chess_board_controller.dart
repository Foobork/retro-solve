// ignore_for_file: avoid_print

import 'package:flutter/material.dart';

import '../chess/chess.dart';

class ChessBoardController extends ValueNotifier<Chess> {
  late Chess game;

  factory ChessBoardController() => ChessBoardController._(Chess());

  factory ChessBoardController.fromGame(Chess game) => ChessBoardController._(game);

  factory ChessBoardController.fromFEN(String fen) => ChessBoardController._(Chess.fromFEN(fen));

  ChessBoardController._(this.game) : super(game);

  /// Makes move on the board
  void makeMove({required String from, required String to}) {
    game.move({"from": from, "to": to});
    notifyListeners();
  }

  /// Makes move and promotes pawn to piece
  /// from is a square like d4
  /// to is also a square like e3
  /// pieceToPromoteTo is a String like "Q".
  void makeMoveWithPromotion({required String from, required String to, required String pieceToPromoteTo}) {
    game.move({"from": from, "to": to, "promotion": pieceToPromoteTo});
    notifyListeners();
  }

  /// Makes move on the board
  void makeMoveWithNormalNotation(String move) {
    game.move(move);
    notifyListeners();
  }

  void undoMove() {
    game.undoMove();
    notifyListeners();
  }

  void resetBoard() {
    game.reset();
    notifyListeners();
  }

  /// Clears board
  void clearBoard() {
    game.clear();
    notifyListeners();
  }

  /// Puts piece on a square
  void putPiece(PieceType piece, String square, PlayerColor color) {
    game.put(Piece(piece, color), square);
    notifyListeners();
  }

  /// Loads a PGN
  void loadPGN(String pgn) {
    game.loadPgn(pgn);
    notifyListeners();
  }

  /// Loads a PGN
  void loadFen(String fen) {
    game.load(fen);
    notifyListeners();
  }

  bool isInCheck() {
    return game.inCheck;
  }

  bool isCheckMate() {
    return game.inCheckmate;
  }

  bool isDraw() {
    return game.inDraw;
  }

  bool isStaleMate() {
    return game.inStalemate;
  }

  bool isThreefoldRepetition() {
    return game.inThreefoldRepetition;
  }

  bool isInsufficientMaterial() {
    return game.insufficientMaterial;
  }

  bool isGameOver() {
    return game.gameOver;
  }

  String getAscii() {
    return game.ascii;
  }

  String getFen() {
    return game.fen;
  }

  List<String?> getSan() {
    return game.sanMoves();
  }

  List<Piece?> getBoard() {
    return game.board;
  }

  List<Move> getPossibleMoves() {
    return game.moves({'asObjects': true}) as List<Move>;
  }

  int getMoveCount() {
    return game.moveNumber;
  }

  int getHalfMoveCount() {
    return game.halfMoves;
  }
}
