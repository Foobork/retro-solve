import 'chess.dart';

class PgnNode {
  final String? san;
  final List<PgnNode> children = [];

  PgnNode({this.san});

  int get totalNodes {
    int count = san != null ? 1 : 0;
    for (final child in children) {
      count += child.totalNodes;
    }
    return count;
  }
}

class PgnGame {
  final Map<String, String> headers;
  final PgnNode root;

  PgnGame({required this.headers, required this.root});

  String? get variant => headers['Variant'] ?? headers['RuleVariants'];
  String? get fen => headers['FEN'];
  String? get event => headers['Event'];
  String? get chapterName => headers['ChapterName'];
}

class PgnParser {
  static List<PgnGame> parse(String pgnText) {
    final List<PgnGame> games = [];
    final lines = pgnText.split(RegExp(r'\r?\n'));

    bool inHeader = false;
    Map<String, String> currentHeaders = {};
    StringBuffer currentMoveText = StringBuffer();

    void finishCurrentGame() {
      final moveStr = currentMoveText.toString().trim();
      if (currentHeaders.isNotEmpty || moveStr.isNotEmpty) {
        final root = _parseMoveText(moveStr);
        games.add(PgnGame(headers: Map.from(currentHeaders), root: root));
        currentHeaders.clear();
        currentMoveText.clear();
      }
    }

    final headerRegex = RegExp(r'^\s*\[([A-Za-z0-9_]+)\s+"(.*)"\]\s*$');

    for (final line in lines) {
      final trimmed = line.trim();
      final match = headerRegex.firstMatch(trimmed);

      if (match != null) {
        if (!inHeader && currentMoveText.isNotEmpty) {
          finishCurrentGame();
        }
        inHeader = true;
        currentHeaders[match.group(1)!] = match.group(2)!;
      } else {
        if (inHeader) {
          inHeader = false;
        }
        if (trimmed.isNotEmpty) {
          currentMoveText.write(' ');
          currentMoveText.write(trimmed);
        }
      }
    }

    finishCurrentGame();
    return games;
  }

  static PgnNode _parseMoveText(String moveText) {
    final root = PgnNode(san: null);

    // 1. Remove comments in curly braces: { ... }
    String cleaned = moveText.replaceAll(RegExp(r'\{[^}]*\}', dotAll: true), ' ');

    // 2. Remove line comments: ; ...
    cleaned = cleaned.replaceAll(RegExp(r';[^\r\n]*'), ' ');

    // 3. Separate parentheses with spaces for clean tokenization, and ensure space after move numbers
    cleaned = cleaned.replaceAll('(', ' ( ').replaceAll(')', ' ) ');
    cleaned = cleaned.replaceAllMapped(RegExp(r'(\d+)\.([^\s\.])'), (m) => '${m[1]}. ${m[2]}');

    // 4. Tokenize by whitespace
    final rawTokens = cleaned.split(RegExp(r'\s+'));
    final tokens = <String>[];

    final moveNumberRegex = RegExp(r'^\d+\.*$');
    final nagRegex = RegExp(r'^\$\d+$');
    const resultTokens = {'1-0', '0-1', '1/2-1/2', '*'};

    for (final token in rawTokens) {
      final t = token.trim();
      if (t.isEmpty) continue;
      if (t == '(' || t == ')') {
        tokens.add(t);
        continue;
      }
      if (moveNumberRegex.hasMatch(t)) continue;
      if (nagRegex.hasMatch(t)) continue;
      if (resultTokens.contains(t)) continue;

      // Clean trailing NAGs/annotations like !, ?, !?, ?! and normalize drop notation
      final cleanMove = Chess.normalizeDropNotation(t.replaceAll(RegExp(r'[!?]+$'), ''));
      if (cleanMove.isNotEmpty) {
        tokens.add(cleanMove);
      }
    }

    if (tokens.isEmpty) return root;

    _buildTree(tokens, 0, root);
    return root;
  }

  static int _buildTree(List<String> tokens, int startIndex, PgnNode initialParent) {
    PgnNode currentParent = initialParent;
    PgnNode? lastNode;

    int i = startIndex;
    while (i < tokens.length) {
      final token = tokens[i];

      if (token == '(') {
        // Variation branches from the parent of lastNode (or currentParent if no lastNode)
        final variationParent = (lastNode != null && currentParent != initialParent)
            ? _findParent(initialParent, lastNode) ?? initialParent
            : initialParent;

        i = _buildTree(tokens, i + 1, variationParent);
      } else if (token == ')') {
        return i + 1;
      } else {
        // Normal move
        final node = PgnNode(san: token);
        currentParent.children.add(node);
        lastNode = node;
        currentParent = node;
        i++;
      }
    }
    return i;
  }

  static PgnNode? _findParent(PgnNode current, PgnNode target) {
    for (final child in current.children) {
      if (child == target) return current;
      final found = _findParent(child, target);
      if (found != null) return found;
    }
    return null;
  }
}
