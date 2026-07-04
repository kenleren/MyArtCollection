import 'dart:io';

import 'package:flutter/material.dart';

import '../app_dependencies.dart';
import '../app_routes.dart';
import '../intake/artwork_intake_service.dart';
import '../prototype/prototype_artwork.dart';
import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_attachment_store.dart';

class PrototypeIntroScreen extends StatelessWidget {
  const PrototypeIntroScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PrototypeScreenFrame(
      appBarTitle: 'MyArtCollection',
      title: 'Private artwork records',
      subtitle: 'AI drafts. You confirm.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ArtworkHero(),
          const SizedBox(height: 16),
          const _Notice(
            icon: Icons.auto_awesome,
            text: 'Take a photo. AI drafts the record. You confirm the facts.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Keep your collection privately organized in your own Google account when backup is enabled.',
          ),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.arrow_forward,
            label: 'Continue',
            routeName: AppRoutes.onboarding,
          ),
        ],
      ),
    );
  }
}

class PrototypeOnboardingScreen extends StatelessWidget {
  const PrototypeOnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PrototypeScreenFrame(
      title: 'Start your first private record',
      subtitle: 'AI suggests. You confirm.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Notice(
            icon: Icons.privacy_tip_outlined,
            text: 'This app does not determine authenticity or appraise value.',
          ),
          const SizedBox(height: 16),
          const _ProgressStrip(activeIndex: 0),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.add_a_photo_outlined,
            label: 'Add artwork',
            routeName: AppRoutes.collectionAdd,
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.lock_outline,
            label: 'Privacy and storage',
            routeName: AppRoutes.onboardingPrivacy,
          ),
        ],
      ),
    );
  }
}

class PrototypePrivacyScreen extends StatelessWidget {
  const PrototypePrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PrototypeScreenFrame(
      title: 'Privacy and storage',
      subtitle: 'Private record',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Notice(
            icon: Icons.cloud_done_outlined,
            text: 'Backup stays in your Google account when you enable it.',
          ),
          SizedBox(height: 12),
          Text(
            'The prototype keeps the first record local and labels every AI or document-derived value for review.',
          ),
        ],
      ),
    );
  }
}

class CollectionHomeScreen extends StatefulWidget {
  const CollectionHomeScreen({super.key});

  @override
  State<CollectionHomeScreen> createState() => _CollectionHomeScreenState();
}

class _CollectionHomeScreenState extends State<CollectionHomeScreen> {
  Future<List<_LocalArtworkSummary>>? _records;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = _maybeDependencies(context);
    _records ??= dependencies == null ? null : _loadLocalArtwork(dependencies);
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = _maybeDependencies(context);
    if (dependencies != null) {
      return FutureBuilder<List<_LocalArtworkSummary>>(
        future: _records,
        builder: (context, snapshot) {
          return _CollectionHomeContent(records: snapshot.data ?? const []);
        },
      );
    }

    return const _CollectionHomeContent(records: []);
  }
}

class _CollectionHomeContent extends StatelessWidget {
  const _CollectionHomeContent({required this.records});

  final List<_LocalArtworkSummary> records;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _Heading(
          title: 'Collection',
          subtitle: 'Private record overview',
        ),
        const SizedBox(height: 16),
        const _LimitHint(),
        const SizedBox(height: 16),
        if (records.isEmpty)
          const _EmptyCollectionPanel()
        else ...[
          for (final summary in records) ...[
            _CollectionRecordPanel(summary: summary),
            const SizedBox(height: 12),
          ],
          PrimaryActionButton(
            icon: Icons.add_a_photo_outlined,
            label: 'Add artwork',
            routeName: AppRoutes.collectionAdd,
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 32),
      ],
    );
  }
}

class IncompleteQueueScreen extends StatefulWidget {
  const IncompleteQueueScreen({super.key});

  @override
  State<IncompleteQueueScreen> createState() => _IncompleteQueueScreenState();
}

class _IncompleteQueueScreenState extends State<IncompleteQueueScreen> {
  Future<List<_LocalArtworkSummary>>? _records;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = _maybeDependencies(context);
    _records ??= dependencies == null ? null : _loadLocalArtwork(dependencies);
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = _maybeDependencies(context);
    if (dependencies != null) {
      return FutureBuilder<List<_LocalArtworkSummary>>(
        future: _records,
        builder: (context, snapshot) {
          return _IncompleteQueueContent(records: snapshot.data ?? const []);
        },
      );
    }

    return const _IncompleteQueueContent(records: []);
  }
}

class _IncompleteQueueContent extends StatelessWidget {
  const _IncompleteQueueContent({required this.records});

  final List<_LocalArtworkSummary> records;

