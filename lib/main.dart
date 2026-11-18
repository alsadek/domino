import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'core/supabase/supabase_config.dart';
import 'features/game_board/presentation/game_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  try {
    await SupabaseConfig.initialize();
  } catch (e) {
    debugPrint('Supabase initialization failed: $e');
  }

  runApp(const DominoMasriApp());
}

class DominoMasriApp extends StatelessWidget {
  const DominoMasriApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'الدومينو الأمريكاني',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF19110B),
        textTheme: GoogleFonts.cairoTextTheme(ThemeData.dark().textTheme),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD4AF37), // Metallic Egyptian Gold
          secondary: Color(0xFF8B6F3E),
          surface: Color(0xFF2C1E14),
        ),
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox(),
        );
      },
      home: const GameScreen(targetScore: 31),
    );
  }
}
