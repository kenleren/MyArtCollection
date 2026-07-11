import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_dependencies.dart';
import '../app_routes.dart';
import '../billing/entitlement_plan.dart';
import '../import/csv_artwork_import_service.dart';
import '../import/csv_import_file_picker.dart';
import '../storage/artwork_record.dart';
import 'prototype_flow.dart';

class CsvImportScreen extends StatefulWidget {
  const CsvImportScreen({super.key});

  @override
  State<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends State<CsvImportScreen> {
  final TextEditingController _testHarnessPathController =
      TextEditingController();

  CsvImportFileSelection? _selectedFile;
  List<CsvArtworkColumnMapping>? _headerMappings;
  CsvArtworkImportPreview? _preview;
  _CsvImportWriteSummary? _summary;
  Map<int, _DuplicateImportChoice> _duplicateChoices = {};
  String? _errorMessage;
  bool _isSelectingFile = false;
  bool _isPreviewing = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _testHarnessPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = context
        .dependOnInheritedWidgetOfExactType<AppDependencyScope>()
        ?.dependencies;
    if (dependencies == null) {
      return PrototypeScreenFrame(
        title: 'Bring in your spreadsheet',
        subtitle: 'Private records stay on this device',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            _CsvPanel(
              child: _CsvPanelBody(
                icon: Icons.table_view_outlined,
                title: 'Open this in the app',
                body:
                    'Use the app build to choose a spreadsheet, review each record, and add it to your collection.',
              ),
            ),
          ],
        ),
      );
    }

    final preview = _preview;
    final summary = _summary;

    return PrototypeScreenFrame(
      title: 'Bring in your spreadsheet',
      subtitle: 'Private records stay on this device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CsvPanel(
            child: _CsvPanelBody(
              icon: Icons.privacy_tip_outlined,
              title: 'Review everything before it is added',
              body:
                  'Your spreadsheet stays on this device while you review titles, notes, possible duplicates, and anything that needs a closer look.',
            ),
          ),
          const SizedBox(height: 12),
          _CsvPanel(child: _buildFileSelectionPanel(dependencies)),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            _CsvPanel(
              child: _CsvPanelBody(
                icon: Icons.error_outline,
                title: 'This spreadsheet needs attention',
                body: _errorMessage!,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          if (_selectedFile != null && _headerMappings != null) ...[
            const SizedBox(height: 12),
            _CsvPanel(child: _buildMappingPanel()),
          ],
          if (_isPreviewing) ...[
            const SizedBox(height: 12),
            const _CsvPanel(
              child: _CsvPanelBody(
                icon: Icons.hourglass_top,
                title: 'Preparing your preview',
                body:
                    'Reviewing your columns, notes to check, possible duplicates, and rows that still need more information.',
              ),
            ),
          ],
          if (preview != null) ...[
            const SizedBox(height: 12),
            _CsvPanel(child: _buildPreviewSummary(preview)),
            const SizedBox(height: 12),
            for (final row in preview.rows) ...[
              _CsvPreviewRowCard(
                row: row,
                category: _rowCategory(row),
                duplicateChoice:
                    _duplicateChoices[row.rowNumber] ??
                    _DuplicateImportChoice.skip,
                onDuplicateChoiceChanged: row.duplicateCandidates.isEmpty
                    ? null
                    : (choice) => _setDuplicateChoice(row.rowNumber, choice),
              ),
              if (row != preview.rows.last) const SizedBox(height: 12),
            ],
            if (summary == null) ...[
              const SizedBox(height: 16),
              _CsvConfirmActions(
                dependencies: dependencies,
                selectedImportRowCount: _selectedImportRowCount(preview),
                isSaving: _isSaving,
                hasRowsSelected: _hasRowsSelectedForImport(preview),
                onConfirm: _confirmImport,
                onCancel: _resetFlow,
              ),
            ],
          ],
          if (summary != null) ...[
            const SizedBox(height: 12),
            _CsvPanel(child: _buildSuccessSummary(summary)),
          ],
        ],
      ),
    );
  }

  Widget _buildFileSelectionPanel(AppDependencies dependencies) {
    final selectedFile = _selectedFile;
    final isBusy = _isSelectingFile || _isPreviewing || _isSaving;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Choose a spreadsheet',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Nothing in your collection changes until you review and confirm. New records arrive as drafts so you can add photos, documents, and your own confirmation next.',
        ),
        if (selectedFile != null) ...[
          const SizedBox(height: 12),
          _CsvInlineStatus(
            icon: Icons.description_outlined,
            text:
                'Selected: ${selectedFile.displayName} (${_formatBytes(selectedFile.bytes.length)}).',
          ),
          if (selectedFile.path.isNotEmpty)
            _CsvInlineStatus(
              icon: Icons.folder_outlined,
              text: 'Path: ${selectedFile.path}',
            ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: isBusy ? null : _selectCsvFile,
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('Choose spreadsheet'),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('csv-test-harness-path-field'),
          controller: _testHarnessPathController,
          enabled: !isBusy,
          decoration: const InputDecoration(
            labelText: 'Test file path',
            hintText: '/path/to/records.csv',
            helperText: 'Optional local path to load this import quickly.',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: isBusy ? null : _loadFromHarnessPath,
            icon: const Icon(Icons.terminal_outlined),
            label: const Text('Load from path'),
          ),
        ),
      ],
    );
  }

  Widget _buildMappingPanel() {
    final headerMappings = _headerMappings!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Match each column',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Pair each column with the right collection field. Extra details can stay in notes, be held as references to review later, or be left out.',
        ),
        const SizedBox(height: 12),
        for (var index = 0; index < headerMappings.length; index += 1) ...[
          _CsvMappingRow(
            header: _preview!.headers[index],
            selectedMappingId: headerMappings[index].id,
            onChanged: _isPreviewing || _isSaving
                ? null
                : (value) {
                    if (value != null) {
                      _updateMapping(index, value);
                    }
                  },
          ),
          if (index < headerMappings.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildPreviewSummary(CsvArtworkImportPreview preview) {
    final categories = <_PreviewCategory, int>{
      _PreviewCategory.ready: 0,
      _PreviewCategory.warning: 0,
      _PreviewCategory.duplicate: 0,
      _PreviewCategory.blocked: 0,
    };
    for (final row in preview.rows) {
      categories[_rowCategory(row)] = categories[_rowCategory(row)]! + 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preview your import',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          '${preview.rows.length} row${preview.rows.length == 1 ? '' : 's'} reviewed. Columns: ${preview.headers.join(', ')}',
        ),
        const SizedBox(height: 12),
        _CsvInlineStatus(
          icon: Icons.check_circle_outline,
          text: 'Ready to add: ${categories[_PreviewCategory.ready]}',
        ),
        _CsvInlineStatus(
          icon: Icons.warning_amber_outlined,
          text: 'Needs review: ${categories[_PreviewCategory.warning]}',
        ),
        _CsvInlineStatus(
          icon: Icons.copy_all_outlined,
          text: 'Possible duplicate: ${categories[_PreviewCategory.duplicate]}',
        ),
        _CsvInlineStatus(
          icon: Icons.block_outlined,
          text:
              'Needs more information: ${categories[_PreviewCategory.blocked]}',
        ),
        if (preview.skippedColumns.isNotEmpty)
          _CsvInlineStatus(
            icon: Icons.skip_next_outlined,
            text: 'Left out: ${preview.skippedColumns.join(', ')}',
          ),
      ],
    );
  }

  Widget _buildSuccessSummary(_CsvImportWriteSummary summary) {
    final firstImportedId = summary.importedRecordIds.isEmpty
        ? null
        : summary.importedRecordIds.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CsvPanelBody(
          icon: summary.importedRecordIds.isEmpty
              ? Icons.info_outline
              : Icons.check_circle_outline,
          title: summary.importedRecordIds.isEmpty
              ? 'Nothing was added'
              : 'Import ready for review',
          body: summary.message,
        ),
        const SizedBox(height: 12),
        _CsvInlineStatus(
          icon: Icons.save_outlined,
          text: 'Records added: ${summary.importedRecordIds.length}',
        ),
        _CsvInlineStatus(
          icon: Icons.copy_all_outlined,
          text: 'Possible duplicates left out: ${summary.skippedDuplicates}',
        ),
        _CsvInlineStatus(
          icon: Icons.warning_amber_outlined,
          text: 'Added with details to review: ${summary.importedWarnings}',
        ),
        _CsvInlineStatus(
          icon: Icons.block_outlined,
          text: 'Rows not added yet: ${summary.blockedRows}',
        ),
        const SizedBox(height: 16),
        if (firstImportedId != null) ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.pushNamed(
                context,
                AppRoutes.artworkDraft(firstImportedId),
              ),
              icon: const Icon(Icons.open_in_new_outlined),
              label: Text(
                summary.importedRecordIds.length == 1
                    ? 'Open record'
                    : 'Open first record',
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () =>
                Navigator.pushReplacementNamed(context, AppRoutes.collection),
            icon: const Icon(Icons.collections_bookmark_outlined),
            label: const Text('Return to collection'),
          ),
        ),
      ],
    );
  }

  Future<void> _selectCsvFile() async {
    setState(() {
      _isSelectingFile = true;
      _errorMessage = null;
      _summary = null;
    });

    try {
      final selection = await AppDependencyScope.of(
        context,
      ).csvImportFilePicker.pickCsvFile();
      if (!mounted || selection == null) {
        return;
      }
      await _loadSelection(selection);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Could not open that spreadsheet. $error';
      });
    } finally {
      if (mounted) {
        setState(() => _isSelectingFile = false);
      }
    }
  }

  Future<void> _loadFromHarnessPath() async {
    final rawPath = _testHarnessPathController.text.trim();
    if (rawPath.isEmpty) {
      setState(() {
        _errorMessage = 'Add a file path before loading it.';
      });
      return;
    }

    setState(() {
      _isSelectingFile = true;
      _errorMessage = null;
      _summary = null;
    });

    try {
      final file = File(rawPath);
      final bytes = await file.readAsBytes();
      if (!mounted) {
        return;
      }
      await _loadSelection(
        CsvImportFileSelection(
          displayName: p.basename(rawPath),
          path: rawPath,
          bytes: bytes,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Could not read that file path. $error';
      });
    } finally {
      if (mounted) {
        setState(() => _isSelectingFile = false);
      }
    }
  }

  Future<void> _loadSelection(CsvImportFileSelection selection) async {
    setState(() {
      _selectedFile = selection;
      _preview = null;
      _headerMappings = null;
      _summary = null;
      _duplicateChoices = {};
      _errorMessage = null;
    });

    await _generatePreview();
  }

  Future<void> _updateMapping(int index, String mappingId) async {
    final currentMappings = _headerMappings;
    if (currentMappings == null) {
      return;
    }

    final nextMappings = List<CsvArtworkColumnMapping>.from(currentMappings);
    nextMappings[index] = _mappingForId(mappingId);
    setState(() {
      _headerMappings = nextMappings;
      _summary = null;
    });
    await _generatePreview(headerMappings: nextMappings);
  }

  Future<void> _generatePreview({
    List<CsvArtworkColumnMapping>? headerMappings,
  }) async {
    final selectedFile = _selectedFile;
    if (selectedFile == null) {
      return;
    }

    setState(() {
      _isPreviewing = true;
      _errorMessage = null;
      _summary = null;
    });

    try {
      final dependencies = AppDependencyScope.of(context);
      final preview = dependencies
          .createCsvArtworkImportService()
          .previewFromBytes(
            selectedFile.bytes,
            existingRecords: await dependencies.artworkRepository.list(),
            headerMappings: headerMappings,
          );
      if (!mounted) {
        return;
      }

      setState(() {
        _preview = preview;
        _headerMappings = List<CsvArtworkColumnMapping>.from(
          preview.headerMappings,
        );
        _duplicateChoices = _nextDuplicateChoices(
          rows: preview.rows,
          existingChoices: _duplicateChoices,
        );
      });
    } on CsvArtworkImportException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _preview = null;
        _headerMappings = null;
        _duplicateChoices = {};
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _preview = null;
        _headerMappings = null;
        _duplicateChoices = {};
        _errorMessage = 'Could not preview that spreadsheet. $error';
      });
    } finally {
      if (mounted) {
        setState(() => _isPreviewing = false);
      }
    }
  }

  void _setDuplicateChoice(int rowNumber, _DuplicateImportChoice choice) {
    setState(() {
      _duplicateChoices = <int, _DuplicateImportChoice>{
        ..._duplicateChoices,
        rowNumber: choice,
      };
      _summary = null;
    });
  }

  Future<void> _confirmImport() async {
    final preview = _preview;
    if (preview == null) {
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
      _summary = null;
    });

    try {
      final dependencies = AppDependencyScope.of(context);
      final planGate = await _loadCsvImportPlanGate(
        dependencies: dependencies,
        selectedImportRowCount: _selectedImportRowCount(preview),
      );
      if (!planGate.canImport) {
        if (!mounted) {
          return;
        }
        setState(() {
          _errorMessage = planGate.limitMessage;
        });
        return;
      }

      final repository = dependencies.artworkRepository;
      final recordsToImport = <ArtworkRecord>[];
      for (final row in preview.rows) {
        if (!_shouldImportRow(row)) {
          continue;
        }

        final record = row.record;
        if (record == null) {
          continue;
        }

        recordsToImport.add(record);
      }
      await repository.createAll(recordsToImport);
      final importedIds = recordsToImport
          .map((record) => record.id)
          .toList(growable: false);

      if (!mounted) {
        return;
      }

      setState(() {
        _summary = _CsvImportWriteSummary.fromPreview(
          preview: preview,
          importedRecordIds: importedIds,
          duplicateChoices: _duplicateChoices,
        );
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage =
            'Could not add those records to your collection. $error';
      });
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _resetFlow() {
    _testHarnessPathController.clear();
    setState(() {
      _selectedFile = null;
      _headerMappings = null;
      _preview = null;
      _summary = null;
      _duplicateChoices = {};
      _errorMessage = null;
    });
  }

  bool _hasRowsSelectedForImport(CsvArtworkImportPreview preview) {
    return preview.rows.any(_shouldImportRow);
  }

  int _selectedImportRowCount(CsvArtworkImportPreview preview) {
    return preview.rows.where(_shouldImportRow).length;
  }

  bool _shouldImportRow(CsvArtworkImportRowPreview row) {
    final category = _rowCategory(row);
    if (category == _PreviewCategory.blocked || row.record == null) {
      return false;
    }
    if (category == _PreviewCategory.duplicate) {
      return _duplicateChoices[row.rowNumber] ==
          _DuplicateImportChoice.importAsNew;
    }
    return true;
  }

  _PreviewCategory _rowCategory(CsvArtworkImportRowPreview row) {
    if (!row.isImportable) {
      return _PreviewCategory.blocked;
    }
    if (row.duplicateCandidates.isNotEmpty) {
      return _PreviewCategory.duplicate;
    }
    if (row.warnings.isNotEmpty) {
      return _PreviewCategory.warning;
    }
    return _PreviewCategory.ready;
  }
}