  @override
  Widget build(BuildContext context) {
    final items = records
        .expand((summary) => summary.incompleteItems)
        .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _Heading(
          title: 'Incomplete',
          subtitle: 'Records that need attention',
        ),
        const SizedBox(height: 16),
        if (items.isEmpty)
          const _StatusPanel(
            icon: Icons.check_circle_outline,
            title: 'No incomplete records',
            body:
                'Local records with confirmed fields and supporting attachments will stay out of this queue.',
          )
        else
          for (final item in items) ...[
            _AttentionRow(
              icon: item.icon,
              title: item.title,
              body: item.body,
              actionLabel: item.actionLabel,
              routeName: item.routeName,
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

class ReportsHomeScreen extends StatelessWidget {
  const ReportsHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _Heading(
          title: 'Reports',
          subtitle: 'Generate an insurance-ready PDF',
        ),
        const SizedBox(height: 16),
        _ReportSummary(artwork: prototypeArtwork),
        const SizedBox(height: 16),
        PrimaryActionButton(
          icon: Icons.picture_as_pdf_outlined,
          label: 'Artwork report',
          routeName: AppRoutes.artworkReportPreview(prototypeArtwork.id),
        ),
        const SizedBox(height: 12),
        SecondaryActionButton(
          icon: Icons.archive_outlined,
          label: 'Export your archive',
          routeName: AppRoutes.artworkExport(prototypeArtwork.id),
        ),
      ],
    );
  }
}

class SettingsHomeScreen extends StatelessWidget {
  const SettingsHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        _Heading(title: 'Settings', subtitle: 'Privacy and storage'),
        SizedBox(height: 16),
        _StatusPanel(
          icon: Icons.lock_outline,
          title: 'Private record',
          body:
              'Back up your records in your Google account or keep local-only.',
        ),
        SizedBox(height: 12),
        _StatusPanel(
          icon: Icons.cloud_off_outlined,
          title: 'Disconnect backup',
          body: 'Disconnect Google Drive without changing local records.',
        ),
        SizedBox(height: 12),
        _StatusPanel(
          icon: Icons.ios_share_outlined,
          title: 'Export your archive',
          body:
              'Includes confirmed fields, attached documents, and report date.',
        ),
      ],
    );
  }
}

class AddArtworkScreen extends StatelessWidget {
  const AddArtworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PrototypeScreenFrame(
      title: 'Add artwork',
      subtitle: 'Start a new private record',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ProgressStrip(activeIndex: 0),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.photo_camera_outlined,
            label: 'Take photo',
            routeName: AppRoutes.capture,
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.photo_library_outlined,
            label: 'Import photo',
            routeName: AppRoutes.import,
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.attach_file,
            label: 'Attach document',
            routeName: AppRoutes.artworkDocuments(prototypeArtwork.id),
          ),
          const SizedBox(height: 20),
          const _Notice(
            icon: Icons.auto_awesome,
            text: 'AI-suggested values stay separate until you confirm them.',
          ),
        ],
      ),
    );
  }
}

class CaptureImportScreen extends StatefulWidget {
  const CaptureImportScreen({super.key, required this.mode});

  final String mode;

  @override
  State<CaptureImportScreen> createState() => _CaptureImportScreenState();
}

class _CaptureImportScreenState extends State<CaptureImportScreen> {
  ArtworkIntakeResult? _result;
  ArtworkIntakeException? _failure;
  bool _isBusy = false;

  bool get _isImport => widget.mode == 'import';

  @override
  Widget build(BuildContext context) {
    if (_maybeDependencies(context) == null) {
      return _StaticCaptureImportScreen(mode: widget.mode);
    }

    return PrototypeScreenFrame(
      title: _isImport ? 'Import photo' : 'Take photo',
      subtitle: 'Primary artwork image',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IntakeStatePanel(
            isImport: _isImport,
            isBusy: _isBusy,
            result: _result,
            failure: _failure,
            attachmentStore: AppDependencyScope.of(context).attachmentStore,
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.error_outline,
            title: 'Upload-failure state',
            body:
                'Retry is available when a document or image upload cannot finish.',
          ),
          const SizedBox(height: 20),
          if (_result == null) ...[
            _ActionButton(
              icon: _isImport
                  ? Icons.photo_library_outlined
                  : Icons.photo_camera_outlined,
              label: _isImport ? 'Choose from system picker' : 'Open camera',
              onPressed: _isBusy ? null : _runIntake,
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.restore_outlined,
              label: 'Recover interrupted import',
              onPressed: _isBusy ? null : _recoverLostImage,
              isPrimary: false,
            ),
          ] else ...[
            PrimaryActionButton(
              icon: Icons.rate_review_outlined,
              label: 'Review AI draft',
              routeName: AppRoutes.artworkDraft(_result!.record.id),
            ),
            const SizedBox(height: 12),
            SecondaryActionButton(
              icon: Icons.collections_bookmark_outlined,
              label: 'Back to collection',
              routeName: AppRoutes.collection,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _runIntake() async {
    await _withBusyState(() async {
      final service = AppDependencyScope.of(context).createIntakeService();
      return _isImport ? service.importImage() : service.captureImage();
    });
  }

  Future<void> _recoverLostImage() async {
    await _withBusyState(() async {
      final recovered = await AppDependencyScope.of(
        context,
      ).createIntakeService().recoverLostImage();
      if (recovered == null) {
        throw const ArtworkIntakeException(
          ArtworkIntakeFailure.sourceUnavailable,
          'No interrupted import was available.',
        );
      }
      return recovered;
    });
  }

  Future<void> _withBusyState(
    Future<ArtworkIntakeResult> Function() action,
  ) async {
    setState(() {
      _isBusy = true;
      _failure = null;
    });

    try {
      final result = await action();
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _failure = null;
      });
    } on ArtworkIntakeException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _failure = error);
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }
}

class _StaticCaptureImportScreen extends StatelessWidget {
  const _StaticCaptureImportScreen({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final isImport = mode == 'import';

    return PrototypeScreenFrame(
      title: isImport ? 'Import photo' : 'Take photo',
      subtitle: 'Primary artwork image',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ArtworkHero(),
          const SizedBox(height: 16),
          _StatusPanel(
            icon: isImport ? Icons.file_upload_outlined : Icons.camera_alt,
            title: isImport ? 'Photo imported' : 'Photo captured',
            body:
                'Draft created locally. If upload is interrupted, the saved draft can be reviewed later.',
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.error_outline,
            title: 'Upload-failure state',
            body:
                'Retry is available when a document or image upload cannot finish.',
          ),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.rate_review_outlined,
            label: 'Review AI draft',
            routeName: AppRoutes.artworkDraft(prototypeArtwork.id),
          ),
        ],
      ),
    );
  }
}

