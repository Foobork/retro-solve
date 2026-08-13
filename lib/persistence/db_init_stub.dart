import 'package:sqflite_common/sqlite_api.dart';

DatabaseFactory getPlatformDatabaseFactory() {
  throw UnsupportedError('Unsupported platform');
}

String resolvePlatformDbPath(String dbName) => dbName;
