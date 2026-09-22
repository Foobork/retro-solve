import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:retro_solve/config.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/tablebase_service.dart';

void main() {
  group('TablebaseService Tests', () {
    test('isSupported checks variant and piece count limits', () {
      // 4 pieces in Antichess (<= 6)
      expect(
        TablebaseService.isSupported(
          DatasetVariant.antichess,
          '8/8/8/8/8/8/p7/2B1B1B1 w - - 0 1',
        ),
        isTrue,
      );

      // 7 pieces in Antichess (> 6)
      expect(
        TablebaseService.isSupported(
          DatasetVariant.antichess,
          '8/8/8/8/8/8/pppp4/2B1B1B1 w - - 0 1',
        ),
        isFalse,
      );

      // 6 pieces in Atomic (<= 6)
      expect(
        TablebaseService.isSupported(
          DatasetVariant.atomic,
          '8/8/8/8/8/2k5/4p3/2B1K1B1 w - - 0 1',
        ),
        isTrue,
      );

      // 7 pieces in Atomic (> 6)
      expect(
        TablebaseService.isSupported(
          DatasetVariant.atomic,
          '8/8/8/8/8/2k5/3ppp2/2B1K1B1 w - - 0 1',
        ),
        isFalse,
      );

      // 7 pieces in Standard Chess (<= 7)
      expect(
        TablebaseService.isSupported(
          DatasetVariant.standard,
          '8/8/8/8/8/2k5/3ppp2/2B1K1B1 w - - 0 1',
        ),
        isTrue,
      );

      // 8 pieces in Standard Chess (> 7)
      expect(
        TablebaseService.isSupported(
          DatasetVariant.standard,
          '8/8/8/8/8/2k5/3pppp1/2B1K1B1 w - - 0 1',
        ),
        isFalse,
      );

      // Unsupported variants
      expect(
        TablebaseService.isSupported(
          DatasetVariant.koth,
          '8/8/8/8/8/8/4k3/4K3 w - - 0 1',
        ),
        isFalse,
      );
      expect(
        TablebaseService.isSupported(
          DatasetVariant.crazyhouse,
          '8/8/8/8/8/8/4k3/4K3 w - - 0 1',
        ),
        isFalse,
      );
    });

    test('parseTablebaseResponse correctly converts winning position and candidate moves', () {
      const fen = '8/8/8/8/8/8/p7/2B1B1B1 w - - 0 1';
      final jsonStr = jsonEncode({
        'category': 'win',
        'dtw': 14,
        'dtz': 3,
        'moves': [
          {
            'uci': 'c1d2',
            'san': 'Bcd2',
            'category': 'loss', // Opponent loses in 13 plies -> side to move wins in 14 plies (M7)
            'dtw': -13,
            'dtz': -1,
          },
          {
            'uci': 'e1h4',
            'san': 'Bh4',
            'category': 'draw',
            'dtw': 0,
            'dtz': 0,
          },
          {
            'uci': 'e1f2',
            'san': 'Bef2',
            'category': 'win', // Opponent wins in 6 plies -> side to move loses in 7 plies (-M4)
            'dtw': 6,
            'dtz': 1,
          },
        ],
      });

      final evals = TablebaseService.parseTablebaseResponse(
        DatasetVariant.antichess,
        fen,
        jsonStr,
      );

      expect(evals, isNotNull);
      expect(evals!.length, equals(3));

      // 1st move: winning move
      final m1 = evals[0];
      expect(m1.candidateMove, equals('c1d2'));
      expect(m1.multipv, equals(1));
      expect(m1.depth, equals(100));
      expect(m1.mate, equals(7)); // (13 + 1 + 1) ~/ 2 = 7
      expect(m1.centipawns, isNull);

      // 2nd move: draw move
      final m2 = evals[1];
      expect(m2.candidateMove, equals('e1h4'));
      expect(m2.multipv, equals(2));
      expect(m2.mate, isNull);
      expect(m2.centipawns, equals(0));

      // 3rd move: losing move
      final m3 = evals[2];
      expect(m3.candidateMove, equals('e1f2'));
      expect(m3.multipv, equals(3));
      expect(m3.mate, equals(-4)); // -((6 + 1 + 1) ~/ 2) = -4
      expect(m3.centipawns, isNull);
    });

    test('parseTablebaseResponse handles losing positions correctly', () {
      const fen = '8/8/8/8/8/8/p7/2B1B1B1 b - - 0 1';
      final jsonStr = jsonEncode({
        'category': 'loss',
        'dtw': -13,
        'dtz': -1,
        'moves': [
          {
            'uci': 'a2a1n',
            'san': 'a1=N',
            'category': 'win', // Opponent wins in 12 plies -> side to move loses in 13 plies (-M7)
            'dtw': 12,
            'dtz': 3,
          },
        ],
      });

      final evals = TablebaseService.parseTablebaseResponse(
        DatasetVariant.antichess,
        fen,
        jsonStr,
      );

      expect(evals, isNotNull);
      expect(evals!.length, equals(1));
      expect(evals.first.candidateMove, equals('a2a1n'));
      expect(evals.first.mate, equals(-7)); // -((12 + 1 + 1) ~/ 2) = -7
      expect(evals.first.depth, equals(100));
    });

    test('parseTablebaseResponse handles draw positions correctly', () {
      const fen = '8/8/8/8/8/8/8/b1B5 w - - 0 1';
      final jsonStr = jsonEncode({
        'category': 'draw',
        'dtw': 0,
        'dtz': 0,
        'moves': [
          {
            'uci': 'c1b2',
            'category': 'draw',
            'dtw': 0,
            'dtz': 0,
          },
        ],
      });

      final evals = TablebaseService.parseTablebaseResponse(
        DatasetVariant.antichess,
        fen,
        jsonStr,
      );

      expect(evals, isNotNull);
      expect(evals!.first.centipawns, equals(0));
      expect(evals.first.mate, isNull);
      expect(evals.first.depth, equals(100));
    });

    test('parseTablebaseResponse returns null for unknown category', () {
      const fen = '8/8/8/8/8/8/p7/2B1B1B1 w - - 0 1';
      final jsonStr = jsonEncode({'category': 'unknown'});

      final evals = TablebaseService.parseTablebaseResponse(
        DatasetVariant.antichess,
        fen,
        jsonStr,
      );

      expect(evals, isNull);
    });

    test('probe queries endpoint via MockClient successfully', () async {
      const fen = '8/8/8/8/8/8/p7/2B1B1B1 w - - 0 1';
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/antichess'));
        expect(request.url.queryParameters['fen'], equals(fen));
        return http.Response(
          jsonEncode({
            'category': 'win',
            'dtw': 14,
            'dtz': 3,
            'moves': [
              {
                'uci': 'c1d2',
                'category': 'loss',
                'dtw': -13,
                'dtz': -1,
              }
            ],
          }),
          200,
        );
      });

      final service = TablebaseService(client: mockClient, enabled: true);
      final evals = await service.probe(DatasetVariant.antichess, fen);

      expect(evals, isNotNull);
      expect(evals!.length, equals(1));
      expect(evals.first.candidateMove, equals('c1d2'));
      expect(evals.first.mate, equals(7));
    });

    test('probe gracefully handles HTTP errors and network failures', () async {
      const fen = '8/8/8/8/8/8/p7/2B1B1B1 w - - 0 1';
      final errorClient = MockClient((request) async {
        return http.Response('Server Error', 500);
      });

      final service = TablebaseService(client: errorClient, enabled: true);
      final evals = await service.probe(DatasetVariant.antichess, fen);
      expect(evals, isNull);
    });

    test('probe returns null when tablebase is disabled', () async {
      const fen = '8/8/8/8/8/8/p7/2B1B1B1 w - - 0 1';
      final service = TablebaseService(enabled: false);
      final evals = await service.probe(DatasetVariant.antichess, fen);
      expect(evals, isNull);
    });

    test('TablebaseService.instance respects Config.enableRemoteTablebase', () {
      expect(TablebaseService.instance.isEnabled, equals(Config.enableRemoteTablebase));
      expect(TablebaseService.instance.isEnabled, isFalse);
    });

    test('parseTablebaseResponse handles 6-piece position with DTZ and null DTW without claiming mate in 1', () {
      const fen = '8/8/5K2/p1p4p/7p/8/8/6r1 b - - 0 1';
      final jsonStr = jsonEncode({
        'category': 'win',
        'dtz': 2,
        'dtw': null,
        'checkmate': false,
        'variant_win': false,
        'moves': [
          {
            'uci': 'g1g5',
            'san': 'Rg5',
            'category': 'loss', // Winning move for Black
            'dtz': -1,
            'dtw': null,
            'checkmate': false,
            'variant_win': false,
          },
          {
            'uci': 'g1g6',
            'san': 'Rg6',
            'category': 'loss', // Winning move for Black
            'dtz': -1,
            'dtw': null,
            'checkmate': false,
            'variant_win': false,
          },
          {
            'uci': 'g1a1',
            'san': 'Ra1',
            'category': 'win', // Losing move for Black
            'dtz': 3,
            'dtw': null,
            'checkmate': false,
            'variant_win': false,
          },
        ],
      });

      final evals = TablebaseService.parseTablebaseResponse(
        DatasetVariant.antichess,
        fen,
        jsonStr,
      );

      expect(evals, isNotNull);
      expect(evals!.length, equals(3));

      // Rg5: Black is winning, but DTW is null -> pseudomate (+Mate / -Mate)
      final m1 = evals[0];
      expect(m1.candidateMove, equals('g1g5'));
      expect(m1.mate, isNull, reason: 'Must not be treated as Mate 1 when DTW is null');
      expect(m1.centipawns, equals(20000));
      expect(m1.isPseudoMate, isTrue);
      expect(m1.depth, equals(100));

      // In White perspective (Black to move):
      final m1White = m1.asWhitePerspective(whiteToMove: false);
      expect(m1White.centipawns, equals(-20000)); // Black winning
      expect(m1White.mate, isNull);
      expect(m1White.toString().contains('-Mate'), isTrue);

      // Rg6: also winning for Black
      final m2 = evals[1];
      expect(m2.candidateMove, equals('g1g6'));
      expect(m2.mate, isNull);
      expect(m2.centipawns, equals(20000));

      // Ra1: losing for Black
      final m3 = evals[2];
      expect(m3.candidateMove, equals('g1a1'));
      expect(m3.mate, isNull);
      expect(m3.centipawns, equals(-20000));
      final m3White = m3.asWhitePerspective(whiteToMove: false);
      expect(m3White.centipawns, equals(20000)); // White winning
      expect(m3White.toString().contains('+Mate'), isTrue);
    });

    test('parseTablebaseResponse detects immediate variant win even if DTW is null', () {
      const fen = '8/8/8/8/8/8/8/1B6 w - - 0 1';
      final jsonStr = jsonEncode({
        'category': 'win',
        'checkmate': false,
        'variant_win': false,
        'moves': [
          {
            'uci': 'b1a2',
            'category': 'loss',
            'dtz': 0,
            'dtw': null,
            'checkmate': false,
            'variant_win': true,
          }
        ],
      });

      final evals = TablebaseService.parseTablebaseResponse(
        DatasetVariant.antichess,
        fen,
        jsonStr,
      );

      expect(evals, isNotNull);
      expect(evals!.length, equals(1));
      expect(evals.first.candidateMove, equals('b1a2'));
      expect(evals.first.mate, equals(1));
    });
  });
}
