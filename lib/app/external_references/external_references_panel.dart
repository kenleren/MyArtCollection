import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app_dependencies.dart';
import '../storage/external_reference.dart';
import '../storage/local_artwork_repository.dart';
import 'external_reference_launch_gateway.dart';
import 'external_reference_launch_service.dart';
import 'external_reference_url_codec.dart';

class ExternalReferencesPanel extends StatefulWidget {
  const ExternalReferencesPanel({super.key, required this.artworkId});

  final String artworkId;

  @override
  State<ExternalReferencesPanel> createState() =>
      _ExternalReferencesPanelState();
}

class _ExternalReferencesPanelState extends State<ExternalReferencesPanel> {
  final FocusNode _addFocus = FocusNode(debugLabel: 'add-external-reference');
  final Map<String, FocusNode> _rowFocus = {};
  Future<List<ExternalReferenceRecord>>? _referencesFuture;
  String? _message;
  bool _busy = false;

  AppDependencies get _dependencies => AppDependencyScope.of(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _referencesFuture ??= _dependencies.artworkRepository
        .externalReferencesForArtwork(widget.artworkId);
  }

  @override
  void didUpdateWidget(ExternalReferencesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkId != widget.artworkId) _reload();
  }

  @override
  void dispose() {
    _addFocus.dispose();
    for (final node in _rowFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _reload({FocusNode? restoreFocus}) async {
    final future = _dependencies.artworkRepository.externalReferencesForArtwork(
      widget.artworkId,
    );
    setState(() {
      _referencesFuture = future;
    });
    await future;
    if (mounted && restoreFocus != null) {
      _restoreFocusWhenReady(restoreFocus);
    }
  }

  void _restoreFocusWhenReady(FocusNode focusNode, [int attempts = 3]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (focusNode.canRequestFocus) {
        focusNode.requestFocus();
      } else if (attempts > 0) {
        _restoreFocusWhenReady(focusNode, attempts - 1);
      }
    });
  }

  FocusNode _focusFor(String id, String action) => _rowFocus.putIfAbsent(
    '$id-$action',
    () => FocusNode(debugLabel: 'reference-$id-$action'),
  );

  Future<void> _showEditor({
    ExternalReferenceRecord? reference,
    required FocusNode invoker,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ExternalReferenceEditorDialog(
        reference: reference,
        onSave: (draft) async {
          if (reference == null) {
            await _dependencies.artworkRepository.addManualExternalReference(
              referenceId: 'reference_${DateTime.now().microsecondsSinceEpoch}',
              artworkId: widget.artworkId,
              type: draft.type,
              label: draft.label,
              url: draft.url,
              transactionTime: DateTime.now().toUtc(),
            );
          } else {
            await _dependencies.artworkRepository.editExternalReference(
              referenceId: reference.id,
              type: draft.type,
              label: draft.label,
              url: draft.url,
              expectedUpdatedAt: reference.updatedAt,
              transactionTime: DateTime.now().toUtc(),
            );
          }
        },
      ),
    );
    if (!mounted) return;
    if (saved == true) {
      setState(() => _message = null);
      await _reload(restoreFocus: invoker);
    } else {
      invoker.requestFocus();
    }
  }

  Future<void> _confirm(ExternalReferenceRecord reference) async {
    await _runMutation(() async {
      await _dependencies.artworkRepository.confirmExternalReference(
        referenceId: reference.id,
        expectedUpdatedAt: reference.updatedAt,
        transactionTime: DateTime.now().toUtc(),
      );
    });
  }

  Future<void> _open(ExternalReferenceRecord reference) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _dependencies.createExternalReferenceLaunchService().open(
        referenceId: reference.id,
        expectedUrl: reference.url,
      );
    } on ExternalReferenceLaunchException {
      if (!mounted) return;
      final target = _launchTarget;
      final message = target == ExternalReferenceLaunchTarget.web
          ? 'Your browser couldn’t open this reference in a new tab.'
          : 'Couldn’t open this reference outside Archivale.';
      setState(() => _message = message);
      await _announce(message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _move(
    List<ExternalReferenceRecord> references,
    int oldIndex,
    int newIndex,
    FocusNode invoker,
  ) async {
    final reordered = List<ExternalReferenceRecord>.of(references);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    await _runMutation(() async {
      await _dependencies.artworkRepository.reorderExternalReferences(
        artworkId: widget.artworkId,
        orderedReferenceIds: reordered.map((row) => row.id).toList(),
        expectedUpdatedAtById: {
          for (final row in references) row.id: row.updatedAt,
        },
        transactionTime: DateTime.now().toUtc(),
      );
    }, restoreFocus: invoker);
    if (mounted) _restoreFocusWhenReady(invoker, 6);
  }

  Future<void> _delete(ExternalReferenceRecord reference) async {
    final focus = _focusFor(reference.id, 'delete');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete external reference?'),
        content: const Text(
          'This removes the reference from this artwork record and future exports.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    focus.requestFocus();
    if (confirmed != true) return;
    await _runMutation(() async {
      await _dependencies.artworkRepository.deleteExternalReference(
        artworkId: widget.artworkId,
        referenceId: reference.id,
        expectedUpdatedAt: reference.updatedAt,
        transactionTime: DateTime.now().toUtc(),
      );
    });
  }

  Future<void> _runMutation(
    Future<void> Function() action, {
    FocusNode? restoreFocus,
  }) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) await _reload(restoreFocus: restoreFocus);
    } on ExternalReferenceRepositoryException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = 'Couldn’t update this external reference. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  ExternalReferenceLaunchTarget get _launchTarget =>
      (_dependencies.externalReferenceLaunchGateway ??
              createSystemExternalReferenceLaunchGateway())
          .target;

  Future<void> _announce(String message) => SemanticsService.sendAnnouncement(
    View.of(context),
    message,
    Directionality.of(context),
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ExternalReferenceRecord>>(
      future: _referencesFuture,
      builder: (context, snapshot) {
        final references = snapshot.data ?? const <ExternalReferenceRecord>[];
        return Column(
          key: const ValueKey('external-references-panel'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 32),
            Text(
              'External references',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'External references support context for this record. They do not prove authenticity, attribution, provenance, ownership, value, appraisal, or insurance approval.',
            ),
            const SizedBox(height: 8),
            Text(
              _launchTarget == ExternalReferenceLaunchTarget.web
                  ? 'Opens in a new browser tab.'
                  : 'Opens in your browser or another app.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                key: const ValueKey('external-reference-message'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            if (snapshot.connectionState != ConnectionState.done)
              const Center(child: CircularProgressIndicator())
            else if (references.isEmpty)
              const Text('No external references yet.')
            else
              for (var index = 0; index < references.length; index++) ...[
                _ExternalReferenceRow(
                  reference: references[index],
                  position: index,
                  count: references.length,
                  busy: _busy,
                  openFocusNode: _focusFor(references[index].id, 'open'),
                  editFocusNode: _focusFor(references[index].id, 'edit'),
                  moveUpFocusNode: _focusFor(references[index].id, 'move-up'),
                  moveDownFocusNode: _focusFor(
                    references[index].id,
                    'move-down',
                  ),
                  deleteFocusNode: _focusFor(references[index].id, 'delete'),
                  onOpen: () => _open(references[index]),
                  onEdit: () => _showEditor(
                    reference: references[index],
                    invoker: _focusFor(references[index].id, 'edit'),
                  ),
                  onConfirm:
                      references[index].reviewState ==
                          ExternalReferenceReviewState.suggested
                      ? () => _confirm(references[index])
                      : null,
                  onMoveUp: index == 0
                      ? null
                      : () => _move(
                          references,
                          index,
                          index - 1,
                          _focusFor(references[index].id, 'open'),
                        ),
                  onMoveDown: index == references.length - 1
                      ? null
                      : () => _move(
                          references,
                          index,
                          index + 1,
                          _focusFor(references[index].id, 'open'),
                        ),
                  onDelete: () => _delete(references[index]),
                ),
                if (index != references.length - 1) const Divider(height: 20),
              ],
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('add-external-reference'),
              focusNode: _addFocus,
              onPressed: _busy ? null : () => _showEditor(invoker: _addFocus),
              icon: const Icon(Icons.add_link),
              label: const Text('Add external reference'),
            ),
          ],
        );
      },
    );
  }
}

