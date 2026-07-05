import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/app_localizations.dart';
import 'app_dependencies.dart';
import 'app_router.dart';
import 'app_routes.dart';

class ArchivaleApp extends StatelessWidget {
  const ArchivaleApp({
    super.key,
    this.initialRoute = AppRoutes.splash,
    this.locale,
    this.dependencies,
  });

  final String initialRoute;
  final Locale? locale;
  final AppDependencies? dependencies;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF355C7D),
      brightness: Brightness.light,
    );

    final app = MaterialApp(
      title: 'Archivale',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
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

    final dependencies = this.dependencies;
    if (dependencies == null) {
      return app;
    }

    return AppDependencyScope(dependencies: dependencies, child: app);
  }
}
