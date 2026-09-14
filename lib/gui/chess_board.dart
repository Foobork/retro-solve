import 'dart:math';

import 'package:chess_vectors_flutter/chess_vectors_flutter.dart';
import 'package:flutter/material.dart';

import '../chess/chess.dart';
import 'board_arrow.dart';
import 'chess_board_controller.dart';

/// Enum which stores board types
enum BoardColor {
  brown,
  darkBrown,
  orange,
  green,
}

extension BoardColorColors on BoardColor {
  Color get lightSquare {
    switch (this) {
      case BoardColor.brown:
        return const Color(0xFFF0D9B5);
      case BoardColor.darkBrown:
        return const Color(0xFFE8D3B9);
      case BoardColor.orange:
        return const Color(0xFFFFDFB0);
      case BoardColor.green:
        return const Color(0xFFE2E4C0);
    }
  }

  Color get darkSquare {
    switch (this) {
      case BoardColor.brown:
        return const Color(0xFFB58863);
      case BoardColor.darkBrown:
        return const Color(0xFF8B5A2B);
      case BoardColor.orange:
        return const Color(0xFFD2691E);
      case BoardColor.green:
        return const Color(0xFF578A34);
    }
  }
}


const _files = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

class ChessBoard extends StatefulWidget {
  /// An instance of [ChessBoardController] which holds the game and allows
  /// manipulating the board programmatically.
  final ChessBoardController controller;

  /// Size of chessboard
  final double? size;

  /// A boolean which checks if the user should be allowed to make moves
  final bool enableUserMoves;

  /// The color type of the board
  final BoardColor boardColor;

  final PlayerColor boardOrientation;

  final VoidCallback? onMove;

  final List<BoardArrow> arrows;

  /// Square of origin for the last move made (e.g. 'e2').
  final String? lastMoveFrom;

  /// Square of destination for the last move made (e.g. 'e4').
  final String? lastMoveTo;

  const ChessBoard({
    Key? key,
    required this.controller,
    this.size,
    this.enableUserMoves = true,
    this.boardColor = BoardColor.brown,
    this.boardOrientation = white,
    this.onMove,
    this.arrows = const [],
    this.lastMoveFrom,
    this.lastMoveTo,
  }) : super(key: key);

  @override
  State<ChessBoard> createState() => _ChessBoardState();
}

