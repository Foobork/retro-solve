import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

DatabaseFactory getPlatformDatabaseFactory() {
  return databaseFactoryFfiWeb;
}

String resolvePlatformDbPath(String dbName) => dbName;