class DraftReviewScreen extends StatelessWidget {
  const DraftReviewScreen({super.key, required this.artwork});

  final PrototypeArtwork artwork;

  @override
  Widget build(BuildContext context) {
    final fields = [
      artwork.title,
      artwork.artist,
      artwork.year,
      artwork.medium,
      artwork.dimensions,
      artwork.location,
      artwork.condition,
    ];

    return PrototypeScreenFrame(
      title: 'AI draft review',
      subtitle: 'Possible values. Please confirm.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ProgressStrip(activeIndex: 1),
          const SizedBox(height: 16),
          _PrimaryImageForArtwork(artworkId: artwork.id),
          const SizedBox(height: 16),
          for (final field in fields) ...[
            FieldSourceTile(field: field),
            const SizedBox(height: 10),
          ],
          PrimaryActionButton(
            icon: Icons.check_circle_outline,
            label: 'Confirm suggested fields',
            routeName: AppRoutes.artworkDetails(artwork.id),
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.attach_file,
            label: 'Continue to documents',
            routeName: AppRoutes.artworkDocuments(artwork.id),
          ),
        ],
      ),
    );
  }
}

class ArtworkDetailsScreen extends StatelessWidget {
  const ArtworkDetailsScreen({super.key, required this.artwork});

  final PrototypeArtwork artwork;

  @override
  Widget build(BuildContext context) {
    final confirmedFields = [
      artwork.title,
      artwork.artist,
      artwork.medium,
      artwork.dimensions,
      artwork.location,
      artwork.insuranceValue,
      artwork.condition,
    ].map(_asConfirmed);

    return PrototypeScreenFrame(
      title: artwork.title.value,
      subtitle: 'Verified by you',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PrimaryImageForArtwork(artworkId: artwork.id),
          const SizedBox(height: 16),
          const _CompletenessPanel(),
          const SizedBox(height: 16),
          for (final field in confirmedFields) ...[
            FieldSourceTile(field: field),
            const SizedBox(height: 10),
          ],
          PrimaryActionButton(
            icon: Icons.attach_file,
            label: 'Attach receipt placeholder',
            routeName: AppRoutes.artworkDocuments(artwork.id),
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.picture_as_pdf_outlined,
            label: 'Report preview',
            routeName: AppRoutes.artworkReportPreview(artwork.id),
          ),
        ],
      ),
    );
  }

  PrototypeField _asConfirmed(PrototypeField field) {
    if (field.source != PrototypeSource.aiSuggested) {
      return field;
    }

    return PrototypeField(
      label: field.label,
      value: field.value,
      source: PrototypeSource.userConfirmed,
      note: 'User confirmed from the draft review.',
    );
  }
}

class DocumentsScreen extends StatelessWidget {
  const DocumentsScreen({super.key, required this.artwork});

  final PrototypeArtwork artwork;

