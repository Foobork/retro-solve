import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:retro_solve/config.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/tablebase_launcher.dart';
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
      expect(TablebaseService.instance.isEnabled, isTrue);
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
      expect(evals.first.dtw, equals(1));
    });

    test('parseTablebaseResponse handles Standard chess with dtm as DTW', () {
      const fen = '8/8/8/8/8/4k3/8/4K2Q w - - 0 1';
      final jsonStr = jsonEncode({
        'category': 'win',
        'checkmate': false,
        'variant_win': false,
        'variant_loss': false,
        'insufficient_material': false,
        'dtz': 9,
        'precise_dtz': 9,
        'dtm': 9,
        'dtw': null,
        'moves': [
          {
            'uci': 'h1d5',
            'san': 'Qd5',
            'category': 'loss',
            'dtz': -8,
            'precise_dtz': -8,
            'dtm': -8,
            'dtw': null,
            'checkmate': false,
            'variant_win': false,
          },
          {
            'uci': 'h1f3',
            'san': 'Qf3+',
            'category': 'draw',
            'dtz': 0,
            'precise_dtz': 0,
            'dtm': 0,
            'dtw': null,
            'checkmate': false,
            'variant_win': false,
          }
        ],
      });

      final evals = TablebaseService.parseTablebaseResponse(
        DatasetVariant.standard,
        fen,
        jsonStr,
      );

      expect(evals, isNotNull);
      expect(evals!.length, equals(2));

      // 1st move: Qd5 (mate in 5 moves / 9 plies)
      final m1 = evals[0];
      expect(m1.candidateMove, equals('h1d5'));
      expect(m1.dtw, equals(9));
      expect(m1.mate, equals(5));

      // 2nd move: Qf3+ (draw)
      final m2 = evals[1];
      expect(m2.candidateMove, equals('h1f3'));
      expect(m2.dtw, isNull);
      expect(m2.mate, isNull);
      expect(m2.centipawns, equals(0));
    });

    test('parseTablebaseResponse handles 4-piece Atomic DTW evaluation (e.g. KRvKN Re1+)', () {
      const fen = '8/8/8/8/7K/4R3/8/5kn1 w - - 0 1';
      final jsonStr = jsonEncode({
        'category': 'win',
        'dtw': 3,
        'dtm': 2,
        'dtz': 3,
        'moves': [
          {
            'uci': 'e3e1',
            'san': 'Re1+',
            'category': 'loss',
            'dtw': -2,
            'dtm': -1,
            'dtz': -2,
          },
          {
            'uci': 'h4h5',
            'san': 'Kh5',
            'category': 'draw',
            'dtw': 0,
            'dtm': null,
            'dtz': 0,
          },
          {
            'uci': 'e3h3',
            'san': 'Rh3',
            'category': 'win',
            'dtw': 1,
            'dtm': 1,
            'dtz': 1,
          },
        ],
      });

      final evals = TablebaseService.parseTablebaseResponse(
        DatasetVariant.atomic,
        fen,
        jsonStr,
      );

      expect(evals, isNotNull);
      expect(evals!.length, equals(3));

      // 1st move: Re1+ wins in 3 plies (+M2)
      final m1 = evals[0];
      expect(m1.candidateMove, equals('e3e1'));
      expect(m1.dtw, equals(3));
      expect(m1.mate, equals(2));
      expect(m1.centipawns, isNull);

      // 2nd move: Kh5 is a draw
      final m2 = evals[1];
      expect(m2.candidateMove, equals('h4h5'));
      expect(m2.dtw, isNull);
      expect(m2.mate, isNull);
      expect(m2.centipawns, equals(0));

      // 3rd move: Rh3 loses in 2 plies (-M1)
      final m3 = evals[2];
      expect(m3.candidateMove, equals('e3h3'));
      expect(m3.dtw, equals(2));
      expect(m3.mate, equals(-1));
      expect(m3.centipawns, isNull);
    });

    test('probe prioritizes local sidecar when localEnabled is true', () async {
      const fen = '4k3/4P3/8/8/8/8/8/4K3 w - - 0 1';
      final requests = <Uri>[];
      final mockClient = MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == '127.0.0.1') {
          return http.Response(
            jsonEncode({
              'category': 'win',
              'dtz': 1,
              'dtw': 3,
              'moves': [
                {
                  'uci': 'e1f2',
                  'san': 'Kf2',
                  'category': 'loss',
                  'dtz': -2,
                  'dtw': -2,
                }
              ],
            }),
            200,
          );
        }
        return http.Response('Unexpected remote probe', 500);
      });

      final service = TablebaseService(
        client: mockClient,
        localEnabled: true,
        enabled: true,
      );

      final evals = await service.probe(DatasetVariant.atomic, fen);
      expect(evals, isNotNull);
      expect(evals!.length, equals(1));
      expect(evals.first.candidateMove, equals('e1f2'));
      expect(evals.first.mate, equals(2)); // (2 + 1) ~/ 2 = 2
      expect(evals.first.dtw, equals(3));  // 2 + 1 = 3
      expect(requests.length, equals(1));
      expect(requests.first.host, equals('127.0.0.1'));
    });

    test('probe does not fall back to remote when local sidecar is enabled to prevent throttling', () async {
      const fen = '4k3/4P3/8/8/8/8/8/4K3 w - - 0 1';
      final requests = <Uri>[];
      final mockClient = MockClient((request) async {
        requests.add(request.url);
        return http.Response('Local sidecar unavailable', 500);
      });

      final service = TablebaseService(
        client: mockClient,
        localEnabled: true,
        enabled: true,
      );

      final evals = await service.probe(DatasetVariant.atomic, fen);
      expect(evals, isNull);
      expect(requests.length, equals(1));
      expect(requests[0].host, equals('127.0.0.1'));
    });

    test('probe returns immediate variant win via local sidecar', () async {
      const fen = '4k3/3Q4/8/8/8/8/8/K7 w - - 0 1';
      final mockClient = MockClient((request) async {
        expect(request.url.host, equals('127.0.0.1'));
        return http.Response(
          jsonEncode({
            'category': 'win',
            'dtz': 0,
            'dtw': null,
            'checkmate': false,
            'variant_win': false,
            'moves': [
              {
                'uci': 'd7e8',
                'san': 'Qxe8#',
                'category': 'loss',
                'dtz': 0,
                'dtw': -1,
                'checkmate': false,
                'variant_win': true,
              }
            ],
          }),
          200,
        );
      });

      final service = TablebaseService(
        client: mockClient,
        localEnabled: true,
      );

      final evals = await service.probe(DatasetVariant.atomic, fen);
      expect(evals, isNotNull);
      expect(evals!.first.candidateMove, equals('d7e8'));
      expect(evals.first.mate, equals(1));
      expect(evals.first.dtw, equals(1));
    });

    test('probe retains tablebase win as +Mate pseudomate when DTW is null', () async {
      const fen = '4k3/4P3/8/8/8/8/8/4K3 w - - 0 1';
      final mockClient = MockClient((request) async {
        expect(request.url.host, equals('127.0.0.1'));
        return http.Response(
          jsonEncode({
            'category': 'win',
            'dtz': 1,
            'dtw': null,
            'checkmate': false,
            'variant_win': false,
            'moves': [
              {
                'uci': 'e1f2',
                'san': 'Kf2',
                'category': 'loss',
                'dtz': -2,
                'dtw': null,
              }
            ],
          }),
          200,
        );
      });

      final service = TablebaseService(
        client: mockClient,
        localEnabled: true,
      );

      final evals = await service.probe(DatasetVariant.atomic, fen);
      expect(evals, isNotNull);
      expect(evals!.length, equals(1));
      expect(evals.first.candidateMove, equals('e1f2'));
      expect(evals.first.mate, isNull);
      expect(evals.first.dtw, isNull);
      expect(evals.first.centipawns, equals(20000));
      expect(evals.first.isPseudoMate, isTrue);
    });

    group('Tablebase Sidecar Server Lifecycle & Multi-Instance Tests', () {
      test('checkHealth returns true on 200 and false on error', () async {
        final okClient = MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response(jsonEncode({'status': 'ok'}), 200);
          }
          return http.Response('Not Found', 404);
        });
        final okService = TablebaseService(client: okClient, localEnabled: true);
        expect(await okService.checkHealth(), isTrue);

        final errClient = MockClient((request) async => throw Exception('Connection refused'));
        final errService = TablebaseService(client: errClient, localEnabled: true);
        expect(await errService.checkHealth(), isFalse);
      });

      test('client registration and heartbeat send client_id and maintain active status', () async {
        final registeredClients = <String>[];
        final heartbeats = <String>[];
        final unregisters = <String>[];

        final mockClient = MockClient((request) async {
          final cid = request.url.queryParameters['client_id'];
          if (request.url.path == '/health') {
            return http.Response(jsonEncode({'status': 'ok'}), 200);
          } else if (request.url.path == '/client/register') {
            if (cid != null) registeredClients.add(cid);
            return http.Response(jsonEncode({'status': 'ok', 'client_id': cid, 'clients': 1}), 200);
          } else if (request.url.path == '/client/heartbeat') {
            if (cid != null) heartbeats.add(cid);
            return http.Response(jsonEncode({'status': 'ok', 'client_id': cid, 'clients': 1}), 200);
          } else if (request.url.path == '/client/unregister') {
            if (cid != null) unregisters.add(cid);
            return http.Response(jsonEncode({'status': 'ok', 'client_id': cid, 'clients': 0}), 200);
          }
          return http.Response('Not Found', 404);
        });

        final service = TablebaseService(
          client: mockClient,
          localEnabled: true,
          clientId: 'test-client-123',
        );

        expect(service.isRegistered, isFalse);
        final regOk = await service.registerClient();
        expect(regOk, isTrue);
        expect(service.isRegistered, isTrue);
        expect(registeredClients, contains('test-client-123'));

        final hbOk = await service.sendHeartbeat();
        expect(hbOk, isTrue);
        expect(heartbeats, contains('test-client-123'));

        await service.unregisterClient();
        expect(service.isRegistered, isFalse);
        expect(unregisters, contains('test-client-123'));
      });

      test('ensureServerRunning connects to already running server without launching', () async {
        var launchAttempted = false;
        final mockLauncher = _MockServerLauncher(onLaunch: () {
          launchAttempted = true;
          return true;
        });

        final mockClient = MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response(jsonEncode({'status': 'ok'}), 200);
          } else if (request.url.path == '/client/register') {
            return http.Response(jsonEncode({'status': 'ok'}), 200);
          }
          return http.Response('Not Found', 404);
        });

        final service = TablebaseService(
          client: mockClient,
          localEnabled: true,
          autoLaunch: true,
          launcher: mockLauncher,
        );

        final result = await service.ensureServerRunning();
        expect(result, isTrue);
        expect(service.isRegistered, isTrue);
        expect(launchAttempted, isFalse);
        service.dispose();
      });

      test('ensureServerRunning auto-launches server if offline and polls until ready', () async {
        var isServerUp = false;
        var launchAttempted = false;
        final mockLauncher = _MockServerLauncher(onLaunch: () {
          launchAttempted = true;
          // Simulate server spinning up shortly after launch
          Future.delayed(const Duration(milliseconds: 100), () {
            isServerUp = true;
          });
          return true;
        });

        final mockClient = MockClient((request) async {
          if (!isServerUp) {
            throw Exception('Connection refused');
          }
          if (request.url.path == '/health') {
            return http.Response(jsonEncode({'status': 'ok'}), 200);
          } else if (request.url.path == '/client/register') {
            return http.Response(jsonEncode({'status': 'ok'}), 200);
          }
          return http.Response('Not Found', 404);
        });

        final service = TablebaseService(
          client: mockClient,
          localEnabled: true,
          autoLaunch: true,
          launcher: mockLauncher,
        );

        final result = await service.ensureServerRunning(timeout: const Duration(seconds: 3));
        expect(result, isTrue);
        expect(launchAttempted, isTrue);
        expect(service.isRegistered, isTrue);
        service.dispose();
      });

      test('multiple retrosolve instances maintain independent client registrations', () async {
        final activeClients = <String>{};

        final mockClient = MockClient((request) async {
          final cid = request.url.queryParameters['client_id'];
          if (request.url.path == '/health') {
            return http.Response(jsonEncode({'status': 'ok', 'clients': activeClients.length}), 200);
          } else if (request.url.path == '/client/register') {
            if (cid != null) activeClients.add(cid);
            return http.Response(jsonEncode({'status': 'ok', 'client_id': cid, 'clients': activeClients.length}), 200);
          } else if (request.url.path == '/client/heartbeat') {
            return http.Response(jsonEncode({'status': 'ok', 'client_id': cid, 'clients': activeClients.length}), 200);
          } else if (request.url.path == '/client/unregister') {
            if (cid != null) activeClients.remove(cid);
            return http.Response(jsonEncode({'status': 'ok', 'client_id': cid, 'clients': activeClients.length}), 200);
          }
          return http.Response('Not Found', 404);
        });

        final instanceA = TablebaseService(
          client: mockClient,
          localEnabled: true,
          clientId: 'instance-A',
        );
        final instanceB = TablebaseService(
          client: mockClient,
          localEnabled: true,
          clientId: 'instance-B',
        );

        expect(instanceA.clientId, isNot(equals(instanceB.clientId)));

        // Both register
        await instanceA.ensureServerRunning();
        await instanceB.ensureServerRunning();

        expect(activeClients, contains('instance-A'));
        expect(activeClients, contains('instance-B'));
        expect(activeClients.length, equals(2));

        // Instance A shuts down / unregisters
        await instanceA.unregisterClient();
        expect(activeClients, isNot(contains('instance-A')));
        expect(activeClients, contains('instance-B'));
        expect(activeClients.length, equals(1));

        // Instance B shuts down / unregisters
        await instanceB.unregisterClient();
        expect(activeClients.isEmpty, isTrue);

        instanceA.dispose();
        instanceB.dispose();
      });
    });
  });
}

class _MockServerLauncher implements TablebaseServerLauncher {
  _MockServerLauncher({required this.onLaunch});
  final bool Function() onLaunch;

  @override
  Future<bool> launchServer({
    required int port,
    required String host,
    String? scriptPath,
    String? atomicPath,
    String? antichessPath,
  }) async {
    return onLaunch();
  }
}
