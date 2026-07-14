import 'package:shared_preferences/shared_preferences.dart';

enum DatasetVariant {
  standard,
  koth,
  threeCheck,
  crazyhouse,
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

