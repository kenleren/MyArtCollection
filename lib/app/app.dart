import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/app_localizations.dart';
import 'app_dependencies.dart';
import 'app_router.dart';
import 'app_routes.dart';

class ArchivaleApp extends StatefulWidget {
  const ArchivaleApp({
    super.key,
    this.initialRoute = AppRoutes.splash,
    this.locale,
    this.dependencies,
    this.themeMode = ThemeMode.system,
    this.platform,
  });

  final String initialRoute;
  final Locale? locale;
  final AppDependencies? dependencies;
  final ThemeMode themeMode;
  final TargetPlatform? platform;

  @override
  State<ArchivaleApp> createState() => _ArchivaleAppState();
}

class _ArchivaleAppState extends State<ArchivaleApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.dependencies?.billingManagementService?.refreshForForeground();
    }
  }

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
      locale: widget.locale,
      theme: _archivaleTheme(
        Brightness.light,
      ).copyWith(platform: widget.platform),
      darkTheme: _archivaleTheme(
        Brightness.dark,
      ).copyWith(platform: widget.platform),
      themeMode: widget.themeMode,
      initialRoute: widget.initialRoute,
      onGenerateRoute: AppRouter.onGenerateRoute,
      onGenerateInitialRoutes: (initialRoute) {
        return [AppRouter.onGenerateRoute(RouteSettings(name: initialRoute))];
      },
    );

    final dependencies = widget.dependencies;
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
          onPrimary: Color(0xFF121614),
          primaryContainer: Color(0xFF3B2E16),
          onPrimaryContainer: Color(0xFFF8E7B6),
          secondary: Color(0xFF9DBBAA),
          onSecondary: Color(0xFF0D1915),
          secondaryContainer: Color(0xFF203D36),
          onSecondaryContainer: Color(0xFFD4EADD),
          tertiary: Color(0xFFAFC8E8),
          onTertiary: Color(0xFF0B1C2E),
          tertiaryContainer: Color(0xFF213A59),
          onTertiaryContainer: Color(0xFFD9E7F7),
          error: Color(0xFFFFB4AB),
          onError: Color(0xFF690005),
          errorContainer: Color(0xFF93000A),
          onErrorContainer: Color(0xFFFFDAD6),
          surface: Color(0xFF101514),
          onSurface: Color(0xFFF1EADF),
          surfaceContainerHighest: Color(0xFF29322F),
          onSurfaceVariant: Color(0xFFCFC5B7),
          outline: Color(0xFF8E8271),
          outlineVariant: Color(0xFF403A31),
          shadow: Color(0xFF000000),
          scrim: Color(0xFF000000),
          inverseSurface: Color(0xFFF1EADF),
          onInverseSurface: Color(0xFF2D2A25),
          inversePrimary: Color(0xFF745720),
        )
      : const ColorScheme.light(
          primary: Color(0xFF87652A),
          onPrimary: Color(0xFFFFF8EC),
          primaryContainer: Color(0xFFF4E2B7),
          onPrimaryContainer: Color(0xFF2C210E),
          secondary: Color(0xFF1D6A5E),
          onSecondary: Color(0xFFFFFFFF),
          secondaryContainer: Color(0xFFDDECE7),
          onSecondaryContainer: Color(0xFF0D2C27),
          tertiary: Color(0xFF24466F),
          onTertiary: Color(0xFFFFFFFF),
          tertiaryContainer: Color(0xFFDDE8F5),
          onTertiaryContainer: Color(0xFF10233A),
          error: Color(0xFFBA1A1A),
          onError: Color(0xFFFFFFFF),
          errorContainer: Color(0xFFFFDAD6),
          onErrorContainer: Color(0xFF410002),
          surface: Color(0xFFFFF8EC),
          onSurface: Color(0xFF211C15),
          surfaceContainerHighest: Color(0xFFECE1D0),
          onSurfaceVariant: Color(0xFF5E5346),
          outline: Color(0xFF817564),
          outlineVariant: Color(0xFFD4C6B2),
          shadow: Color(0xFF000000),
          scrim: Color(0xFF000000),
          inverseSurface: Color(0xFF362F26),
          onInverseSurface: Color(0xFFF8EFE2),
          inversePrimary: Color(0xFFD9BE78),
        );

  final scaffoldBackground = isDark
      ? const Color(0xFF090B0B)
      : const Color(0xFFFFF8EC);
  final appBarBackground = isDark
      ? const Color(0xFF0F1413)
      : scaffoldBackground;
  final navigationBackground = isDark
      ? const Color(0xFF111716)
      : const Color(0xFFFFFBF4);

  final textTheme = Typography.material2021().black.apply(
    displayColor: colorScheme.onSurface,
    bodyColor: colorScheme.onSurface,
  );

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: scaffoldBackground,
    useMaterial3: true,
    textTheme: textTheme.copyWith(
      headlineMedium: textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      headlineSmall: textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleLarge: textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleMedium: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleSmall: textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      labelLarge: textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      labelMedium: textTheme.labelMedium?.copyWith(letterSpacing: 0),
      labelSmall: textTheme.labelSmall?.copyWith(letterSpacing: 0),
      bodyMedium: textTheme.bodyMedium?.copyWith(height: 1.34),
      bodySmall: textTheme.bodySmall?.copyWith(height: 1.34),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: appBarBackground,
      foregroundColor: colorScheme.onSurface,
      elevation: 0,
      centerTitle: false,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleMedium?.copyWith(
        color: colorScheme.onSurface,
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 82,
      backgroundColor: navigationBackground,
      indicatorColor: colorScheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.all(
        textTheme.labelSmall?.copyWith(
          color: colorScheme.onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
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
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colorScheme.onSurface,
        side: BorderSide(color: colorScheme.outline),
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark
          ? colorScheme.surfaceContainerHighest.withValues(alpha: .28)
          : Colors.white.withValues(alpha: .72),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colorScheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colorScheme.primary,
      linearTrackColor: colorScheme.surfaceContainerHighest,
      circularTrackColor: colorScheme.surfaceContainerHighest,
    ),
  );
}