class _CsvMappingRow extends StatelessWidget {
  const _CsvMappingRow({
    required this.header,
    required this.selectedMappingId,
    required this.onChanged,
  });

  final String header;
  final String selectedMappingId;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(header, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey('csv-mapping-$header'),
          initialValue: selectedMappingId,
          isExpanded: true,
          onChanged: onChanged,
          items: [
            for (final option in _mappingOptions)
              DropdownMenuItem<String>(
                value: option.id,
                child: Text(option.label, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ],
    );
  }
}

class _CsvPreviewRowCard extends StatelessWidget {
  const _CsvPreviewRowCard({
    required this.row,
    required this.category,
    required this.duplicateChoice,
    this.onDuplicateChoiceChanged,
  });

  final CsvArtworkImportRowPreview row;
  final _PreviewCategory category;
  final _DuplicateImportChoice duplicateChoice;
  final ValueChanged<_DuplicateImportChoice>? onDuplicateChoiceChanged;

  @override
  Widget build(BuildContext context) {
    final record = row.record;
    final title =
        record?.field(ArtworkFieldKeys.title)?.value ??
        row.rawValues.values.firstWhere(
          (value) => value.trim().isNotEmpty,
          orElse: () => 'Row ${row.rowNumber}',
        );
    final artist = record?.field(ArtworkFieldKeys.artist)?.value;

    return _CsvPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Row ${row.rowNumber}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              _PreviewCategoryBadge(category: category),
            ],
          ),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (artist != null && artist.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Artist: $artist'),
          ],
          if (row.duplicateCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Possible duplicate',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            SegmentedButton<_DuplicateImportChoice>(
              segments: const [
                ButtonSegment<_DuplicateImportChoice>(
                  value: _DuplicateImportChoice.skip,
                  label: Text('Leave out'),
                  icon: Icon(Icons.skip_next_outlined),
                ),
                ButtonSegment<_DuplicateImportChoice>(
                  value: _DuplicateImportChoice.importAsNew,
                  label: Text('Add anyway'),
                  icon: Icon(Icons.add_box_outlined),
                ),
              ],
              selected: {_DuplicateImportChoice.skip, duplicateChoice}
                ..remove(_DuplicateImportChoice.skip)
                ..add(duplicateChoice),
              onSelectionChanged: onDuplicateChoiceChanged == null
                  ? null
                  : (selection) => onDuplicateChoiceChanged!(selection.first),
              showSelectedIcon: false,
            ),
          ],
          if (row.warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final warning in row.warnings)
              _CsvInlineStatus(
                icon: Icons.warning_amber_outlined,
                text: warning,
              ),
          ],
          if (row.duplicateCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final candidate in row.duplicateCandidates)
              _CsvInlineStatus(
                icon: Icons.copy_all_outlined,
                text: _duplicateText(candidate),
              ),
          ],
          if (row.errors.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final error in row.errors)
              _CsvInlineStatus(icon: Icons.block_outlined, text: error),
          ],
        ],
      ),
    );
  }

  String _duplicateText(CsvArtworkDuplicateCandidate candidate) {
    return switch (candidate.source) {
      CsvArtworkDuplicateSource.existingRecord =>
        'Looks close to record ${candidate.existingArtworkId}: ${candidate.reason}',
      CsvArtworkDuplicateSource.incomingRow =>
        'Looks close to row ${candidate.incomingRowNumber}: ${candidate.reason}',
    };
  }
}

