import 'package:flutter/material.dart';

import 'app_router.dart';
import 'app_routes.dart';

class MyArtCollectionApp extends StatelessWidget {
  const MyArtCollectionApp({super.key, this.initialRoute = AppRoutes.splash});

  final String initialRoute;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF355C7D),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'MyArtCollection',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF7F4EF),
        useMaterial3: true,
      ),
      initialRoute: initialRoute,
      onGenerateRoute: AppRouter.onGenerateRoute,
      onGenerateInitialRoutes: (initialRoute) {
        return [AppRouter.onGenerateRoute(RouteSettings(name: initialRoute))];
      },
    );
  }
}
