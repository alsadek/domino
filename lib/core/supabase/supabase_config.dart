import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String publishableKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> initialize() async {
    if (!isConfigured) {
      debugPrint('SupabaseConfig: SUPABASE_URL or SUPABASE_ANON_KEY not set. Operating in offline mode.');
      return;
    }

    // ignore: deprecated_member_use
    await Supabase.initialize(
      url: url,
      // ignore: deprecated_member_use
      anonKey: publishableKey,
    );
  }
}