class _PreviewCategoryBadge extends StatelessWidget {
  const _PreviewCategoryBadge({required this.category});

  final _PreviewCategory category;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = switch (category) {
      _PreviewCategory.ready => (
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer,
      ),
      _PreviewCategory.warning => (
        background: scheme.primaryContainer,
        foreground: scheme.onPrimaryContainer,
      ),
      _PreviewCategory.duplicate => (
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
      ),
      _PreviewCategory.blocked => (
        background: scheme.errorContainer,
        foreground: scheme.onErrorContainer,
      ),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          category.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: colors.foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CsvPanel extends StatelessWidget {
  const _CsvPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _CsvPanelBody extends StatelessWidget {
  const _CsvPanelBody({
    required this.icon,
    required this.title,
    required this.body,
    this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? Theme.of(context).colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(body),
            ],
          ),
        ),
      ],
    );
  }
}

class _CsvInlineStatus extends StatelessWidget {
  const _CsvInlineStatus({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _CsvImportWriteSummary {
  const _CsvImportWriteSummary({
    required this.importedRecordIds,
    required this.importedWarnings,
    required this.skippedDuplicates,
    required this.blockedRows,
  });

  final List<String> importedRecordIds;
  final int importedWarnings;
  final int skippedDuplicates;
  final int blockedRows;

  String get message {
    if (importedRecordIds.isEmpty) {
      return 'Everything that looked like a duplicate was left out, or the remaining rows still need more information. Your collection was left unchanged.';
    }

    final importedCount = importedRecordIds.length;
    return '$importedCount record${importedCount == 1 ? '' : 's'} ${importedCount == 1 ? 'was' : 'were'} added as draft ${importedCount == 1 ? 'record' : 'records'} for your review. Your spreadsheet stayed on this device throughout the import.';
  }

  factory _CsvImportWriteSummary.fromPreview({
    required CsvArtworkImportPreview preview,
    required List<String> importedRecordIds,
    required Map<int, _DuplicateImportChoice> duplicateChoices,
  }) {
    var importedWarnings = 0;
    var skippedDuplicates = 0;
    var blockedRows = 0;

    for (final row in preview.rows) {
      final category = _previewCategoryForSummary(row);
      switch (category) {
        case _PreviewCategory.ready:
          break;
        case _PreviewCategory.warning:
          if (importedRecordIds.contains(row.record?.id)) {
            importedWarnings += 1;
          }
        case _PreviewCategory.duplicate:
          if (duplicateChoices[row.rowNumber] == _DuplicateImportChoice.skip) {
            skippedDuplicates += 1;
          }
        case _PreviewCategory.blocked:
          blockedRows += 1;
      }
    }

    return _CsvImportWriteSummary(
      importedRecordIds: importedRecordIds,
      importedWarnings: importedWarnings,
      skippedDuplicates: skippedDuplicates,
      blockedRows: blockedRows,
    );
  }
}

enum _DuplicateImportChoice { skip, importAsNew }

enum _PreviewCategory {
  ready('Ready to add'),
  warning('Needs review'),
  duplicate('Possible duplicate'),
  blocked('Needs more information');

  const _PreviewCategory(this.label);

  final String label;
}

class _CsvConfirmActions extends StatelessWidget {
  const _CsvConfirmActions({
    required this.dependencies,
    required this.selectedImportRowCount,
    required this.isSaving,
    required this.hasRowsSelected,
    required this.onConfirm,
    required this.onCancel,
  });

  final AppDependencies dependencies;
  final int selectedImportRowCount;
  final bool isSaving;
  final bool hasRowsSelected;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_CsvImportPlanGate>(
      future: _loadCsvImportPlanGate(
        dependencies: dependencies,
        selectedImportRowCount: selectedImportRowCount,
      ),
      builder: (context, snapshot) {
        final planGate = snapshot.data;
        if (hasRowsSelected && planGate != null && !planGate.canImport) {
          return Column(
            children: [
              _CsvPanel(
                child: _CsvPanelBody(
                  icon: Icons.workspace_premium_outlined,
                  title: 'Collection capacity before import',
                  body: planGate.limitMessage,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.pushNamed(context, AppRoutes.billing),
                  icon: const Icon(Icons.workspace_premium_outlined),
                  label: const Text('Manage plan'),
                ),
              ),
              const SizedBox(height: 12),
              _CancelImportButton(isSaving: isSaving, onCancel: onCancel),
            ],
          );
        }

        final isCheckingPlan = hasRowsSelected && planGate == null;
        return Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isSaving || !hasRowsSelected || isCheckingPlan
                    ? null
                    : onConfirm,
                icon: const Icon(Icons.check_circle_outline),
                label: Text(
                  isSaving
                      ? 'Adding to collection...'
                      : isCheckingPlan
                      ? 'Checking your plan...'
                      : 'Add to collection',
                ),
              ),
            ),
            const SizedBox(height: 12),
            _CancelImportButton(isSaving: isSaving, onCancel: onCancel),
          ],
        );
      },
    );
  }
}

