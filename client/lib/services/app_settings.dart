import 'package:flutter/foundation.dart';

/// 可用字体选项（key: Flutter fontFamily 名，value: 显示名）
const Map<String, String> kAvailableFonts = {'': '系统默认', 'MiSans': 'MiSans'};

class AppSettings extends ChangeNotifier {
  String _fontFamily = 'MiSans'; // 默认使用 MiSans

  /// 当前字体族名（null = 系统默认，传给 ThemeData.fontFamily）
  String? get fontFamily => _fontFamily.isEmpty ? null : _fontFamily;

  /// 当前字体 key
  String get fontKey => _fontFamily;

  void setFontFamily(String key) {
    if (_fontFamily == key) return;
    _fontFamily = key;
    notifyListeners();
  }
}
