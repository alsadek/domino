import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/key_derivators/scrypt.dart';
import 'package:pointycastle/pointycastle.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../supabase/supabase_config.dart';

class AuthUser {
  final String userId;
  final String username;
  final String displayName;

  const AuthUser({
    required this.userId,
    required this.username,
    required this.displayName,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        userId: (json['userId'] as String? ?? '').trim(),
        username: (json['username'] as String? ?? '').trim(),
        displayName: (json['displayName'] as String? ?? json['username'] as String? ?? '').trim(),
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'displayName': displayName,
      };
}

class AuthResult {
  final bool ok;
  final AuthUser? user;
  final String? token;
  final String? message;

  const AuthResult({
    required this.ok,
    this.user,
    this.token,
    this.message,
  });
}

class AuthManager {
  static const String _tokenKey = 'domino_auth_token';
  static const String _userKey = 'domino_auth_user';

  static String _scryptHash(String pin, String saltHex) {
    final scrypt = Scrypt();
    scrypt.init(ScryptParameters(16384, 8, 1, 32, Uint8List.fromList(utf8.encode(saltHex))));
    final out = Uint8List(32);
    scrypt.deriveKey(Uint8List.fromList(utf8.encode(pin.trim())), 0, out, 0);
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _randomHex(int byteCount) {
    final rng = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String?> getSavedToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<AuthUser?> getCachedUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_userKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _persistSession(AuthUser user, String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
    await prefs.setString('domino_user_nickname', user.displayName);
  }

  static Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
  }

  static Future<AuthUser?> restoreSession() async {
    final token = await getSavedToken();
    if (token == null || token.isEmpty) return null;

    try {
      final res = await SupabaseConfig.client
          .from('user_sessions')
          .select('token, user_id, app_users(id, username, display_name)')
          .eq('token', token)
          .maybeSingle();

      if (res != null && res['app_users'] != null) {
        final u = res['app_users'] as Map<String, dynamic>;
        final user = AuthUser(
          userId: u['id'] as String? ?? res['user_id'] as String,
          username: u['username'] as String? ?? res['user_id'] as String,
          displayName: u['display_name'] as String? ?? u['username'] as String? ?? '',
        );
        await _persistSession(user, token);
        return user;
      }

      // If token wasn't found in DB, try cached fallback
      return await getCachedUser();
    } catch (_) {
      // Offline fallback
      return await getCachedUser();
    }
  }

  static Future<AuthResult> register({
    required String username,
    required String pin,
    String? displayName,
  }) async {
    final cleanUsername = username.trim().toLowerCase();
    if (cleanUsername.isEmpty || cleanUsername.length < 2) {
      return const AuthResult(ok: false, message: 'اسم المستخدم قصير جداً');
    }
    if (pin.trim().length < 4) {
      return const AuthResult(ok: false, message: 'رمز PIN يجب أن يتكون من 4 أرقام على الأقل');
    }

    try {
      final existing = await SupabaseConfig.client
          .from('app_users')
          .select('id')
          .eq('id', cleanUsername)
          .maybeSingle();

      if (existing != null) {
        return const AuthResult(ok: false, message: 'اسم المستخدم مسجل بالفعل، اختر اسماً آخر');
      }

      final salt = _randomHex(16);
      final pinHash = _scryptHash(pin, salt);
      final finalDisplayName =
          (displayName ?? '').trim().isEmpty ? username.trim() : displayName!.trim();

      await SupabaseConfig.client.from('app_users').insert({
        'id': cleanUsername,
        'username': username.trim(),
        'display_name': finalDisplayName,
        'salt': salt,
        'pin_hash': pinHash,
      });

      final token = 'usr_${_randomHex(24)}';
      await SupabaseConfig.client.from('user_sessions').insert({
        'token': token,
        'user_id': cleanUsername,
      });

      final user = AuthUser(
        userId: cleanUsername,
        username: username.trim(),
        displayName: finalDisplayName,
      );
      await _persistSession(user, token);
      return AuthResult(ok: true, user: user, token: token);
    } catch (e) {
      return AuthResult(ok: false, message: 'تعذر إنشاء الحساب: $e');
    }
  }

  static Future<AuthResult> login({
    required String username,
    required String pin,
  }) async {
    final cleanUsername = username.trim().toLowerCase();
    if (cleanUsername.isEmpty) {
      return const AuthResult(ok: false, message: 'يرجى إدخال اسم المستخدم');
    }

    try {
      final res = await SupabaseConfig.client
          .from('app_users')
          .select('id, username, display_name, salt, pin_hash')
          .eq('id', cleanUsername)
          .maybeSingle();

      if (res == null) {
        return const AuthResult(ok: false, message: 'اسم المستخدم غير موجود');
      }

      final salt = res['salt'] as String;
      final expectedHash = res['pin_hash'] as String;
      final actualHash = _scryptHash(pin, salt);

      if (actualHash != expectedHash) {
        return const AuthResult(ok: false, message: 'رمز PIN غير صحيح');
      }

      final token = 'usr_${_randomHex(24)}';
      await SupabaseConfig.client.from('user_sessions').insert({
        'token': token,
        'user_id': cleanUsername,
      });

      final user = AuthUser(
        userId: cleanUsername,
        username: res['username'] as String? ?? cleanUsername,
        displayName: res['display_name'] as String? ?? res['username'] as String? ?? cleanUsername,
      );
      await _persistSession(user, token);
      return AuthResult(ok: true, user: user, token: token);
    } catch (e) {
      return AuthResult(ok: false, message: 'تعذر الاتصال بـ Supabase: $e');
    }
  }

  static Future<void> logout() async {
    final token = await getSavedToken();
    if (token != null && token.isNotEmpty) {
      try {
        await SupabaseConfig.client.from('user_sessions').delete().eq('token', token);
      } catch (_) {}
    }
    await _clearSession();
  }
}
