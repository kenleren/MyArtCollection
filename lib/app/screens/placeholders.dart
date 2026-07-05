import 'package:flutter/material.dart';

class SimplePlaceholderScreen extends StatelessWidget {
  const SimplePlaceholderScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.message,
    this.actions = const [],
  });

  final String title;
  final String subtitle;
  final String message;
  final List<PlaceholderAction> actions;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(title, style: textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(subtitle, style: textTheme.titleMedium),
            const SizedBox(height: 20),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Color.alphaBlend(
                        Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .05),
                        Theme.of(context).colorScheme.surface,
                      )
                    : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(message),
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 20),
              ActionList(title: 'Next actions', actions: actions),
            ],
          ],
        ),
      ),
    );
  }
}

class ActionList extends StatelessWidget {
  const ActionList({super.key, required this.title, required this.actions});

  final String title;
  final List<PlaceholderAction> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        for (final action in actions) ...[
          SizedBox(
            width: double.infinity,
            child: action.isPrimary
                ? FilledButton(
                    onPressed: () =>
                        Navigator.pushNamed(context, action.routeName),
                    child: Text(action.label),
                  )
                : OutlinedButton(
                    onPressed: () =>
                        Navigator.pushNamed(context, action.routeName),
                    child: Text(action.label),
                  ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class PlaceholderAction {
  const PlaceholderAction({
    required this.label,
    required this.routeName,
    this.isPrimary = false,
  });

  final String label;
  final String routeName;
  final bool isPrimary;
}
