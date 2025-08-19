import 'package:flutter/material.dart';
import 'screens/bwd_ai.dart';

void main() => runApp(const BwdAiDemoApp());

class BwdAiDemoApp extends StatelessWidget {
  const BwdAiDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BWD AI Training (Demo)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2962FF),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      home: const BwdAi(),
    );
  }
}
