import 'package:shared_preferences/shared_preferences.dart';

enum DatasetVariant {
  standard,
  koth,
  threeCheck,
  crazyhouse,
  antichess,
  atomic,
  horde,
  racingKings,
}

extension DatasetVariantX on DatasetVariant {
  String get label {
    switch (this) {
      case DatasetVariant.standard:
        return 'Standard';
      case DatasetVariant.koth:
        return 'KOTH';
      case DatasetVariant.threeCheck:
        return 'Three-Check';
      case DatasetVariant.crazyhouse:
        return 'Crazyhouse';
      case DatasetVariant.antichess:
        return 'Antichess';
      case DatasetVariant.atomic:
        return 'Atomic';
      case DatasetVariant.horde:
        return 'Horde';
      case DatasetVariant.racingKings:
        return 'Racing Kings';
    }
  }

  String get dataPath {
    switch (this) {
      case DatasetVariant.standard:
        return 'data/Standard.txt';
      case DatasetVariant.koth:
        return 'data/KOTH.txt';
      case DatasetVariant.threeCheck:
        return 'data/ThreeCheck.txt';
      case DatasetVariant.crazyhouse:
        return 'data/Crazyhouse.txt';
      case DatasetVariant.antichess:
        return 'data/Antichess.txt';
      case DatasetVariant.atomic:
        return 'data/Atomic.txt';
      case DatasetVariant.horde:
        return 'data/Horde.txt';
      case DatasetVariant.racingKings:
        return 'data/RacingKings.txt';
    }
  }

  String get preferenceValue => toString().split('.').last;

  static DatasetVariant fromPreferenceValue(String? value) {
    if (value == null) return DatasetVariant.koth;
    for (final v in DatasetVariant.values) {
      if (v.toString().split('.').last == value) return v;
    }
    return DatasetVariant.koth;
  }
}

class DatasetVariantStore {
  static const _key = 'dataset_variant';

  static Future<DatasetVariant> load() async {
    final prefs = await SharedPreferences.getInstance();
    return DatasetVariantX.fromPreferenceValue(prefs.getString(_key));
  }

  static Future<void> save(DatasetVariant variant) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, variant.preferenceValue);
  }
}

class SolveOnStartupStore {
  static const _key = 'solve_on_startup';

  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  static Future<void> save(bool solveOnStartup) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, solveOnStartup);
  }
}

class InteractiveBacksolvingStore {
  static const _key = 'interactive_backsolving';

  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> save(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, enabled);
    } catch (_) {}
  }
}

class TablebaseStore {
  static const _key = 'enable_tablebase';

  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> save(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, enabled);
    } catch (_) {}
  }
}

class AutosolveAfterExploreStore {
  static const _key = 'autosolve_after_explore';

  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> save(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, enabled);
    } catch (_) {}
  }
}