class _CancelImportButton extends StatelessWidget {
  const _CancelImportButton({required this.isSaving, required this.onCancel});

  final bool isSaving;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isSaving ? null : onCancel,
        icon: const Icon(Icons.close),
        label: const Text('Start over'),
      ),
    );
  }
}

class _CsvImportPlanGate {
  const _CsvImportPlanGate({
    required this.currentActiveArtworkCount,
    required this.selectedImportRowCount,
    required this.entitlementState,
  });

  final int currentActiveArtworkCount;
  final int selectedImportRowCount;
  final EntitlementState entitlementState;

  bool get canImport {
    return entitlementState.plan.canAddActiveArtworks(
      currentActiveArtworkCount: currentActiveArtworkCount,
      additionalArtworkCount: selectedImportRowCount,
    );
  }

  String get limitMessage {
    final plan = entitlementState.plan;
    var upgradePlan = EntitlementPlans.archive;
    for (final candidate in EntitlementPlans.all) {
      if (candidate.id == plan.id) {
        continue;
      }
      if (candidate.canAddActiveArtworks(
        currentActiveArtworkCount: currentActiveArtworkCount,
        additionalArtworkCount: selectedImportRowCount,
      )) {
        upgradePlan = candidate;
        break;
      }
    }

    final projectedActiveCount =
        currentActiveArtworkCount + selectedImportRowCount;
    final planLimitCopy = upgradePlan.activeArtworkLimit == null
        ? 'room for your full active collection'
        : 'room for up to ${upgradePlan.activeArtworkLimit} active records';
    final draftCopy =
        '${upgradePlan.monthlyAiCredits} Archivale AI research draft${upgradePlan.monthlyAiCredits == 1 ? '' : 's'} each month';
    final previewCopy = switch (entitlementState.billingStatus) {
      EntitlementBillingStatus.available =>
        'Choose a plan to see currently available Play options.',
      EntitlementBillingStatus.unavailable =>
        'Plan changes are unavailable on this device right now.',
      EntitlementBillingStatus.notConfigured =>
        'Plan management is not configured in this app session.',
    };
    return 'This import would bring this plan from $currentActiveArtworkCount to $projectedActiveCount active records. Existing records remain editable and exportable. ${upgradePlan.name} plan can provide $planLimitCopy and $draftCopy. $previewCopy';
  }
}

