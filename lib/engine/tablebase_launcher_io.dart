import 'dart:io';
import 'package:flutter/foundation.dart';
import 'tablebase_launcher.dart';

TablebaseServerLauncher createTablebaseServerLauncher() =>
    TablebaseServerLauncherIo();

class TablebaseServerLauncherIo implements TablebaseServerLauncher {
  @override
  Future<bool> launchServer({
    required int port,
    required String host,
    String? scriptPath,
    String? atomicPath,
    String? antichessPath,
  }) async {
    final script = scriptPath ?? resolveScriptPath();
    if (script == null) {
      debugPrint('[tablebase_launcher] Could not locate tablebase_server.py');
      return false;
    }

    final python = await resolvePythonExecutable();
    if (python == null) {
      debugPrint('[tablebase_launcher] Could not locate Python executable (python, py, python3)');
      return false;
    }

    final atomic = atomicPath ?? resolveAtomicTbPath();
    final antichess = antichessPath ?? resolveAntichessTbPath();

    final args = <String>[
      script,
      '--host',
      host,
      '--port',
      port.toString(),
      '--managed',
      '--idle-timeout',
      '30',
    ];

    if (atomic != null) {
      args.addAll(['--atomic-tables', atomic]);
    }
    if (antichess != null) {
      args.addAll(['--antichess-tables', antichess]);
    }

    try {
      debugPrint('[tablebase_launcher] Launching sidecar: $python ${args.join(' ')}');
      await Process.start(
        python,
        args,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (e) {
      debugPrint('[tablebase_launcher] Failed to start server process: $e');
      return false;
    }
  }

  static String? resolveScriptPath() {
    final cwd = Directory.current.path;
    final exeDir = File(Platform.resolvedExecutable).parent.path;

    final candidates = <String>[
      '$cwd\\tool\\tablebase_server.py',
      '$cwd/tool/tablebase_server.py',
    ];

    var probe = Directory(cwd);
    for (var i = 0; i < 6; i++) {
      candidates.add('${probe.path}\\tool\\tablebase_server.py');
      candidates.add('${probe.path}/tool/tablebase_server.py');
      final parent = probe.parent;
      if (parent.path == probe.path) break;
      probe = parent;
    }

    candidates.add('$exeDir\\tool\\tablebase_server.py');
    candidates.add('$exeDir/tool/tablebase_server.py');
    candidates.add('$exeDir\\tablebase_server.py');
    candidates.add('$exeDir/tablebase_server.py');

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static Future<String?> resolvePythonExecutable() async {
    final candidates = Platform.isWindows
        ? const ['pythonw', 'python', 'py', 'python3']
        : const ['python3', 'python'];
    for (final cmd in candidates) {
      try {
        final result = await Process.run(cmd, ['--version']);
        if (result.exitCode == 0) {
          return cmd;
        }
      } catch (_) {
        // Try next candidate
      }
    }
    return null;
  }

  static String? resolveAtomicTbPath() {
    final cwd = Directory.current.path;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$cwd\\data\\tablebases\\atomic',
      '$cwd/data/tablebases/atomic',
    ];

    var probe = Directory(cwd);
    for (var i = 0; i < 6; i++) {
      candidates.add('${probe.path}\\data\\tablebases\\atomic');
      candidates.add('${probe.path}/data/tablebases/atomic');
      final parent = probe.parent;
      if (parent.path == probe.path) break;
      probe = parent;
    }

    candidates.add('$exeDir\\data\\tablebases\\atomic');
    candidates.add('$exeDir/data/tablebases/atomic');

    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String? resolveAntichessTbPath() {
    final cwd = Directory.current.path;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$cwd\\data\\tablebases\\antichess',
      '$cwd/data/tablebases/antichess',
    ];

    var probe = Directory(cwd);
    for (var i = 0; i < 6; i++) {
      candidates.add('${probe.path}\\data\\tablebases\\antichess');
      candidates.add('${probe.path}/data/tablebases/antichess');
      final parent = probe.parent;
      if (parent.path == probe.path) break;
      probe = parent;
    }

    candidates.add('$exeDir\\data\\tablebases\\antichess');
    candidates.add('$exeDir/data/tablebases/antichess');

    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    return null;
  }
}