  @override
  Widget build(BuildContext context) {
    return PrototypeScreenFrame(
      title: 'Documents',
      subtitle: 'Supporting records',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ProgressStrip(activeIndex: 2),
          const SizedBox(height: 16),
          const _Notice(
            icon: Icons.info_outline,
            text:
                'These documents support the record, but do not prove authenticity.',
          ),
          const SizedBox(height: 16),
          for (final document in artwork.documents) ...[
            DocumentTile(document: document),
            const SizedBox(height: 10),
          ],
          const _StatusPanel(
            icon: Icons.add_circle_outline,
            title: 'Attach document placeholder',
            body:
                'Receipt, certificate, appraisal, auction record, or provenance note can be added here later.',
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.warning_amber_outlined,
            title: 'Missing-file state',
            body:
                'If an app-private file is unavailable, the record keeps its attachment metadata and asks you to reattach it.',
          ),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.verified_user_outlined,
            label: 'View verified record',
            routeName: AppRoutes.artworkDetails(artwork.id),
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.picture_as_pdf_outlined,
            label: 'Report preview',
            routeName: AppRoutes.artworkReportPreview(artwork.id),
          ),
        ],
      ),
    );
  }
}

class ReportPreviewScreen extends StatelessWidget {
  const ReportPreviewScreen({super.key, required this.artwork});

  final PrototypeArtwork artwork;

  @override
  Widget build(BuildContext context) {
    return PrototypeScreenFrame(
      title: 'Report preview',
      subtitle: 'Generate an insurance-ready PDF',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ProgressStrip(activeIndex: 3),
          const SizedBox(height: 16),
          _ReportSummary(artwork: artwork),
          const SizedBox(height: 16),
          const _StatusPanel(
            icon: Icons.fact_check_outlined,
            title: 'Included',
            body:
                'Confirmed fields, attached document list, report date, and user-provided insurance value.',
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.block_outlined,
            title: 'Excluded',
            body:
                'No authenticity determination, appraisal certainty, or market-value claim.',
          ),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.ios_share_outlined,
            label: 'Export archive preview',
            routeName: AppRoutes.artworkExport(artwork.id),
          ),
        ],
      ),
    );
  }
}

class ExportPreviewScreen extends StatelessWidget {
  const ExportPreviewScreen({super.key, required this.artwork});

  final PrototypeArtwork artwork;

  @override
  Widget build(BuildContext context) {
    return PrototypeScreenFrame(
      title: 'Export record package',
      subtitle: 'Export your archive',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReportSummary(artwork: artwork),
          const SizedBox(height: 16),
          const _LimitHint(),
          const SizedBox(height: 16),
          const _StatusPanel(
            icon: Icons.archive_outlined,
            title: 'ZIP archive preview',
            body:
                'Includes artwork fields, source labels, document metadata, and report date.',
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.picture_as_pdf_outlined,
            title: 'PDF preview',
            body: 'User-provided insurance values only.',
          ),
        ],
      ),
    );
  }
}

class PrototypeScreenFrame extends StatelessWidget {
  const PrototypeScreenFrame({
    super.key,
    this.appBarTitle,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String? appBarTitle;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(appBarTitle ?? title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _Heading(title: title, subtitle: subtitle),
            const SizedBox(height: 20),
            child,
          ],
        ),
      ),
    );
  }
}

class FieldSourceTile extends StatelessWidget {
  const FieldSourceTile({super.key, required this.field});

  final PrototypeField field;

  @override
  Widget build(BuildContext context) {
    final colors = _sourceColors(field.source);

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  field.label,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              _SourceBadge(source: field.source, colors: colors),
            ],
          ),
          const SizedBox(height: 8),
          Text(field.value, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(field.note, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class DocumentTile extends StatelessWidget {
  const DocumentTile({super.key, required this.document});

  final PrototypeDocument document;

  @override
  Widget build(BuildContext context) {
    final colors = _sourceColors(document.source);

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.description_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.type,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(document.fileName),
                  ],
                ),
              ),
              _SourceBadge(source: document.source, colors: colors),
            ],
          ),
          const SizedBox(height: 8),
          Text(document.note, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _IntakeStatePanel extends StatelessWidget {
  const _IntakeStatePanel({
    required this.isImport,
    required this.isBusy,
    required this.result,
    required this.failure,
    required this.attachmentStore,
  });

  final bool isImport;
  final bool isBusy;
  final ArtworkIntakeResult? result;
  final ArtworkIntakeException? failure;
  final LocalAttachmentStore attachmentStore;

  @override
  Widget build(BuildContext context) {
    if (isBusy) {
      return const _StatusPanel(
        icon: Icons.hourglass_top,
        title: 'Opening private intake',
        body:
            'Use the system picker or camera. The app stores only your chosen file.',
      );
    }

    final result = this.result;
    if (result != null) {
      return Column(
        children: [
          _StatusPanel(
            icon: result.wasRecovered
                ? Icons.restore_outlined
                : isImport
                ? Icons.file_upload_outlined
                : Icons.camera_alt,
            title: result.wasRecovered
                ? 'Interrupted import recovered'
                : isImport
                ? 'Photo imported'
                : 'Photo captured',
            body:
                'Draft created locally. Return from Collection to keep reviewing this record after restart.',
          ),
          const SizedBox(height: 12),
          _PrimaryArtworkImagePreview(
            file: attachmentStore.fileFor(result.primaryImage),
          ),
        ],
      );
    }

    final failure = this.failure;
    if (failure != null) {
      return _StatusPanel(
        icon: failure.failure == ArtworkIntakeFailure.cancelled
            ? Icons.cancel_outlined
            : Icons.error_outline,
        title: failure.failure == ArtworkIntakeFailure.cancelled
            ? 'Import cancelled'
            : 'Import needs attention',
        body:
            '${failure.message} Retry when ready; no broad photo-library access is required for import.',
      );
    }

    return _StatusPanel(
      icon: isImport
          ? Icons.photo_library_outlined
          : Icons.photo_camera_outlined,
      title: isImport ? 'Use system photo picker' : 'Use camera',
      body:
          'Choose one artwork image. The app copies only that file into private storage.',
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isPrimary = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: isPrimary
          ? FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            )
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            ),
    );
  }
}

