import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _ffiInitialized = false;

DatabaseFactory getPlatformDatabaseFactory() {
  if (Platform.isWindows || Platform.isLinux) {
    if (!_ffiInitialized) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      _ffiInitialized = true;
    }
    return databaseFactoryFfi;
  }
  return databaseFactory;
}

String resolvePlatformDbPath(String dbName) {
  final cleanName = dbName.replaceAll('\\', '/').split('/').last;

  // 1. Direct checks
  if (File(dbName).existsSync()) return File(dbName).absolute.path;
  if (File('data/$cleanName').existsSync()) {
    return File('data/$cleanName').absolute.path;
  }

  // 2. Search ascending parent directories from cwd
  final cwd = Directory.current.path;
  var probe = Directory(cwd);
  for (var i = 0; i < 6; i++) {
    final candidate1 = File('${probe.path}/$cleanName');
    if (candidate1.existsSync()) return candidate1.absolute.path;
    final candidate2 = File('${probe.path}/data/$cleanName');
    if (candidate2.existsSync()) return candidate2.absolute.path;
    final parent = probe.parent;
    if (parent.path == probe.path) break;
    probe = parent;
  }

  // 3. Search near the executable
  try {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidateExe1 = File('${exeDir.path}/$cleanName');
    if (candidateExe1.existsSync()) return candidateExe1.absolute.path;
    final candidateExe2 = File('${exeDir.path}/data/$cleanName');
    if (candidateExe2.existsSync()) return candidateExe2.absolute.path;
    final candidateAsset =
        File('${exeDir.path}/data/flutter_assets/data/$cleanName');
    if (candidateAsset.existsSync()) return candidateAsset.absolute.path;
  } catch (_) {}

  // 4. Default fallback: create/use data/ subdirectory
  final defaultDataDir = Directory('data');
  if (!defaultDataDir.existsSync()) {
    try {
      defaultDataDir.createSync(recursive: true);
    } catch (_) {}
  }
  return File('data/$cleanName').absolute.path;
}
