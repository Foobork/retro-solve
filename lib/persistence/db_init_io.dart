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
