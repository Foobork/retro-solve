import 'tablebase_launcher.dart';

TablebaseServerLauncher createTablebaseServerLauncher() =>
    TablebaseServerLauncherStub();

class TablebaseServerLauncherStub implements TablebaseServerLauncher {
  @override
  Future<bool> launchServer({
    required int port,
    required String host,
    String? scriptPath,
    String? atomicPath,
    String? antichessPath,
  }) async =>
      false;
}