class _ExternalReferenceRow extends StatelessWidget {
  const _ExternalReferenceRow({
    required this.reference,
    required this.position,
    required this.count,
    required this.busy,
    required this.openFocusNode,
    required this.editFocusNode,
    required this.moveUpFocusNode,
    required this.moveDownFocusNode,
    required this.deleteFocusNode,
    required this.onOpen,
    required this.onEdit,
    required this.onConfirm,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
  });

  final ExternalReferenceRecord reference;
  final int position;
  final int count;
  final bool busy;
  final FocusNode openFocusNode;
  final FocusNode editFocusNode;
  final FocusNode moveUpFocusNode;
  final FocusNode moveDownFocusNode;
  final FocusNode deleteFocusNode;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback? onConfirm;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final host = Uri.parse(reference.url).host;
    final display = reference.label ?? host;
    final trustState = reference.origin == ExternalReferenceOrigin.aiSuggestion
        ? reference.reviewState == ExternalReferenceReviewState.suggested
              ? 'AI suggestion'
              : 'Confirmed by you'
        : 'Added by you';
    final summary =
        '${reference.type.label}, $display, '
        '${reference.origin.label}, ${reference.reviewState.label}, '
        'position ${position + 1} of $count';
    return Semantics(
      key: ValueKey('external-reference-${reference.id}'),
      container: true,
      explicitChildNodes: true,
      label: summary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Text(display, style: Theme.of(context).textTheme.titleSmall),
          ),
          const SizedBox(height: 3),
          ExcludeSemantics(child: Text(reference.type.label)),
          const SizedBox(height: 3),
          ExcludeSemantics(
            child: Text(
              reference.url,
              key: ValueKey('external-reference-url-${reference.id}'),
            ),
          ),
          const SizedBox(height: 3),
          ExcludeSemantics(
            child: Text(
              trustState,
              key: ValueKey('external-reference-trust-state-${reference.id}'),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              IconButton(
                focusNode: openFocusNode,
                tooltip: 'Open external reference',
                onPressed: busy ? null : onOpen,
                icon: const Icon(Icons.open_in_new),
              ),
              IconButton(
                focusNode: editFocusNode,
                tooltip: 'Edit external reference',
                onPressed: busy ? null : onEdit,
                icon: const Icon(Icons.edit_outlined),
              ),
              if (onConfirm != null)
                IconButton(
                  tooltip: 'Confirm external reference',
                  onPressed: busy ? null : onConfirm,
                  icon: const Icon(Icons.check_circle_outline),
                ),
              IconButton(
                focusNode: moveUpFocusNode,
                tooltip: 'Move external reference up',
                onPressed: busy ? null : onMoveUp,
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                focusNode: moveDownFocusNode,
                tooltip: 'Move external reference down',
                onPressed: busy ? null : onMoveDown,
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton(
                focusNode: deleteFocusNode,
                tooltip: 'Delete external reference',
                onPressed: busy ? null : onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReferenceDraft {
  const _ReferenceDraft({
    required this.type,
    required this.label,
    required this.url,
  });
  final ExternalReferenceType type;
  final String? label;
  final String url;
}

class _ExternalReferenceEditorDialog extends StatefulWidget {
  const _ExternalReferenceEditorDialog({
    required this.reference,
    required this.onSave,
  });

  final ExternalReferenceRecord? reference;
  final Future<void> Function(_ReferenceDraft draft) onSave;

  @override
  State<_ExternalReferenceEditorDialog> createState() =>
      _ExternalReferenceEditorDialogState();
}

class _ExternalReferenceEditorDialogState
    extends State<_ExternalReferenceEditorDialog> {
  final FocusNode _urlFocus = FocusNode(debugLabel: 'external-reference-url');
  late final TextEditingController _labelController;
  late final TextEditingController _urlController;
  late ExternalReferenceType _type;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final reference = widget.reference;
    _type = reference?.type ?? ExternalReferenceType.galleryOrArtist;
    _labelController = TextEditingController(text: reference?.label);
    _urlController = TextEditingController(text: reference?.url);
  }

  @override
  void dispose() {
    _urlFocus.dispose();
    _labelController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final labelText = _labelController.text;
      final label = labelText.isEmpty
          ? null
          : normalizeExternalReferenceLabel(labelText);
      final url = const ExternalReferenceUrlCodec().canonicalize(
        _urlController.text,
      );
      await widget.onSave(_ReferenceDraft(type: _type, label: label, url: url));
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      final message = switch (error) {
        ExternalReferenceUrlException(:final message) => message,
        ExternalReferenceValidationException(:final message) => message,
        ExternalReferenceRepositoryException(:final message) => message,
        _ => 'Couldn’t save this external reference. Try again.',
      };
      setState(() => _error = message);
      await SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (_error != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _error != null) _urlFocus.requestFocus();
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.reference == null
            ? 'Add external reference'
            : 'Edit external reference',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<ExternalReferenceType>(
              isExpanded: true,
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Reference type'),
              items: [
                for (final type in ExternalReferenceType.values)
                  DropdownMenuItem(value: type, child: Text(type.label)),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _type = value!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _labelController,
              enabled: !_saving,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Label (optional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('external-reference-url-field'),
              focusNode: _urlFocus,
              controller: _urlController,
              enabled: !_saving,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'HTTPS address',
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
