/// 深色导航蓝 + 琥珀黄主题（参考厂家界面配色）
library;

import 'package:flutter/material.dart';

class AppColors {
  /// 整体背景（深藏蓝）
  static const bg = Color(0xFF141B2E);

  /// 面板/参数栏背景
  static const panel = Color(0xFF1B2440);

  /// 更深的底栏/工具栏
  static const panelDark = Color(0xFF10162A);

  /// 卡片/悬浮
  static const card = Color(0xFF232D4D);

  /// 主强调（琥珀黄）
  static const accent = Color(0xFFF5C518);

  /// 次级强调（亮黄）
  static const accentSoft = Color(0xFFE8B93E);

  /// 预览区背景（近黑）
  static const previewBg = Color(0xFF0A0E1A);

  /// 框线/分隔
  static const divider = Color(0xFF2C3657);

  /// 正文
  static const text = Color(0xFFE8ECF6);

  /// 次要文字
  static const textDim = Color(0xFF9AA5C0);

  /// 成功
  static const ok = Color(0xFF4CAF50);

  /// 错误
  static const err = Color(0xFFE05555);

  /// 预览裁剪框（绿色）
  static const guide = Color(0xFF3DDC5A);
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      secondary: AppColors.accentSoft,
      surface: AppColors.panel,
      onSurface: AppColors.text,
      error: AppColors.err,
    ),
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: 'Microsoft YaHei',
  );
  return base.copyWith(
    dropdownMenuTheme: const DropdownMenuThemeData(
      textStyle: TextStyle(color: AppColors.text, fontSize: 13),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(color: AppColors.text, fontSize: 12),
    ),
  );
}
