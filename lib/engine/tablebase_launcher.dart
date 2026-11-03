import 'tablebase_launcher_stub.dart'
    if (dart.library.io) 'tablebase_launcher_io.dart';

abstract class TablebaseServerLauncher {
  factory TablebaseServerLauncher() => createTablebaseServerLauncher();

  /// Attempts to launch the tablebase sidecar server.
  ///
  /// Returns `true` if the server process was successfully spawned or already running.
  Future<bool> launchServer({
    required int port,
    required String host,
    String? scriptPath,
    String? atomicPath,
    String? antichessPath,
  });
}