class PrimaryActionButton extends StatelessWidget {
  const PrimaryActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.routeName,
  });

  final IconData icon;
  final String label;
  final String routeName;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: () => Navigator.pushNamed(context, routeName),
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class SecondaryActionButton extends StatelessWidget {
  const SecondaryActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.routeName,
  });

  final IconData icon;
  final String label;
  final String routeName;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => Navigator.pushNamed(context, routeName),
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(subtitle, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _ArtworkHero extends StatelessWidget {
  const _ArtworkHero();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFE9E1D4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF8A6F4D)),
        ),
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _ArtworkPainter())),
            const Positioned(
              left: 14,
              bottom: 12,
              child: _MiniLabel(text: 'Example artwork image'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryImageForArtwork extends StatefulWidget {
  const _PrimaryImageForArtwork({required this.artworkId});

  final String artworkId;

  @override
  State<_PrimaryImageForArtwork> createState() =>
      _PrimaryImageForArtworkState();
}

class _PrimaryImageForArtworkState extends State<_PrimaryImageForArtwork> {
  Future<File?>? _file;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = _maybeDependencies(context);
    _file ??= dependencies == null
        ? Future<File?>.value(null)
        : _primaryImageFileForArtwork(dependencies, widget.artworkId);
  }

  @override
  void didUpdateWidget(covariant _PrimaryImageForArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkId != widget.artworkId) {
      final dependencies = _maybeDependencies(context);
      _file = dependencies == null
          ? Future<File?>.value(null)
          : _primaryImageFileForArtwork(dependencies, widget.artworkId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_maybeDependencies(context) == null) {
      return const _ArtworkHero();
    }

    return FutureBuilder<File?>(
      future: _file,
      builder: (context, snapshot) {
        return _PrimaryArtworkImagePreview(file: snapshot.data);
      },
    );
  }
}

class _PrimaryArtworkImagePreview extends StatelessWidget {
  const _PrimaryArtworkImagePreview({
    required this.file,
    this.isCompact = false,
  });

  static const imageKey = ValueKey('primary-artwork-image-preview');
  static const placeholderKey = ValueKey('primary-artwork-image-placeholder');

  final File? file;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final file = this.file;
    final canAttemptImage = file != null && file.existsSync();

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: isCompact ? 16 / 9 : 4 / 3,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFEFF3F6),
            border: Border.all(color: const Color(0xFFC6D0D8)),
          ),
          child: canAttemptImage
              ? Image.file(
                  file,
                  key: imageKey,
                  fit: BoxFit.cover,
                  semanticLabel: 'Primary artwork image',
                  errorBuilder: (context, error, stackTrace) {
                    return const _PrimaryImagePlaceholder();
                  },
                )
              : const _PrimaryImagePlaceholder(),
        ),
      ),
    );
  }
}

class _PrimaryImagePlaceholder extends StatelessWidget {
  const _PrimaryImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: _PrimaryArtworkImagePreview.placeholderKey,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 36),
            SizedBox(height: 8),
            Text(
              'Primary image preview unavailable',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtworkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFECE4D8),
    );
    final artRect = Rect.fromLTWH(
      size.width * .2,
      size.height * .14,
      size.width * .6,
      size.height * .62,
    );
    canvas.drawRect(artRect, Paint()..color = const Color(0xFF244E73));
    canvas.drawRect(
      artRect.deflate(8),
      Paint()..color = const Color(0xFFC45A46),
    );
    canvas.drawOval(
      Rect.fromCircle(
        center: Offset(size.width * .48, size.height * .42),
        radius: size.shortestSide * .13,
      ),
      Paint()..color = const Color(0xFFF2D16B),
    );
    canvas.drawRect(
      artRect,
      Paint()
        ..color = const Color(0xFF5D4631)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(14), child: child),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source, required this.colors});

  final PrototypeSource source;
  final _BadgeColors colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          source.label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: colors.foreground),
        ),
      ),
    );
  }
}

class _BadgeColors {
  const _BadgeColors(this.background, this.border, this.foreground);

  final Color background;
  final Color border;
  final Color foreground;
}