class _ChessBoardState extends State<ChessBoard> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Chess>(
      valueListenable: widget.controller,
      builder: (context, game, _) {
        final boardWidget = Stack(
          children: [
            AspectRatio(
              aspectRatio: 1.0,
              child: LayoutBuilder(
                builder: (context, boxConstraints) {
                  final squareSize = boxConstraints.maxWidth / 8;
                  return GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8),
                    itemBuilder: (context, index) {
                      var row = index ~/ 8;
                      var column = index % 8;
                      var boardRank = widget.boardOrientation == black ? '${row + 1}' : '${(7 - row) + 1}';
                      var boardFile = widget.boardOrientation == white ? _files[column] : _files[7 - column];

                      var squareName = '$boardFile$boardRank';
                      var pieceOnSquare = game.get(squareName);

                      final lastMove = game.history.isNotEmpty ? game.history.last.move : null;
                      final effectiveLastMoveTo = widget.lastMoveTo ?? lastMove?.toAlgebraic;
                      final effectiveLastMoveFrom = widget.lastMoveFrom ?? lastMove?.fromAlgebraic;
                      final isLastMoveTo = squareName == effectiveLastMoveTo;
                      final isLastMoveFrom = squareName == effectiveLastMoveFrom;

                      var piece = BoardPiece(
                        key: ValueKey('piece-$squareName-${pieceOnSquare?.color}-${pieceOnSquare?.type}'),
                        squareName: squareName,
                        game: game,
                      );

                      var draggable = game.get(squareName) != null
                          ? Draggable<PieceMoveData>(
                              key: ValueKey('drag-$squareName'),
                              maxSimultaneousDrags: widget.enableUserMoves ? 1 : 0,
                              child: piece,
                              feedback: Material(
                                color: Colors.transparent,
                                child: SizedBox(
                                  width: squareSize,
                                  height: squareSize,
                                  child: piece,
                                ),
                              ),
                              childWhenDragging: Opacity(
                                opacity: 0.3,
                                child: piece,
                              ),
                              data: PieceMoveData(
                                squareName: squareName,
                                pieceType: pieceOnSquare?.type.toUpperCase() ?? 'P',
                                pieceColor: pieceOnSquare?.color ?? white,
                              ),
                            )
                          : Container();

                  var dragTarget = DragTarget<PieceMoveData>(
                    key: ValueKey('target-$squareName'),
                    builder: (context, candidateData, _) {
                      final isHovered = candidateData.isNotEmpty;

                      return Stack(
                        children: [
                          if (isLastMoveTo)
                            Positioned.fill(
                              child: Container(
                                key: ValueKey('last-move-to-$squareName'),
                                decoration: BoxDecoration(
                                  color: const Color(0x4D64FFDA),
                                  border: Border.all(
                                    color: const Color(0xCC64FFDA),
                                    width: 2.5,
                                  ),
                                ),
                              ),
                            )
                          else if (isLastMoveFrom)
                            Positioned.fill(
                              child: Container(
                                key: ValueKey('last-move-from-$squareName'),
                                color: const Color(0x2864FFDA),
                              ),
                            ),
                          Positioned.fill(child: draggable),
                          if (isHovered)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Container(
                                  color: const Color(0x5964FFDA),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                    onWillAcceptWithDetails: (details) {
                      if (!widget.enableUserMoves) return false;
                      return details.data.squareName != squareName;
                    },
                    onAcceptWithDetails: (DragTargetDetails<PieceMoveData> dragTargetDetails) async {
                      PieceMoveData pieceMoveData = dragTargetDetails.data;
                      if (pieceMoveData.squareName == squareName) return;

                      // A way to check if move occurred.
                      PlayerColor moveColor = game.turn;

                      final isPawnPromotion = pieceMoveData.pieceType.toUpperCase() == "P" &&
                          !pieceMoveData.squareName.startsWith('@') &&
                          ((squareName[1] == "8" && pieceMoveData.pieceColor == white) ||
                              (squareName[1] == "1" && pieceMoveData.pieceColor == black));

                      if (isPawnPromotion) {
                        var val = await _promotionDialog(
                          context,
                          color: pieceMoveData.pieceColor,
                          isAntichess: game.isAntichess,
                        );

                        if (val != null) {
                          widget.controller.makeMoveWithPromotion(
                            from: pieceMoveData.squareName,
                            to: squareName,
                            pieceToPromoteTo: val,
                          );
                        } else {
                          return;
                        }
                      } else {
                        widget.controller.makeMove(
                          from: pieceMoveData.squareName,
                          to: squareName,
                        );
                      }
                      if (game.turn != moveColor) {
                        widget.onMove?.call();
                      }
                    },
                  );

                  final isLightSquare = (row + column) % 2 == 0;
                  final squareColor = isLightSquare ? widget.boardColor.lightSquare : widget.boardColor.darkSquare;

                  return Container(
                    color: squareColor,
                    child: dragTarget,
                  );
                },
                itemCount: 64,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
              );
            },
          ),
        ),
            if (widget.arrows.isNotEmpty)
              IgnorePointer(
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: CustomPaint(
                    child: Container(),
                    painter: _ArrowPainter(widget.arrows, widget.boardOrientation),
                  ),
                ),
              ),
          ],
        );

        return LayoutBuilder(
          builder: (context, constraints) {
            final hasBoundedWidth = constraints.hasBoundedWidth && !constraints.maxWidth.isInfinite;
            final hasBoundedHeight = constraints.hasBoundedHeight && !constraints.maxHeight.isInfinite;

            if (game is CrazyhouseChess) {
              final topColor = widget.boardOrientation == white ? black : white;
              final bottomColor = widget.boardOrientation == white ? white : black;

              double boardSize;
              double pocketHeight = 44.0;
              const verticalSpacing = 8.0; // Two 4.0 spacers

              if (hasBoundedWidth && hasBoundedHeight) {
                final maxBoardHeight = max(0.0, constraints.maxHeight - (pocketHeight * 2) - verticalSpacing);
                boardSize = min(constraints.maxWidth, maxBoardHeight);
              } else if (hasBoundedWidth) {
                boardSize = widget.size ?? constraints.maxWidth;
              } else if (hasBoundedHeight) {
                final maxBoardHeight = max(0.0, constraints.maxHeight - (pocketHeight * 2) - verticalSpacing);
                boardSize = widget.size ?? maxBoardHeight;
              } else {
                boardSize = widget.size ?? 400.0;
              }

              pocketHeight = (boardSize / 8).clamp(24.0, 44.0);

              return Center(
                child: SizedBox(
                  width: boardSize,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildPocket(game, topColor, pocketHeight, boardSize / 8),
                      const SizedBox(height: 4.0),
                      SizedBox(
                        width: boardSize,
                        height: boardSize,
                        child: boardWidget,
                      ),
                      const SizedBox(height: 4.0),
                      _buildPocket(game, bottomColor, pocketHeight, boardSize / 8),
                    ],
                  ),
                ),
              );
            } else {
              double boardSize;
              if (hasBoundedWidth && hasBoundedHeight) {
                boardSize = min(constraints.maxWidth, constraints.maxHeight);
              } else if (hasBoundedWidth) {
                boardSize = widget.size ?? constraints.maxWidth;
              } else if (hasBoundedHeight) {
                boardSize = widget.size ?? constraints.maxHeight;
              } else {
                boardSize = widget.size ?? 400.0;
              }

              return Center(
                child: SizedBox(
                  width: boardSize,
                  height: boardSize,
                  child: boardWidget,
                ),
              );
            }
          },
        );
      },
    );
  }

  Widget _buildPocket(CrazyhouseChess game, PlayerColor color, double height, [double? squareSize]) {
    final pocket = game.pockets[color]!;
    final types = [PieceType.queen, PieceType.rook, PieceType.bishop, PieceType.knight, PieceType.pawn];
    final pieceSize = (height - 8.0).clamp(16.0, 36.0);

    return Container(
      height: height,
      color: Colors.grey.shade100,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: types.map((type) {
              final count = pocket[type] ?? 0;
              final hasPieces = count > 0;
              final letter = type.name.toUpperCase();
              final dropCode = '$letter@';

              Widget pieceWidget = SizedBox(
                width: pieceSize,
                height: pieceSize,
                child: Opacity(
                  opacity: hasPieces ? 1.0 : 0.25,
                  child: _getPieceVector(type, color),
                ),
              );

              Widget pieceWithBadge = Stack(
                clipBehavior: Clip.none,
                children: [
                  pieceWidget,
                  if (hasPieces)
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: Container(
                        padding: const EdgeInsets.all(2.0),
                        decoration: const BoxDecoration(
                          color: Colors.deepPurple,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        child: Text(
                          '$count',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              );

              if (hasPieces) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6.0),
                  child: Draggable<PieceMoveData>(
                    key: ValueKey('pocket-drag-$color-${type.name}'),
                    maxSimultaneousDrags: widget.enableUserMoves ? 1 : 0,
                    feedback: Material(
                      color: Colors.transparent,
                      child: SizedBox(
                        width: squareSize ?? 50,
                        height: squareSize ?? 50,
                        child: _getPieceVector(type, color),
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.3,
                      child: pieceWithBadge,
                    ),
                    data: PieceMoveData(
                      squareName: dropCode,
                      pieceType: letter,
                      pieceColor: color,
                    ),
                    child: pieceWithBadge,
                  ),
                );
              } else {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6.0),
                  child: pieceWithBadge,
                );
              }
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _getPieceVector(PieceType type, PlayerColor color) {
    if (color == white) {
      switch (type) {
        case PieceType.pawn: return WhitePawn();
        case PieceType.knight: return WhiteKnight();
        case PieceType.bishop: return WhiteBishop();
        case PieceType.rook: return WhiteRook();
        case PieceType.queen: return WhiteQueen();
        case PieceType.king: return WhiteKing();
      }
    } else {
      switch (type) {
        case PieceType.pawn: return BlackPawn();
        case PieceType.knight: return BlackKnight();
        case PieceType.bishop: return BlackBishop();
        case PieceType.rook: return BlackRook();
        case PieceType.queen: return BlackQueen();
        case PieceType.king: return BlackKing();
      }
    }
    return const SizedBox();
  }

  /// Show dialog when pawn reaches last square
  Future<String?> _promotionDialog(BuildContext context, {PlayerColor color = white, bool isAntichess = false}) async {
    final isWhite = color == white;

    Widget promoButton(String code, Widget pieceWidget, String label) {
      return Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.of(context).pop(code),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: SizedBox(
              width: 48,
              height: 48,
              child: pieceWidget,
            ),
          ),
        ),
      );
    }

    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Choose promotion'),
          content: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                promoButton('q', isWhite ? WhiteQueen() : BlackQueen(), 'Queen'),
                const SizedBox(width: 8),
                promoButton('r', isWhite ? WhiteRook() : BlackRook(), 'Rook'),
                const SizedBox(width: 8),
                promoButton('b', isWhite ? WhiteBishop() : BlackBishop(), 'Bishop'),
                const SizedBox(width: 8),
                promoButton('n', isWhite ? WhiteKnight() : BlackKnight(), 'Knight'),
                if (isAntichess) ...[
                  const SizedBox(width: 8),
                  promoButton('k', isWhite ? WhiteKing() : BlackKing(), 'King'),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }
}

class BoardPiece extends StatelessWidget {
  final String squareName;
  final Chess game;

  const BoardPiece({
    Key? key,
    required this.squareName,
    required this.game,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    late Widget imageToDisplay;
    var square = game.get(squareName);

    if (game.get(squareName) == null) {
      return Container();
    }

    String piece = (square?.color == white ? 'W' : 'B') + (square?.type.toUpperCase() ?? 'P');

    switch (piece) {
      case "WP":
        imageToDisplay = WhitePawn();
        break;
      case "WR":
        imageToDisplay = WhiteRook();
        break;
      case "WN":
        imageToDisplay = WhiteKnight();
        break;
      case "WB":
        imageToDisplay = WhiteBishop();
        break;
      case "WQ":
        imageToDisplay = WhiteQueen();
        break;
      case "WK":
        imageToDisplay = WhiteKing();
        break;
      case "BP":
        imageToDisplay = BlackPawn();
        break;
      case "BR":
        imageToDisplay = BlackRook();
        break;
      case "BN":
        imageToDisplay = BlackKnight();
        break;
      case "BB":
        imageToDisplay = BlackBishop();
        break;
      case "BQ":
        imageToDisplay = BlackQueen();
        break;
      case "BK":
        imageToDisplay = BlackKing();
        break;
      default:
        imageToDisplay = WhitePawn();
    }

    if (game.isThreeCheck && square != null && square.type == PieceType.king) {
      final opponentColor = square.color == white ? black : white;
      final remainingChecks = game.checksCount[opponentColor];
      
      final kingImage = imageToDisplay;
      imageToDisplay = LayoutBuilder(
        builder: (context, constraints) {
          final double squareSize = constraints.hasBoundedWidth ? constraints.maxWidth : 50.0;
          final badgeSize = (squareSize * 0.50).clamp(16.0, 48.0);
          final fontSize = badgeSize * 0.55;
          final borderWidth = (badgeSize * 0.08).clamp(1.0, 3.0);

          return Stack(
            fit: StackFit.passthrough,
            clipBehavior: Clip.none,
            children: [
              kingImage,
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: EdgeInsets.all(badgeSize * 0.15),
                  decoration: BoxDecoration(
                    color: _getBadgeColor(remainingChecks),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: borderWidth),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 2,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  width: badgeSize,
                  height: badgeSize,
                  child: Center(
                    child: Text(
                      '$remainingChecks',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    return imageToDisplay;
  }

  Color _getBadgeColor(int remaining) {
    switch (remaining) {
      case 3:
        return Colors.green.shade600;
      case 2:
        return Colors.amber.shade700;
      case 1:
        return Colors.red.shade700;
      default:
        return Colors.grey.shade600;
    }
  }
}

class PieceMoveData {
  final String squareName;
  final String pieceType;
  final PlayerColor pieceColor;

  PieceMoveData({
    required this.squareName,
    required this.pieceType,
    required this.pieceColor,
  });
}

class _ArrowPainter extends CustomPainter {
  List<BoardArrow> arrows;
  PlayerColor boardOrientation;

  _ArrowPainter(this.arrows, this.boardOrientation);

  @override
  void paint(Canvas canvas, Size size) {
    var blockSize = size.width / 8;
    var halfBlockSize = size.width / 16;

    for (var arrow in arrows) {
      var startFile = _files.indexOf(arrow.from[0]);
      var startRank = int.parse(arrow.from[1]) - 1;
      var endFile = _files.indexOf(arrow.to[0]);
      var endRank = int.parse(arrow.to[1]) - 1;

      int effectiveRowStart = 0;
      int effectiveColumnStart = 0;
      int effectiveRowEnd = 0;
      int effectiveColumnEnd = 0;

      if (boardOrientation == PlayerColor.black) {
        effectiveColumnStart = 7 - startFile;
        effectiveColumnEnd = 7 - endFile;
        effectiveRowStart = startRank;
        effectiveRowEnd = endRank;
      } else {
        effectiveColumnStart = startFile;
        effectiveColumnEnd = endFile;
        effectiveRowStart = 7 - startRank;
        effectiveRowEnd = 7 - endRank;
      }

      var startOffset = Offset(((effectiveColumnStart + 1) * blockSize) - halfBlockSize,
          ((effectiveRowStart + 1) * blockSize) - halfBlockSize);
      var endOffset = Offset(
          ((effectiveColumnEnd + 1) * blockSize) - halfBlockSize, ((effectiveRowEnd + 1) * blockSize) - halfBlockSize);

      var yDist = 0.8 * (endOffset.dy - startOffset.dy);
      var xDist = 0.8 * (endOffset.dx - startOffset.dx);

      var paint = Paint()
        ..strokeWidth = halfBlockSize * 0.8
        ..color = arrow.color;

      canvas.drawLine(startOffset, Offset(startOffset.dx + xDist, startOffset.dy + yDist), paint);

      var slope = (endOffset.dy - startOffset.dy) / (endOffset.dx - startOffset.dx);

      var newLineSlope = -1 / slope;

      var points = _getNewPoints(Offset(startOffset.dx + xDist, startOffset.dy + yDist), newLineSlope, halfBlockSize);
      var newPoint1 = points[0];
      var newPoint2 = points[1];

      var path = Path();

      path.moveTo(endOffset.dx, endOffset.dy);
      path.lineTo(newPoint1.dx, newPoint1.dy);
      path.lineTo(newPoint2.dx, newPoint2.dy);
      path.close();

      canvas.drawPath(path, paint);
    }
  }

  List<Offset> _getNewPoints(Offset start, double slope, double length) {
    if (slope == double.infinity || slope == double.negativeInfinity) {
      return [Offset(start.dx, start.dy + length), Offset(start.dx, start.dy - length)];
    }

    return [
      Offset(
          start.dx + (length / sqrt(1 + (slope * slope))), start.dy + ((length * slope) / sqrt(1 + (slope * slope)))),
      Offset(
          start.dx - (length / sqrt(1 + (slope * slope))), start.dy - ((length * slope) / sqrt(1 + (slope * slope)))),
    ];
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) {
    return arrows != oldDelegate.arrows;
  }
}
