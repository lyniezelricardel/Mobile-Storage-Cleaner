import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_theme.dart';
import 'providers/photo_provider.dart';
import 'providers/storage_provider.dart';
import 'screens/dashboard_screen.dart';

void main() {
  runApp(const MobileStorageCleanerApp());
}

class MobileStorageCleanerApp extends StatelessWidget {
  const MobileStorageCleanerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PhotoProvider()),
        ChangeNotifierProvider(create: (_) => StorageProvider()),
      ],
      child: MaterialApp(
        title: 'Mobile Storage Cleaner',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme(),
        home: const DashboardScreen(),
      ),
    );
  }
}
