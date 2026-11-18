import 'package:flutter/services.dart';

/// Cross-platform haptic and vibration helper.
/// Works across native iOS (Taptic Engine / CoreHaptics), native Android (Vibrator),
/// and Web browsers that support haptics / Vibration API.
class VibrationHelper {
  /// Triggers a noticeable double-pulse vibration pattern when it becomes the player's turn ("دوري يجي").
  static Future<void> vibrateTurnArrival() async {
    try {
      await HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 90));
      await HapticFeedback.vibrate();
      await Future.delayed(const Duration(milliseconds: 90));
      await HapticFeedback.heavyImpact();
    } catch (_) {
      try {
        await HapticFeedback.vibrate();
      } catch (_) {}
    }
  }

  /// Single crisp feedback for tile placement.
  static Future<void> lightFeedback() async {
    try {
      await HapticFeedback.lightImpact();
    } catch (_) {}
  }
}