_BadgeColors _sourceColors(PrototypeSource source) {
  return switch (source) {
    PrototypeSource.userConfirmed => const _BadgeColors(
      Color(0xFFE7F3EA),
      Color(0xFF5F8F68),
      Color(0xFF24522C),
    ),
    PrototypeSource.documentExtracted => const _BadgeColors(
      Color(0xFFEAF0F6),
      Color(0xFF607D9E),
      Color(0xFF244662),
    ),
    PrototypeSource.aiSuggested => const _BadgeColors(
      Color(0xFFFFF1D6),
      Color(0xFFBC8745),
      Color(0xFF704C16),
    ),
    PrototypeSource.unknown => const _BadgeColors(
      Color(0xFFF1EDF4),
      Color(0xFF8D7D9C),
      Color(0xFF4B4056),
    ),
  };
}

class _ProgressStrip extends StatelessWidget {
  const _ProgressStrip({required this.activeIndex});

  final int activeIndex;

  static const _steps = [
    'Add photo',
    'Review draft',
    'Attach docs',
    'Preview PDF',
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var index = 0; index < _steps.length; index++)
          DecoratedBox(
            decoration: BoxDecoration(
              color: index <= activeIndex
                  ? colorScheme.primaryContainer
                  : Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                _steps[index],
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _LimitHint extends StatelessWidget {
  const _LimitHint();

  @override
  Widget build(BuildContext context) {
    return const _StatusPanel(
      icon: Icons.workspace_premium_outlined,
      title: 'Free limit preview',
      body:
          'The first records are free. Export stays clear and available for your archive.',
    );
  }
}

class _EmptyCollectionPanel extends StatelessWidget {
  const _EmptyCollectionPanel();

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No artworks yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text('Add artwork to start your first record.'),
          const SizedBox(height: 12),
          PrimaryActionButton(
            icon: Icons.add_a_photo_outlined,
            label: 'Add artwork',
            routeName: AppRoutes.collectionAdd,
          ),
        ],
      ),
    );
  }
}

class _CollectionRecordPanel extends StatelessWidget {
  const _CollectionRecordPanel({required this.summary});

  final _LocalArtworkSummary summary;

  @override
  Widget build(BuildContext context) {
    final record = summary.record;
    final title =
        record.field(ArtworkFieldKeys.title)?.value ?? 'Untitled artwork';
    final routeName = _reviewSafeRoute(record);
    final supportingCount = summary.supportingAttachmentCount;
    final incompleteCount = summary.incompleteItems.length;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(record.recordState.label),
          const SizedBox(height: 8),
          _PrimaryArtworkImagePreview(
            file: summary.primaryImageFile,
            isCompact: true,
          ),
          const SizedBox(height: 10),
          _StatusLine(
            icon: Icons.photo_library_outlined,
            text: record.primaryImageAttachmentId == null
                ? 'Primary image is not attached yet.'
                : 'Primary image saved in app-private storage.',
          ),
          _StatusLine(
            icon: Icons.attach_file,
            text: supportingCount == 0
                ? 'No supporting documents attached yet.'
                : '$supportingCount supporting document${supportingCount == 1 ? '' : 's'} attached.',
          ),
          _StatusLine(
            icon: incompleteCount == 0
                ? Icons.check_circle_outline
                : Icons.rule_folder_outlined,
            text: incompleteCount == 0
                ? 'No incomplete queue items for this record.'
                : '$incompleteCount incomplete queue item${incompleteCount == 1 ? '' : 's'} need attention.',
          ),
          const SizedBox(height: 12),
          PrimaryActionButton(
            icon: Icons.rate_review_outlined,
            label: routeName == AppRoutes.artworkDetails(record.id)
                ? 'Open record'
                : 'Resume draft',
            routeName: routeName,
          ),
        ],
      ),
    );
  }
}

class _LocalArtworkSummary {
  const _LocalArtworkSummary({
    required this.record,
    required this.attachments,
    required this.incompleteItems,
    required this.primaryImageFile,
  });

  final ArtworkRecord record;
  final List<AttachmentRecord> attachments;
  final List<_IncompleteItem> incompleteItems;
  final File? primaryImageFile;

  int get supportingAttachmentCount {
    return attachments
        .where((attachment) => attachment.type != AttachmentType.photo)
        .length;
  }
}

class _IncompleteItem {
  const _IncompleteItem({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.routeName,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final String routeName;
}

class _CompletenessPanel extends StatelessWidget {
  const _CompletenessPanel();

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Completeness', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const LinearProgressIndicator(value: .88),
          const SizedBox(height: 8),
          const Text('7 of 8 core fields are user-confirmed or reviewed.'),
          const SizedBox(height: 8),
          const _StatusLine(
            icon: Icons.verified_user_outlined,
            text: 'Record state: Verified by you',
          ),
          const _StatusLine(
            icon: Icons.inventory_2_outlined,
            text: 'Missing documents is a completeness note, not a blocker.',
          ),
        ],
      ),
    );
  }
}

