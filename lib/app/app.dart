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
    this.themeMode = ThemeMode.system,
  });

  final String initialRoute;
  final Locale? locale;
  final AppDependencies? dependencies;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
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
      theme: _archivaleTheme(Brightness.light),
      darkTheme: _archivaleTheme(Brightness.dark),
      themeMode: themeMode,
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

ThemeData _archivaleTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colorScheme = isDark
      ? const ColorScheme.dark(
          primary: Color(0xFFD9BE78),
          onPrimary: Color(0xFF182016),
          primaryContainer: Color(0xFF314435),
          onPrimaryContainer: Color(0xFFF6E6B6),
          secondary: Color(0xFF9DBBAA),
          onSecondary: Color(0xFF102019),
          secondaryContainer: Color(0xFF263C33),
          onSecondaryContainer: Color(0xFFD5E9DD),
          tertiary: Color(0xFFE2C58B),
          onTertiary: Color(0xFF271B08),
          tertiaryContainer: Color(0xFF4C3918),
          onTertiaryContainer: Color(0xFFF7E2AF),
          error: Color(0xFFFFB4AB),
          onError: Color(0xFF690005),
          errorContainer: Color(0xFF93000A),
          onErrorContainer: Color(0xFFFFDAD6),
          surface: Color(0xFF111714),
          onSurface: Color(0xFFE5ECE5),
          surfaceContainerHighest: Color(0xFF2D3731),
          onSurfaceVariant: Color(0xFFC6CEC6),
          outline: Color(0xFF8B958C),
          outlineVariant: Color(0xFF3F4A43),
          shadow: Color(0xFF000000),
          scrim: Color(0xFF000000),
          inverseSurface: Color(0xFFE5ECE5),
          onInverseSurface: Color(0xFF2E332F),
          inversePrimary: Color(0xFF6D5520),
        )
      : ColorScheme.fromSeed(
          seedColor: const Color(0xFF355C7D),
          brightness: Brightness.light,
        );

  final scaffoldBackground = isDark
      ? const Color(0xFF0B1110)
      : const Color(0xFFF7F4EF);
  final appBarBackground = isDark
      ? const Color(0xFF101714)
      : scaffoldBackground;
  final navigationBackground = isDark
      ? const Color(0xFF121A16)
      : const Color(0xFFFCF8F2);

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: scaffoldBackground,
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      backgroundColor: appBarBackground,
      foregroundColor: colorScheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 92,
      backgroundColor: navigationBackground,
      indicatorColor: colorScheme.secondaryContainer,
      labelTextStyle: WidgetStateProperty.all(
        TextStyle(color: colorScheme.onSurface, fontSize: 12),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected
              ? colorScheme.onSecondaryContainer
              : colorScheme.onSurfaceVariant,
        );
      }),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        disabledBackgroundColor: colorScheme.surfaceContainerHighest,
        disabledForegroundColor: colorScheme.onSurfaceVariant,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colorScheme.onSurface,
        side: BorderSide(color: colorScheme.outline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: isDark,
      fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: .28),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colorScheme.primary,
      linearTrackColor: colorScheme.surfaceContainerHighest,
      circularTrackColor: colorScheme.surfaceContainerHighest,
    ),
  );
}