Future<_CsvImportPlanGate> _loadCsvImportPlanGate({
  required AppDependencies dependencies,
  required int selectedImportRowCount,
}) async {
  final records = await dependencies.artworkRepository.list();
  final activeArtworkCount = records
      .where(
        (record) => record.lifecycleStatus == ArtworkLifecycleStatus.active,
      )
      .length;
  final entitlementState = await dependencies.entitlementService.currentState();
  return _CsvImportPlanGate(
    currentActiveArtworkCount: activeArtworkCount,
    selectedImportRowCount: selectedImportRowCount,
    entitlementState: entitlementState,
  );
}

class _CsvMappingOption {
  const _CsvMappingOption({required this.id, required this.label});

  final String id;
  final String label;
}

const _mappingOptions = [
  _CsvMappingOption(id: 'field:title', label: 'Title'),
  _CsvMappingOption(id: 'field:artist', label: 'Artist'),
  _CsvMappingOption(id: 'field:year', label: 'Year or date'),
  _CsvMappingOption(id: 'field:medium', label: 'Medium or material'),
  _CsvMappingOption(id: 'field:dimensions', label: 'Dimensions'),
  _CsvMappingOption(id: 'field:purchase_price', label: 'Purchase price'),
  _CsvMappingOption(id: 'field:purchase_date', label: 'Purchase date'),
  _CsvMappingOption(id: 'field:seller_or_gallery', label: 'Seller or gallery'),
  _CsvMappingOption(id: 'field:current_location', label: 'Current location'),
  _CsvMappingOption(id: 'field:insurance_value', label: 'Insurance value'),
  _CsvMappingOption(id: 'field:condition_notes', label: 'Condition notes'),
  _CsvMappingOption(id: 'field:notes', label: 'Notes'),
  _CsvMappingOption(id: 'reference', label: 'Unresolved reference'),
  _CsvMappingOption(id: 'unmapped', label: 'Append to notes'),
  _CsvMappingOption(id: 'skip', label: 'Skip column'),
];