class _ReportSummary extends StatelessWidget {
  const _ReportSummary({required this.artwork});

  final PrototypeArtwork artwork;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            artwork.title.value,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text('Report date: July 3, 2026'),
          const SizedBox(height: 8),
          const _StatusLine(
            icon: Icons.check_circle_outline,
            text: 'Confirmed fields are included.',
          ),
          const _StatusLine(
            icon: Icons.attach_file,
            text: 'Attached documents are listed as supporting records.',
          ),
          const _StatusLine(
            icon: Icons.price_check_outlined,
            text: 'User-provided insurance value: USD 2,400.',
          ),
        ],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 10),
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
      ),
    );
  }
}

AppDependencies? _maybeDependencies(BuildContext context) {
  return context
      .dependOnInheritedWidgetOfExactType<AppDependencyScope>()
      ?.dependencies;
}

Future<List<_LocalArtworkSummary>> _loadLocalArtwork(
  AppDependencies dependencies,
) async {
  final records = await dependencies.artworkRepository.list();
  final summaries = <_LocalArtworkSummary>[];

  for (final record in records) {
    final attachments = await dependencies.artworkRepository
        .attachmentsForArtwork(record.id);
    summaries.add(
      _LocalArtworkSummary(
        record: record,
        attachments: attachments,
        incompleteItems: _incompleteItems(record, attachments),
        primaryImageFile: _primaryImageFileFromAttachments(
          dependencies,
          record,
          attachments,
        ),
      ),
    );
  }

  return summaries;
}

Future<File?> _primaryImageFileForArtwork(
  AppDependencies dependencies,
  String artworkId,
) async {
  final record = await dependencies.artworkRepository.get(artworkId);
  if (record == null) {
    return null;
  }

  final attachmentId = record.primaryImageAttachmentId;
  if (attachmentId == null) {
    return null;
  }

  final attachment = await dependencies.artworkRepository.getAttachment(
    attachmentId,
  );
  if (attachment == null || attachment.type != AttachmentType.photo) {
    return null;
  }

  return dependencies.attachmentStore.fileFor(attachment);
}

File? _primaryImageFileFromAttachments(
  AppDependencies dependencies,
  ArtworkRecord record,
  List<AttachmentRecord> attachments,
) {
  final attachmentId = record.primaryImageAttachmentId;
  if (attachmentId == null) {
    return null;
  }

  for (final attachment in attachments) {
    if (attachment.id == attachmentId &&
        attachment.type == AttachmentType.photo) {
      return dependencies.attachmentStore.fileFor(attachment);
    }
  }

  return null;
}

List<_IncompleteItem> _incompleteItems(
  ArtworkRecord record,
  List<AttachmentRecord> attachments,
) {
  final items = <_IncompleteItem>[];
  final title =
      record.field(ArtworkFieldKeys.title)?.value ?? 'Untitled artwork';
  final reviewCount = _fieldsNeedingReview(record).length;
  final missingCount = _missingCoreFields(record).length;
  final supportingCount = attachments
      .where((attachment) => attachment.type != AttachmentType.photo)
      .length;

  if (record.recordState != ArtworkRecordState.verifiedByYou ||
      reviewCount > 0) {
    items.add(
      _IncompleteItem(
        icon: Icons.rate_review_outlined,
        title: '$title needs review',
        body: reviewCount == 0
            ? 'Record state still needs review before export.'
            : '$reviewCount field${reviewCount == 1 ? '' : 's'} still need user confirmation before export.',
        actionLabel: 'Review draft',
        routeName: AppRoutes.artworkDraft(record.id),
      ),
    );
  }

  if (missingCount > 0) {
    items.add(
      _IncompleteItem(
        icon: Icons.edit_note_outlined,
        title: '$title has missing values',
        body:
            '$missingCount core field${missingCount == 1 ? '' : 's'} need a value before this record is complete.',
        actionLabel: 'Open record',
        routeName: _reviewSafeRoute(record),
      ),
    );
  }

  if (record.recordState == ArtworkRecordState.missingDocuments ||
      supportingCount == 0) {
    items.add(
      _IncompleteItem(
        icon: Icons.attach_file,
        title: '$title needs supporting documents',
        body: supportingCount == 0
            ? 'Add a receipt, certificate, appraisal, auction record, or provenance note when available.'
            : '$supportingCount supporting document${supportingCount == 1 ? '' : 's'} attached; review the document completeness state.',
        actionLabel: 'Attach documents',
        routeName: AppRoutes.artworkDocuments(record.id),
      ),
    );
  }

  return items;
}

List<ArtworkFieldValue> _fieldsNeedingReview(ArtworkRecord record) {
  return _coreFieldKeys
      .map(record.field)
      .whereType<ArtworkFieldValue>()
      .where((field) => field.source != ArtworkFieldSource.userConfirmed)
      .toList(growable: false);
}

