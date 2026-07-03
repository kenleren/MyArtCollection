import 'package:flutter/material.dart';

import '../app_routes.dart';
import 'prototype_flow.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.currentRoute});

  final String currentRoute;

  static const _tabs = <_ShellTab>[
    _ShellTab(
      label: 'Collection',
      route: AppRoutes.collection,
      icon: Icons.collections_bookmark_outlined,
      title: 'Collection',
    ),
    _ShellTab(
      label: 'Incomplete',
      route: AppRoutes.collectionIncomplete,
      icon: Icons.rule_folder_outlined,
      title: 'Incomplete',
    ),
    _ShellTab(
      label: 'Reports',
      route: AppRoutes.collectionReport,
      icon: Icons.description_outlined,
      title: 'Reports',
    ),
    _ShellTab(
      label: 'Settings',
      route: AppRoutes.collectionSettings,
      icon: Icons.settings_outlined,
      title: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final activeTab = _activeTab;

    return Scaffold(
      appBar: AppBar(title: Text(activeTab.title)),
      body: SafeArea(child: _ShellBody(currentRoute: currentRoute)),
      floatingActionButton: currentRoute == AppRoutes.settings
          ? null
          : FloatingActionButton.extended(
              onPressed: () =>
                  Navigator.pushNamed(context, AppRoutes.collectionAdd),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Add artwork'),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabs.indexOf(activeTab),
        onDestinationSelected: (index) {
          if (_tabs[index].route != currentRoute) {
            Navigator.pushReplacementNamed(context, _tabs[index].route);
          }
        },
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(icon: Icon(tab.icon), label: tab.label),
        ],
      ),
    );
  }

  _ShellTab get _activeTab {
    return _tabs.firstWhere(
      (tab) =>
          tab.route == currentRoute ||
          (tab.route == AppRoutes.collectionSettings &&
              currentRoute == AppRoutes.settings),
      orElse: () => _tabs.first,
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