CsvArtworkColumnMapping _mappingForId(String id) {
  if (id == 'reference') {
    return const CsvArtworkColumnMapping.reference();
  }
  if (id == 'unmapped') {
    return const CsvArtworkColumnMapping.unmapped();
  }
  if (id == 'skip') {
    return const CsvArtworkColumnMapping.skip();
  }
  return CsvArtworkColumnMapping.canonical(id.replaceFirst('field:', ''));
}

Map<int, _DuplicateImportChoice> _nextDuplicateChoices({
  required List<CsvArtworkImportRowPreview> rows,
  required Map<int, _DuplicateImportChoice> existingChoices,
}) {
  final next = <int, _DuplicateImportChoice>{};
  for (final row in rows) {
    if (row.duplicateCandidates.isEmpty) {
      continue;
    }
    next[row.rowNumber] =
        existingChoices[row.rowNumber] ?? _DuplicateImportChoice.skip;
  }
  return next;
}

_PreviewCategory _previewCategoryForSummary(CsvArtworkImportRowPreview row) {
  if (!row.isImportable) {
    return _PreviewCategory.blocked;
  }
  if (row.duplicateCandidates.isNotEmpty) {
    return _PreviewCategory.duplicate;
  }
  if (row.warnings.isNotEmpty) {
    return _PreviewCategory.warning;
  }
  return _PreviewCategory.ready;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
  }
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(1)} MB';
}