String _reviewSafeRoute(ArtworkRecord record) {
  if (record.recordState == ArtworkRecordState.verifiedByYou &&
      _fieldsNeedingReview(record).isEmpty) {
    return AppRoutes.artworkDetails(record.id);
  }

  return AppRoutes.artworkDraft(record.id);
}

List<String> _missingCoreFields(ArtworkRecord record) {
  return _coreFieldKeys
      .where((key) {
        final field = record.field(key);
        final value = field?.value.trim();
        return value == null ||
            value.isEmpty ||
            field?.source == ArtworkFieldSource.unknown;
      })
      .toList(growable: false);
}

const _coreFieldKeys = [
  ArtworkFieldKeys.title,
  ArtworkFieldKeys.artist,
  ArtworkFieldKeys.year,
  ArtworkFieldKeys.medium,
  ArtworkFieldKeys.dimensions,
  ArtworkFieldKeys.currentLocation,
  ArtworkFieldKeys.insuranceValue,
  ArtworkFieldKeys.conditionNotes,
];

Future<PrototypeArtwork> artworkForRoute(
  BuildContext context,
  String artworkId,
) async {
  final dependencies = _maybeDependencies(context);
  final record = dependencies == null
      ? null
      : await dependencies.artworkRepository.get(artworkId);
  if (record == null) {
    return prototypeArtwork;
  }

  final attachments = await dependencies!.artworkRepository
      .attachmentsForArtwork(record.id);
  return prototypeArtworkFromRecord(record, attachments: attachments);
}

PrototypeArtwork prototypeArtworkFromRecord(
  ArtworkRecord record, {
  List<AttachmentRecord> attachments = const [],
}) {
  final title = _field(
    record,
    key: ArtworkFieldKeys.title,
    label: 'Title',
    fallback: 'Untitled artwork',
  );
  return PrototypeArtwork(
    id: record.id,
    title: title,
    artist: _field(
      record,
      key: ArtworkFieldKeys.artist,
      label: 'Artist',
      fallback: 'Unknown',
    ),
    year: _field(
      record,
      key: ArtworkFieldKeys.year,
      label: 'Year',
      fallback: 'Could not determine',
    ),
    medium: _field(
      record,
      key: ArtworkFieldKeys.medium,
      label: 'Medium',
      fallback: 'Needs review',
    ),
    dimensions: _field(
      record,
      key: ArtworkFieldKeys.dimensions,
      label: 'Dimensions',
      fallback: 'Needs review',
    ),
    location: _field(
      record,
      key: ArtworkFieldKeys.currentLocation,
      label: 'Current location',
      fallback: 'Needs review',
    ),
    insuranceValue: _field(
      record,
      key: ArtworkFieldKeys.insuranceValue,
      label: 'User-provided insurance value',
      fallback: 'Not set',
    ),
    condition: _field(
      record,
      key: ArtworkFieldKeys.conditionNotes,
      label: 'Condition notes',
      fallback: 'Needs review',
    ),
    documents: attachments
        .where((attachment) => attachment.type != AttachmentType.photo)
        .map(_documentFromAttachment)
        .toList(growable: false),
  );
}

PrototypeField _field(
  ArtworkRecord record, {
  required String key,
  required String label,
  required String fallback,
}) {
  final value = record.field(key);
  return PrototypeField(
    label: label,
    value: value?.value ?? fallback,
    source: _prototypeSource(value?.source ?? ArtworkFieldSource.unknown),
    note: value?.note ?? 'Confirm this field before using it in a report.',
  );
}

PrototypeSource _prototypeSource(ArtworkFieldSource source) {
  return switch (source) {
    ArtworkFieldSource.aiSuggested => PrototypeSource.aiSuggested,
    ArtworkFieldSource.userConfirmed => PrototypeSource.userConfirmed,
    ArtworkFieldSource.documentExtracted => PrototypeSource.documentExtracted,
    ArtworkFieldSource.unknown => PrototypeSource.unknown,
  };
}

PrototypeDocument _documentFromAttachment(AttachmentRecord attachment) {
  return PrototypeDocument(
    type: _attachmentTypeLabel(attachment.type),
    fileName: attachment.fileName,
    source: _prototypeSource(attachment.source),
    note: attachment.notes ?? 'Stored as app-private attachment metadata.',
  );
}

String _attachmentTypeLabel(AttachmentType type) {
  return switch (type) {
    AttachmentType.photo => 'Photo',
    AttachmentType.receipt => 'Receipt',
    AttachmentType.certificate => 'Certificate',
    AttachmentType.appraisal => 'Appraisal',
    AttachmentType.auctionRecord => 'Auction record',
    AttachmentType.provenanceNote => 'Provenance note',
    AttachmentType.otherSupportingDocument => 'Supporting document',
  };
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.routeName,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final String routeName;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusLine(icon: icon, text: title),
          const SizedBox(height: 8),
          Text(body),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.arrow_forward,
            label: actionLabel,
            routeName: routeName,
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

class _MiniLabel extends StatelessWidget {
  const _MiniLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .88),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(text, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}
