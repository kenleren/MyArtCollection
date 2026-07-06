import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_routes.dart';
import 'prototype_flow.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.currentRoute});

  final String currentRoute;

  List<_ShellTab> _tabs(AppLocalizations l10n) {
    return [
      _ShellTab(
        label: l10n.collectionTab,
        route: AppRoutes.collection,
        icon: Icons.collections_bookmark_outlined,
        title: l10n.collectionTab,
      ),
      _ShellTab(
        label: l10n.incompleteTab,
        route: AppRoutes.collectionIncomplete,
        icon: Icons.rule_folder_outlined,
        title: l10n.incompleteTab,
      ),
      _ShellTab(
        label: l10n.reportsTab,
        route: AppRoutes.collectionReport,
        icon: Icons.description_outlined,
        title: l10n.reportsTab,
      ),
      _ShellTab(
        label: l10n.settingsTab,
        route: AppRoutes.collectionSettings,
        icon: Icons.settings_outlined,
        title: l10n.settingsTab,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs(AppLocalizations.of(context));
    final activeTab = _activeTab(tabs);

    return Scaffold(
      appBar: AppBar(title: const Text('Archivale')),
      body: SafeArea(child: _ShellBody(currentRoute: currentRoute)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabs.indexOf(activeTab),
        onDestinationSelected: (index) {
          if (tabs[index].route != currentRoute) {
            Navigator.pushReplacementNamed(context, tabs[index].route);
          }
        },
        destinations: [
          for (final tab in tabs)
            NavigationDestination(icon: Icon(tab.icon), label: tab.label),
        ],
      ),
    );
  }

  _ShellTab _activeTab(List<_ShellTab> tabs) {
    return tabs.firstWhere(
      (tab) =>
          tab.route == currentRoute ||
          (tab.route == AppRoutes.collectionSettings &&
              currentRoute == AppRoutes.settings),
      orElse: () => tabs.first,
    );
  }
}

class _ShellTab {
  const _ShellTab({
    required this.label,
    required this.route,
    required this.icon,
    required this.title,
  });

  final String label;
  final String route;
  final IconData icon;
  final String title;
}

class _ShellBody extends StatelessWidget {
  const _ShellBody({required this.currentRoute});

  final String currentRoute;

  @override
  Widget build(BuildContext context) {
    return switch (currentRoute) {
      AppRoutes.collection => const CollectionHomeScreen(),
      AppRoutes.collectionIncomplete => const IncompleteQueueScreen(),
      AppRoutes.collectionReport => const ReportsHomeScreen(),
      AppRoutes.collectionSettings ||
      AppRoutes.settings => const SettingsHomeScreen(),
      _ => const CollectionHomeScreen(),
    };
  }
}
