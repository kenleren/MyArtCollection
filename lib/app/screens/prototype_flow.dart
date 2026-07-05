import 'dart:io';

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../app_dependencies.dart';
import '../app_identity.dart';
import '../app_routes.dart';
import '../intake/artwork_intake_service.dart';
import '../localization/app_currency_formatter.dart';
import '../prototype/prototype_artwork.dart';
import '../research/online_research_service.dart';
import '../storage/ai_research_record.dart';
import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_attachment_store.dart';

class PrototypeIntroScreen extends StatelessWidget {
  const PrototypeIntroScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PrototypeScreenFrame(
      appBarTitle: appDisplayName,
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
    final l10n = AppLocalizations.of(context);
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
            label: l10n.addArtworkAction,
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
    final l10n = AppLocalizations.of(context);
    return PrototypeScreenFrame(
      title: l10n.addArtworkAction,
      subtitle: 'Start a new private record',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ProgressStrip(activeIndex: 0),
          const SizedBox(height: 20),
          const _EvidencePhotoGuide(),
          const SizedBox(height: 16),
          PrimaryActionButton(
            icon: Icons.photo_camera_outlined,
            label: l10n.takePhotoAction,
            routeName: AppRoutes.capture,
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.photo_library_outlined,
            label: l10n.importPhotoAction,
            routeName: AppRoutes.import,
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.attach_file,
            label: l10n.attachDocumentAction,
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
  AiDraftJob? _aiDraftJob;
  ArtworkIntakeException? _failure;
  bool _isBusy = false;
  bool _isAiDraftBusy = false;

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
            isAiDraftBusy: _isAiDraftBusy,
            result: _result,
            aiDraftJob: _aiDraftJob,
            failure: _failure,
            attachmentStore: AppDependencyScope.of(context).attachmentStore,
          ),
          const SizedBox(height: 12),
          if (_result == null) ...[
            const _EvidencePhotoGuide(),
            const SizedBox(height: 12),
          ],
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
              label: _aiDraftJob?.status == AiDraftJobStatus.completed
                  ? 'Review AI draft'
                  : 'Review draft',
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
        _aiDraftJob = null;
        _failure = null;
      });
      await _runPrivateAiDraft(result);
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

  Future<void> _runPrivateAiDraft(ArtworkIntakeResult result) async {
    setState(() => _isAiDraftBusy = true);

    final service = AppDependencyScope.of(
      context,
    ).createOnDeviceAiDraftService();
    final draftJob = await service.createDraftForPrimaryImage(
      record: result.record,
      primaryImage: result.primaryImage,
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _aiDraftJob = draftJob;
      _isAiDraftBusy = false;
    });
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
          const _EvidencePhotoGuide(),
          const SizedBox(height: 12),
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

class DraftReviewScreen extends StatefulWidget {
  const DraftReviewScreen({
    super.key,
    required this.artwork,
    required this.isAiDraftReview,
    this.aiDraftJob,
    this.initialResearchJob,
  });

  final PrototypeArtwork artwork;
  final bool isAiDraftReview;
  final AiDraftJob? aiDraftJob;
  final ResearchJob? initialResearchJob;

  @override
  State<DraftReviewScreen> createState() => _DraftReviewScreenState();
}

class _DraftReviewScreenState extends State<DraftReviewScreen> {
  ResearchJob? _researchJob;
  Object? _researchError;
  bool _showResearchConsent = false;
  bool _isResearchBusy = false;
  final Set<String> _acceptedResearchFieldKeys = {};
  final Set<String> _rejectedResearchFieldKeys = {};

  @override
  void initState() {
    super.initState();
    _researchJob = widget.initialResearchJob;
  }

  @override
  void didUpdateWidget(covariant DraftReviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialResearchJob?.id != widget.initialResearchJob?.id) {
      _researchJob = widget.initialResearchJob;
      _acceptedResearchFieldKeys.clear();
      _rejectedResearchFieldKeys.clear();
      _researchError = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = [
      widget.artwork.title,
      widget.artwork.artist,
      widget.artwork.year,
      widget.artwork.medium,
      widget.artwork.dimensions,
      widget.artwork.location,
      widget.artwork.condition,
    ];
    return PrototypeScreenFrame(
      title: widget.isAiDraftReview ? 'AI draft review' : 'Draft review',
      subtitle: widget.isAiDraftReview
          ? 'Possible values. Please confirm.'
          : 'Local draft. Please confirm.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ProgressStrip(activeIndex: 1),
          const SizedBox(height: 16),
          _PrimaryImageForArtwork(artworkId: widget.artwork.id),
          const SizedBox(height: 16),
          const _EvidencePhotoGuide(isFollowUp: true),
          const SizedBox(height: 16),
          _AiDraftStatusPanel(isBusy: false, draftJob: widget.aiDraftJob),
          const SizedBox(height: 16),
          _OnlineResearchPanel(
            artwork: widget.artwork,
            researchJob: _researchJob,
            showConsent: _showResearchConsent && _isOnlineResearchEnabled,
            isBusy: _isResearchBusy,
            error: _researchError,
            isEnabled: _isOnlineResearchEnabled,
            acceptedFieldKeys: _acceptedResearchFieldKeys,
            rejectedFieldKeys: _rejectedResearchFieldKeys,
            onStart: _isOnlineResearchEnabled
                ? () => setState(() => _showResearchConsent = true)
                : null,
            onCancelConsent: () => setState(() => _showResearchConsent = false),
            onConfirmConsent: _isOnlineResearchEnabled
                ? _runOnlineResearch
                : null,
            onAcceptField: _acceptResearchField,
            onRejectField: _rejectResearchField,
          ),
          const SizedBox(height: 16),
          for (final field in fields) ...[
            FieldSourceTile(field: field),
            const SizedBox(height: 10),
          ],
          PrimaryActionButton(
            icon: Icons.edit_note_outlined,
            label: 'Edit record fields',
            routeName: AppRoutes.artworkEdit(widget.artwork.id),
          ),
          const SizedBox(height: 12),
          PrimaryActionButton(
            icon: Icons.check_circle_outline,
            label: widget.isAiDraftReview
                ? 'Confirm suggested fields'
                : 'Continue review',
            routeName: AppRoutes.artworkDetails(widget.artwork.id),
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.attach_file,
            label: 'Continue to documents',
            routeName: AppRoutes.artworkDocuments(widget.artwork.id),
          ),
        ],
      ),
    );
  }

  bool get _isOnlineResearchEnabled {
    final dependencies = _maybeDependencies(context);
    return dependencies?.featureFlags.onlineResearchEnabled ?? false;
  }

  Future<void> _runOnlineResearch() async {
    if (!_isOnlineResearchEnabled) {
      return;
    }

    setState(() {
      _isResearchBusy = true;
      _researchError = null;
    });

    try {
      final dependencies = AppDependencyScope.of(context);
      final service = dependencies.createOnlineResearchService();
      final job = await service.runResearch(
        OnlineResearchRequest(
          artworkId: widget.artwork.id,
          consentSummary:
              'User approved selected artwork image, current draft fields, and local notes for professional-source research.',
          querySummary: _researchQuerySummary(widget.artwork),
          searchTerms: _researchSearchTerms(widget.artwork),
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _researchJob = job;
        _showResearchConsent = false;
        _isResearchBusy = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _researchError = error;
        _isResearchBusy = false;
      });
    }
  }

  void _acceptResearchField(String fieldKey) {
    setState(() {
      _acceptedResearchFieldKeys.add(fieldKey);
      _rejectedResearchFieldKeys.remove(fieldKey);
    });
  }

  void _rejectResearchField(String fieldKey) {
    setState(() {
      _rejectedResearchFieldKeys.add(fieldKey);
      _acceptedResearchFieldKeys.remove(fieldKey);
    });
  }
}

String _researchQuerySummary(PrototypeArtwork artwork) {
  return [
    artwork.title.value,
    artwork.artist.value,
    artwork.medium.value,
    artwork.condition.value,
  ].where(_usefulResearchTerm).join(' ');
}

List<String> _researchSearchTerms(PrototypeArtwork artwork) {
  return [
    artwork.title.value,
    artwork.artist.value,
    artwork.medium.value,
    artwork.year.value,
  ].where(_usefulResearchTerm).toList(growable: false);
}

bool _usefulResearchTerm(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.isNotEmpty &&
      normalized != 'unknown' &&
      normalized != 'could not determine' &&
      normalized != 'untitled artwork';
}

class ArtworkDetailsScreen extends StatefulWidget {
  const ArtworkDetailsScreen({super.key, required this.artwork});

  final PrototypeArtwork artwork;

  @override
  State<ArtworkDetailsScreen> createState() => _ArtworkDetailsScreenState();
}

class _ArtworkDetailsScreenState extends State<ArtworkDetailsScreen> {
  Future<ArtworkRecord?>? _recordFuture;
  ArtworkLifecycleStatus? _localLifecycleStatus;
  bool _isUpdatingLifecycle = false;
  String? _lifecycleError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _recordFuture ??= _loadRecord();
  }

  @override
  Widget build(BuildContext context) {
    final artwork = widget.artwork;
    final completenessFields = [
      artwork.title,
      artwork.artist,
      artwork.year,
      artwork.medium,
      artwork.dimensions,
      artwork.location,
      artwork.insuranceValue,
      artwork.condition,
    ];
    final displayedFields = [
      ...completenessFields.take(5),
      artwork.purchasePrice,
      ...completenessFields.skip(5),
    ];

    return PrototypeScreenFrame(
      title: artwork.title.value,
      subtitle: 'Verified by you',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PrimaryImageForArtwork(artworkId: artwork.id),
          const SizedBox(height: 16),
          FutureBuilder<ArtworkRecord?>(
            future: _recordFuture,
            builder: (context, snapshot) {
              final status =
                  _localLifecycleStatus ??
                  snapshot.data?.lifecycleStatus ??
                  ArtworkLifecycleStatus.active;
              return _LifecycleStatusPanel(
                status: status,
                isUpdating: _isUpdatingLifecycle,
                errorMessage: _lifecycleError,
                onSetStatus: _setLifecycleStatus,
              );
            },
          ),
          const SizedBox(height: 16),
          _CompletenessPanel(fields: completenessFields),
          const SizedBox(height: 16),
          for (final field in displayedFields) ...[
            FieldSourceTile(field: field),
            const SizedBox(height: 10),
          ],
          PrimaryActionButton(
            icon: Icons.edit_note_outlined,
            label: 'Edit record fields',
            routeName: AppRoutes.artworkEdit(artwork.id),
          ),
          const SizedBox(height: 12),
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

  Future<ArtworkRecord?> _loadRecord() async {
    final dependencies = _maybeDependencies(context);
    if (dependencies == null) {
      return null;
    }
    return dependencies.artworkRepository.get(widget.artwork.id);
  }

  Future<void> _setLifecycleStatus(ArtworkLifecycleStatus status) async {
    if (status == ArtworkLifecycleStatus.removed) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Remove from current holdings?'),
            content: const Text(
              'The local record and files stay on this device, but the artwork is marked removed and no longer treated as a current holding.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Mark removed'),
              ),
            ],
          );
        },
      );
      if (confirmed != true) {
        return;
      }
      if (!mounted) {
        return;
      }
    }

    setState(() {
      _isUpdatingLifecycle = true;
      _lifecycleError = null;
    });

    try {
      final dependencies = AppDependencyScope.of(context);
      final record = await dependencies.artworkRepository.get(
        widget.artwork.id,
      );
      if (record == null) {
        throw StateError('Record not found');
      }
      final updatedRecord = record.copyWith(
        lifecycleStatus: status,
        updatedAt: DateTime.now().toUtc(),
      );
      await dependencies.artworkRepository.upsert(updatedRecord);
      if (!mounted) {
        return;
      }
      setState(() {
        _localLifecycleStatus = status;
        _isUpdatingLifecycle = false;
        _recordFuture = Future.value(updatedRecord);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isUpdatingLifecycle = false;
        _lifecycleError = error.toString();
      });
    }
  }
}

class ArtworkEditScreen extends StatefulWidget {
  const ArtworkEditScreen({super.key, required this.artworkId});

  final String artworkId;

  @override
  State<ArtworkEditScreen> createState() => _ArtworkEditScreenState();
}

class _ArtworkEditScreenState extends State<ArtworkEditScreen> {
  final Map<String, TextEditingController> _controllers = {
    for (final field in _editableArtworkFields)
      field.key: TextEditingController(),
  };
  final Map<String, TextEditingController> _moneyAmountControllers = {
    for (final field in _editableArtworkFields)
      if (field.usesStructuredMoney) field.key: TextEditingController(),
  };
  final Map<String, TextEditingController> _moneyCurrencyControllers = {
    for (final field in _editableArtworkFields)
      if (field.usesStructuredMoney) field.key: TextEditingController(),
  };
  Future<ArtworkRecord?>? _recordFuture;
  String? _seededArtworkId;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _recordFuture ??= _loadRecord();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final controller in _moneyAmountControllers.values) {
      controller.dispose();
    }
    for (final controller in _moneyCurrencyControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ArtworkRecord?>(
      future: _recordFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const PrototypeScreenFrame(
            title: 'Edit record fields',
            subtitle: 'Loading local record',
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final record = snapshot.requireData;
        if (record == null) {
          return const PrototypeScreenFrame(
            title: 'Edit record fields',
            subtitle: 'Local record unavailable',
            child: _StatusPanel(
              icon: Icons.error_outline,
              title: 'Record not found',
              body:
                  'Return to Collection and reopen the artwork before editing.',
            ),
          );
        }

        _seedControllers(record);

        return PrototypeScreenFrame(
          title: 'Edit record fields',
          subtitle: 'Your values outrank AI suggestions',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Notice(
                icon: Icons.verified_user_outlined,
                text:
                    'Saved values are labeled User confirmed. AI and research suggestions stay as suggestions until you save your edits.',
              ),
              const SizedBox(height: 16),
              for (final field in _editableArtworkFields) ...[
                TextField(
                  key: ValueKey('artwork-edit-${field.key}'),
                  controller: _controllers[field.key],
                  textInputAction: field.maxLines > 1
                      ? TextInputAction.newline
                      : TextInputAction.next,
                  keyboardType: field.maxLines > 1
                      ? TextInputType.multiline
                      : field.keyboardType,
                  minLines: field.maxLines > 1 ? 3 : 1,
                  maxLines: field.maxLines,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: field.label,
                    helperText: field.helperText,
                  ),
                ),
                if (field.usesStructuredMoney) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          key: ValueKey('artwork-edit-${field.key}-amount'),
                          controller: _moneyAmountControllers[field.key],
                          textInputAction: TextInputAction.next,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Amount',
                            helperText: 'Numbers only, no currency symbol.',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: ValueKey('artwork-edit-${field.key}-currency'),
                          controller: _moneyCurrencyControllers[field.key],
                          textInputAction: TextInputAction.next,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Currency',
                            helperText: 'USD, EUR, NOK.',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
              ],
              if (_errorMessage != null) ...[
                _StatusPanel(
                  icon: Icons.error_outline,
                  title: 'Could not save edits',
                  body: _errorMessage!,
                ),
                const SizedBox(height: 14),
              ],
              _ActionButton(
                icon: Icons.save_outlined,
                label: _isSaving ? 'Saving...' : 'Save user-confirmed fields',
                onPressed: _isSaving ? null : () => _save(record),
              ),
              const SizedBox(height: 10),
              _ActionButton(
                icon: Icons.arrow_back,
                label: 'Back to draft review',
                onPressed: _isSaving
                    ? null
                    : () => Navigator.pushReplacementNamed(
                        context,
                        AppRoutes.artworkDraft(record.id),
                      ),
                isPrimary: false,
              ),
            ],
          ),
        );
      },
    );
  }

  Future<ArtworkRecord?> _loadRecord() async {
    final dependencies = _maybeDependencies(context);
    if (dependencies == null) {
      return null;
    }
    return dependencies.artworkRepository.get(widget.artworkId);
  }

  void _seedControllers(ArtworkRecord record) {
    if (_seededArtworkId == record.id) {
      return;
    }
    _seededArtworkId = record.id;
    for (final field in _editableArtworkFields) {
      final value = record.field(field.key);
      _controllers[field.key]!.text = value?.value ?? '';
      if (field.usesStructuredMoney) {
        _moneyAmountControllers[field.key]!.text = value?.moneyAmount ?? '';
        _moneyCurrencyControllers[field.key]!.text =
            value?.moneyCurrencyCode ?? '';
      }
    }
  }

  Future<void> _save(ArtworkRecord record) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final dependencies = AppDependencyScope.of(context);
      final now = DateTime.now().toUtc();
      final fields = Map<String, ArtworkFieldValue>.of(record.fields);
      final locale = Localizations.maybeLocaleOf(context) ?? const Locale('en');

      for (final field in _editableArtworkFields) {
        final rawValue = _controllers[field.key]!.text.trim();
        final normalizedAmount = field.usesStructuredMoney
            ? _normalizeMoneyAmount(_moneyAmountControllers[field.key]!.text)
            : null;
        final normalizedCurrency = field.usesStructuredMoney
            ? _normalizeCurrencyCode(_moneyCurrencyControllers[field.key]!.text)
            : null;

        if (field.usesStructuredMoney &&
            ((normalizedAmount == null) != (normalizedCurrency == null))) {
          throw StateError(
            '${field.label} needs both a structured amount and an ISO currency code.',
          );
        }

        final value = rawValue.isNotEmpty
            ? rawValue
            : (field.usesStructuredMoney &&
                  normalizedAmount != null &&
                  normalizedCurrency != null)
            ? AppCurrencyFormatter.displayMoneyValue(
                locale: locale,
                rawValue: '',
                amount: normalizedAmount,
                currencyCode: normalizedCurrency,
              )
            : '';

        if (value.isEmpty) {
          fields.remove(field.key);
          continue;
        }

        fields[field.key] = ArtworkFieldValue(
          value: value,
          source: ArtworkFieldSource.userConfirmed,
          note: 'Edited and confirmed by you.',
          lastConfirmedAt: now,
          moneyAmount: normalizedAmount,
          moneyCurrencyCode: normalizedCurrency,
        );
      }

      final updatedRecord = record.copyWith(
        recordState: _hasCompleteConfirmedCoreFields(fields)
            ? ArtworkRecordState.verifiedByYou
            : ArtworkRecordState.needsReview,
        updatedAt: now,
        fields: fields,
      );

      await dependencies.artworkRepository.upsert(updatedRecord);
      if (!mounted) {
        return;
      }
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.artworkDraft(record.id),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isSaving = false;
        _errorMessage = _userFacingEditError(error);
      });
    }
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
    required this.isAiDraftBusy,
    required this.result,
    required this.aiDraftJob,
    required this.failure,
    required this.attachmentStore,
  });

  final bool isImport;
  final bool isBusy;
  final bool isAiDraftBusy;
  final ArtworkIntakeResult? result;
  final AiDraftJob? aiDraftJob;
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
          const SizedBox(height: 12),
          _AiDraftStatusPanel(isBusy: isAiDraftBusy, draftJob: aiDraftJob),
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

class _AiDraftStatusPanel extends StatelessWidget {
  const _AiDraftStatusPanel({required this.isBusy, required this.draftJob});

  final bool isBusy;
  final AiDraftJob? draftJob;

  @override
  Widget build(BuildContext context) {
    if (isBusy) {
      return const _StatusPanel(
        icon: Icons.auto_awesome_outlined,
        title: 'Private AI draft',
        body: 'Checking on-device AI. No online research is running.',
      );
    }

    final draftJob = this.draftJob;
    if (draftJob == null) {
      return const _StatusPanel(
        icon: Icons.auto_awesome_outlined,
        title: 'Private AI draft',
        body:
            'On-device AI has not run for this photo. You can still review and edit manually.',
      );
    }

    return switch (draftJob.status) {
      AiDraftJobStatus.completed => _StatusPanel(
        icon: Icons.auto_awesome,
        title: 'Private AI draft saved',
        body: _completedDraftBody(draftJob),
      ),
      AiDraftJobStatus.unavailable => _StatusPanel(
        icon: Icons.offline_bolt_outlined,
        title: 'On-device AI unavailable',
        body:
            '${draftJob.errorMessage ?? 'This device or build cannot run a private AI draft yet.'} No photo was sent online.',
      ),
      AiDraftJobStatus.failed => _StatusPanel(
        icon: Icons.error_outline,
        title: 'Private AI draft failed',
        body:
            '${draftJob.errorMessage ?? 'The draft could not be created.'} You can continue manually.',
      ),
      AiDraftJobStatus.pending || AiDraftJobStatus.running => _StatusPanel(
        icon: Icons.hourglass_top,
        title: 'Private AI draft pending',
        body: 'The draft is not ready yet. No online research is running.',
      ),
    };
  }

  static String _completedDraftBody(AiDraftJob draftJob) {
    final parts = [
      if (draftJob.visualSummary != null) draftJob.visualSummary!,
      if (draftJob.signatureNotes != null)
        'Signature: ${draftJob.signatureNotes!}',
      if (draftJob.mediumHint != null) 'Medium hint: ${draftJob.mediumHint!}',
      'AI-suggested only. Confirm before using in a record.',
    ];
    return parts.join(' ');
  }
}

class _EvidencePhotoGuide extends StatelessWidget {
  const _EvidencePhotoGuide({this.isFollowUp = false});

  final bool isFollowUp;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        key: const ValueKey('evidence-photo-guide'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.fact_check_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isFollowUp
                          ? 'Add evidence photos next'
                          : 'Evidence photo checklist',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isFollowUp
                          ? 'Add close-ups and back photos when research needs better clues.'
                          : 'Photograph the clues that help document the record before research.',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _EvidenceGuideItem(
            icon: Icons.crop_free_outlined,
            text:
                'Full front image, plus close-ups of the signature or maker marks.',
          ),
          const _EvidenceGuideItem(
            icon: Icons.tag_outlined,
            text: 'Edition number for prints or lithographs, such as 70/250.',
          ),
          const _EvidenceGuideItem(
            icon: Icons.flip_to_back_outlined,
            text: 'Back, frame, label, sticker, stamp, and hanging hardware.',
          ),
          const _EvidenceGuideItem(
            icon: Icons.straighten_outlined,
            text: 'Dimensions, medium/material, condition, and frame details.',
          ),
          const _EvidenceGuideItem(
            icon: Icons.description_outlined,
            text: 'Receipts, certificates, gallery, auction, or estate papers.',
          ),
          const SizedBox(height: 8),
          const Text(
            'These details support a private record and later research; they do not confirm attribution or value.',
          ),
        ],
      ),
    );
  }
}

class _EvidenceGuideItem extends StatelessWidget {
  const _EvidenceGuideItem({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _OnlineResearchPanel extends StatelessWidget {
  const _OnlineResearchPanel({
    required this.artwork,
    required this.researchJob,
    required this.showConsent,
    required this.isBusy,
    required this.error,
    required this.isEnabled,
    required this.acceptedFieldKeys,
    required this.rejectedFieldKeys,
    required this.onStart,
    required this.onCancelConsent,
    required this.onConfirmConsent,
    required this.onAcceptField,
    required this.onRejectField,
  });

  final PrototypeArtwork artwork;
  final ResearchJob? researchJob;
  final bool showConsent;
  final bool isBusy;
  final Object? error;
  final bool isEnabled;
  final Set<String> acceptedFieldKeys;
  final Set<String> rejectedFieldKeys;
  final VoidCallback? onStart;
  final VoidCallback onCancelConsent;
  final VoidCallback? onConfirmConsent;
  final ValueChanged<String> onAcceptField;
  final ValueChanged<String> onRejectField;

  @override
  Widget build(BuildContext context) {
    final researchJob = this.researchJob;

    if (!isEnabled) {
      if (researchJob != null) {
        return _ResearchResultsPanel(
          researchJob: researchJob,
          acceptedFieldKeys: acceptedFieldKeys,
          rejectedFieldKeys: rejectedFieldKeys,
          onAcceptField: onAcceptField,
          onRejectField: onRejectField,
        );
      }

      return const _StatusPanel(
        icon: Icons.travel_explore_outlined,
        title: 'Professional-source research disabled',
        body:
            'This build hides online research. Keep the local draft and use documents or manual review.',
      );
    }

    if (showConsent) {
      return _ResearchConsentPanel(
        isBusy: isBusy,
        onCancel: onCancelConsent,
        onConfirm: onConfirmConsent,
      );
    }

    if (researchJob != null) {
      return _ResearchResultsPanel(
        researchJob: researchJob,
        acceptedFieldKeys: acceptedFieldKeys,
        rejectedFieldKeys: rejectedFieldKeys,
        onAcceptField: onAcceptField,
        onRejectField: onRejectField,
      );
    }

    if (error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusPanel(
            icon: Icons.error_outline,
            title: 'Research unavailable',
            body:
                'Professional-source research could not run. ${error.toString()}',
          ),
          const SizedBox(height: 12),
          _ActionButton(
            icon: Icons.travel_explore,
            label: 'Try research again',
            onPressed: onStart,
          ),
        ],
      );
    }

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.travel_explore,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Professional-source research'),
                    SizedBox(height: 4),
                    Text(
                      'Optional. You choose before anything leaves this device.',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ActionButton(
            icon: Icons.travel_explore,
            label: 'Research online',
            onPressed: onStart,
          ),
        ],
      ),
    );
  }
}

class _ResearchConsentPanel extends StatelessWidget {
  const _ResearchConsentPanel({
    required this.isBusy,
    required this.onCancel,
    required this.onConfirm,
  });

  final bool isBusy;
  final VoidCallback onCancel;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Research consent',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'If you continue, the research service may receive the selected artwork image or a derived thumbnail, current draft fields, user notes, and on-device summary/search terms. Your full collection is not sent.',
          ),
          const SizedBox(height: 12),
          const _Notice(
            icon: Icons.fact_check_outlined,
            text:
                'Results are source-backed candidates. They are not authentication, attribution certainty, or an appraisal.',
          ),
          const SizedBox(height: 12),
          _ActionButton(
            icon: Icons.check_circle_outline,
            label: isBusy ? 'Researching...' : 'Allow professional research',
            onPressed: isBusy ? null : onConfirm,
          ),
          const SizedBox(height: 10),
          _ActionButton(
            icon: Icons.close,
            label: 'Skip online research',
            onPressed: isBusy ? null : onCancel,
            isPrimary: false,
          ),
        ],
      ),
    );
  }
}

class _ResearchResultsPanel extends StatelessWidget {
  const _ResearchResultsPanel({
    required this.researchJob,
    required this.acceptedFieldKeys,
    required this.rejectedFieldKeys,
    required this.onAcceptField,
    required this.onRejectField,
  });

  final ResearchJob researchJob;
  final Set<String> acceptedFieldKeys;
  final Set<String> rejectedFieldKeys;
  final ValueChanged<String> onAcceptField;
  final ValueChanged<String> onRejectField;

  @override
  Widget build(BuildContext context) {
    if (researchJob.sourceHits.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _StatusPanel(
            icon: Icons.travel_explore,
            title: 'No source-backed match yet',
            body:
                'No reliable professional-source candidate was found. Keep the local record and add documents or better photos later.',
          ),
          const SizedBox(height: 12),
          _ComparableSignalsPanel(
            signals: researchJob.comparableValueSignals,
            sourceHits: researchJob.sourceHits,
          ),
        ],
      );
    }

    final citationCount = researchJob.sourceHits.length;
    final citationWord = citationCount == 1 ? 'citation' : 'citations';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusPanel(
          icon: Icons.travel_explore,
          title: 'Source-backed candidates',
          body:
              '$citationCount professional-source $citationWord found. Review before confirming any field.',
        ),
        const SizedBox(height: 12),
        for (final candidate in researchJob.candidateAttributions) ...[
          _CandidateCitationCard(
            candidate: candidate,
            sourceHit: _sourceForCandidate(candidate),
            acceptedFieldKeys: acceptedFieldKeys,
            rejectedFieldKeys: rejectedFieldKeys,
            onAcceptField: onAcceptField,
            onRejectField: onRejectField,
          ),
          const SizedBox(height: 12),
        ],
        _ComparableSignalsPanel(
          signals: researchJob.comparableValueSignals,
          sourceHits: researchJob.sourceHits,
        ),
      ],
    );
  }

  ResearchSourceHit? _sourceForCandidate(CandidateAttribution candidate) {
    for (final sourceHit in researchJob.sourceHits) {
      if (sourceHit.id == candidate.sourceHitId) {
        return sourceHit;
      }
    }
    return null;
  }
}

class _ComparableSignalsPanel extends StatelessWidget {
  const _ComparableSignalsPanel({
    required this.signals,
    required this.sourceHits,
  });

  final List<ComparableValueSignal> signals;
  final List<ResearchSourceHit> sourceHits;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (signals.isEmpty) {
      return const SizedBox.shrink();
    }

    final signalCount = signals.length;
    final signalWord = signalCount == 1 ? 'signal' : 'signals';

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.comparableSourceSignalsTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            '$signalCount source-backed comparable $signalWord. These are source context only, not an appraisal.',
          ),
          const SizedBox(height: 12),
          for (final signal in signals) ...[
            _ComparableSignalCard(signal: signal, sourceHits: sourceHits),
            if (signal != signals.last) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _ComparableSignalCard extends StatelessWidget {
  const _ComparableSignalCard({required this.signal, required this.sourceHits});

  final ComparableValueSignal signal;
  final List<ResearchSourceHit> sourceHits;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context);
    final kind = _effectiveComparableKind(signal, sourceHits);
    final sourceName = _comparableSourceName(signal, sourceHits, kind);
    final citationUrl = _comparableCitationUrl(signal, sourceHits, kind);
    final amountText = _comparableAmountText(
      signal,
      sourceHits,
      kind,
      locale,
      l10n,
    );
    final dateText = _comparableDateText(signal.signalDate, kind, l10n);
    final caveat = _comparableCaveatText(signal, kind);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAF8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              kind.displayLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            _StatusLine(
              icon: Icons.source_outlined,
              text: l10n.sourceLine(sourceName),
            ),
            if (citationUrl != null)
              _StatusLine(
                icon: Icons.link_outlined,
                text: l10n.citationLine(citationUrl),
              ),
            if (amountText != null)
              _StatusLine(icon: Icons.price_check_outlined, text: amountText),
            if (dateText != null)
              _StatusLine(icon: Icons.event_outlined, text: dateText),
            const SizedBox(height: 8),
            Text(caveat, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

ComparableValueKind _effectiveComparableKind(
  ComparableValueSignal signal,
  List<ResearchSourceHit> sourceHits,
) {
  if (signal.kind == ComparableValueKind.noReliableComparable ||
      signal.kind == ComparableValueKind.userProvidedInsuranceValue) {
    return signal.kind;
  }
  return _linkedAuctionSource(signal, sourceHits) == null
      ? ComparableValueKind.noReliableComparable
      : signal.kind;
}

String _comparableSourceName(
  ComparableValueSignal signal,
  List<ResearchSourceHit> sourceHits,
  ComparableValueKind kind,
) {
  if (kind == ComparableValueKind.noReliableComparable) {
    return 'Professional-source search';
  }
  return _linkedAuctionSource(signal, sourceHits)?.sourceName ??
      signal.sourceName;
}

String? _comparableCitationUrl(
  ComparableValueSignal signal,
  List<ResearchSourceHit> sourceHits,
  ComparableValueKind kind,
) {
  if (kind == ComparableValueKind.userProvidedInsuranceValue) {
    return null;
  }
  return _linkedAuctionSource(signal, sourceHits)?.sourceUrl;
}

String? _comparableAmountText(
  ComparableValueSignal signal,
  List<ResearchSourceHit> sourceHits,
  ComparableValueKind kind,
  Locale locale,
  AppLocalizations l10n,
) {
  if (!kind.canDisplayAmount) {
    return null;
  }
  if (kind != ComparableValueKind.userProvidedInsuranceValue &&
      _linkedAuctionSource(signal, sourceHits) == null) {
    return null;
  }

  final amount = AppCurrencyFormatter.comparableAmount(
    locale: locale,
    currencyCode: signal.currency,
    amountLow: signal.amountLow,
    amountHigh: signal.amountHigh,
  );
  if (amount.isEmpty) {
    return null;
  }
  return l10n.comparableAmountLine(amount);
}

String? _comparableDateText(
  DateTime? date,
  ComparableValueKind kind,
  AppLocalizations l10n,
) {
  if (date == null || !kind.canDisplayAmount) {
    return null;
  }
  return l10n.signalDateLine(
    '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)}',
  );
}

String _comparableCaveatText(
  ComparableValueSignal signal,
  ComparableValueKind kind,
) {
  if (kind != signal.kind) {
    return 'Comparable signal hidden because its source could not be verified.';
  }
  if (_containsProhibitedComparablePhrase(signal.caveat)) {
    return _defaultComparableCaveat(kind);
  }
  return signal.caveat;
}

String _defaultComparableCaveat(ComparableValueKind kind) {
  return switch (kind) {
    ComparableValueKind.noReliableComparable =>
      'No source-backed comparable was available for this draft.',
    ComparableValueKind.publicEstimate ||
    ComparableValueKind.comparableSaleSignal ||
    ComparableValueKind.userProvidedInsuranceValue =>
      'Comparable data may not apply to this artwork; confirm with an expert.',
  };
}

ResearchSourceHit? _linkedAuctionSource(
  ComparableValueSignal signal,
  List<ResearchSourceHit> sourceHits,
) {
  final sourceHitId = signal.sourceHitId;
  if (sourceHitId == null) {
    return null;
  }

  for (final sourceHit in sourceHits) {
    if (sourceHit.id != sourceHitId ||
        sourceHit.sourceType != ResearchSourceType.auctionHouse) {
      continue;
    }

    final sourceUrl = sourceHit.sourceUrl;
    if (!_isDisplaySafeWebUrl(sourceUrl)) {
      return null;
    }
    if (signal.sourceUrl != null && signal.sourceUrl != sourceUrl) {
      return null;
    }
    return sourceHit;
  }
  return null;
}

bool _isDisplaySafeWebUrl(String? url) {
  final uri = Uri.tryParse(url?.trim() ?? '');
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty;
}

bool _containsProhibitedComparablePhrase(String text) {
  final normalized = text.toLowerCase();
  return normalized.contains('market value') ||
      normalized.contains('appraised at') ||
      normalized.contains('worth') ||
      normalized.contains('certified value') ||
      normalized.contains('authentic value');
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

class _CandidateCitationCard extends StatelessWidget {
  const _CandidateCitationCard({
    required this.candidate,
    required this.sourceHit,
    required this.acceptedFieldKeys,
    required this.rejectedFieldKeys,
    required this.onAcceptField,
    required this.onRejectField,
  });

  final CandidateAttribution candidate;
  final ResearchSourceHit? sourceHit;
  final Set<String> acceptedFieldKeys;
  final Set<String> rejectedFieldKeys;
  final ValueChanged<String> onAcceptField;
  final ValueChanged<String> onRejectField;

  @override
  Widget build(BuildContext context) {
    final sourceHit = this.sourceHit;
    final fields = [
      if (candidate.title != null)
        _CandidateFieldSuggestion(
          key: _candidateFieldKey(candidate, 'title'),
          label: 'Title',
          value: candidate.title!,
        ),
      if (candidate.artist != null)
        _CandidateFieldSuggestion(
          key: _candidateFieldKey(candidate, 'artist'),
          label: 'Artist',
          value: candidate.artist!,
        ),
      if (candidate.year != null)
        _CandidateFieldSuggestion(
          key: _candidateFieldKey(candidate, 'year'),
          label: 'Year',
          value: candidate.year!,
        ),
      if (candidate.medium != null)
        _CandidateFieldSuggestion(
          key: _candidateFieldKey(candidate, 'medium'),
          label: 'Medium',
          value: candidate.medium!,
        ),
    ];

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            candidate.title ?? 'Candidate match',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(candidate.matchReason),
          const SizedBox(height: 10),
          _SourceBadge(
            source: PrototypeSource.aiSuggested,
            colors: _sourceColors(PrototypeSource.aiSuggested),
          ),
          const SizedBox(height: 12),
          if (sourceHit != null) ...[
            Text('Source: ${sourceHit.sourceName}'),
            Text('Source type: ${sourceHit.sourceType.storageValue}'),
            if (sourceHit.sourceUrl != null)
              Text('Citation: ${sourceHit.sourceUrl!}'),
            if (sourceHit.rawSnippet != null)
              Text('Evidence: ${sourceHit.rawSnippet!}'),
            const SizedBox(height: 12),
          ],
          for (final field in fields) ...[
            _CandidateFieldRow(
              suggestion: field,
              accepted: acceptedFieldKeys.contains(field.key),
              rejected: rejectedFieldKeys.contains(field.key),
              onAccept: () => onAcceptField(field.key),
              onReject: () => onRejectField(field.key),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

String _candidateFieldKey(CandidateAttribution candidate, String fieldKey) {
  return '${candidate.id}:$fieldKey';
}

class _CandidateFieldSuggestion {
  const _CandidateFieldSuggestion({
    required this.key,
    required this.label,
    required this.value,
  });

  final String key;
  final String label;
  final String value;
}

class _CandidateFieldRow extends StatelessWidget {
  const _CandidateFieldRow({
    required this.suggestion,
    required this.accepted,
    required this.rejected,
    required this.onAccept,
    required this.onReject,
  });

  final _CandidateFieldSuggestion suggestion;
  final bool accepted;
  final bool rejected;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final status = accepted
        ? 'Accepted for review'
        : rejected
        ? 'Rejected for this draft'
        : 'AI-suggested';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAF8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              suggestion.label,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Text(suggestion.value),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _SourceBadge(
                  source: PrototypeSource.aiSuggested,
                  colors: _sourceColors(PrototypeSource.aiSuggested),
                ),
                Text(status),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.check),
                  label: const Text('Accept suggestion'),
                ),
                OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close),
                  label: const Text('Reject'),
                ),
              ],
            ),
          ],
        ),
      ),
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
          _localizedSourceLabel(context, source),
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: colors.foreground),
        ),
      ),
    );
  }
}

String _localizedSourceLabel(BuildContext context, PrototypeSource source) {
  final l10n = AppLocalizations.of(context);
  return switch (source) {
    PrototypeSource.aiSuggested => l10n.aiSuggestedLabel,
    PrototypeSource.userConfirmed => l10n.userConfirmedLabel,
    PrototypeSource.documentExtracted => l10n.documentExtractedLabel,
    PrototypeSource.unknown => l10n.unknownLabel,
  };
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
    final lifecycleStatus = record.lifecycleStatus;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _RecordStateBadge(label: record.recordState.label),
              _LifecycleBadge(status: lifecycleStatus),
            ],
          ),
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
                : '$incompleteCount incomplete queue item${incompleteCount == 1 ? '' : 's'} ${incompleteCount == 1 ? 'needs' : 'need'} attention.',
          ),
          if (lifecycleStatus != ArtworkLifecycleStatus.active)
            _StatusLine(
              icon: Icons.inventory_2_outlined,
              text:
                  'Marked ${lifecycleStatus.label.toLowerCase()}; retained in the local record.',
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

class _RecordStateBadge extends StatelessWidget {
  const _RecordStateBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: colors.onSecondaryContainer),
        ),
      ),
    );
  }
}

class _LifecycleBadge extends StatelessWidget {
  const _LifecycleBadge({required this.status});

  final ArtworkLifecycleStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = _lifecycleColors(context, status);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          status.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: colors.foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _LifecycleStatusPanel extends StatelessWidget {
  const _LifecycleStatusPanel({
    required this.status,
    required this.isUpdating,
    required this.onSetStatus,
    this.errorMessage,
  });

  final ArtworkLifecycleStatus status;
  final bool isUpdating;
  final String? errorMessage;
  final ValueChanged<ArtworkLifecycleStatus> onSetStatus;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.inventory_2_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Lifecycle status',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              _LifecycleBadge(status: status),
            ],
          ),
          const SizedBox(height: 10),
          Text(_lifecycleDescription(status)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in ArtworkLifecycleStatus.values)
                _LifecycleActionChip(
                  status: option,
                  selected: option == status,
                  enabled: !isUpdating,
                  onSelected: () => onSetStatus(option),
                ),
            ],
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              'Could not update lifecycle status: $errorMessage',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _LifecycleActionChip extends StatelessWidget {
  const _LifecycleActionChip({
    required this.status,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final ArtworkLifecycleStatus status;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final isRemove = status == ArtworkLifecycleStatus.removed;
    return ActionChip(
      avatar: Icon(
        _lifecycleIcon(status),
        size: 18,
        color: isRemove ? Theme.of(context).colorScheme.error : null,
      ),
      label: Text(status.label),
      onPressed: !enabled || selected ? null : onSelected,
      side: selected
          ? BorderSide(color: Theme.of(context).colorScheme.primary)
          : null,
    );
  }
}

({Color background, Color foreground}) _lifecycleColors(
  BuildContext context,
  ArtworkLifecycleStatus status,
) {
  final colors = Theme.of(context).colorScheme;
  return switch (status) {
    ArtworkLifecycleStatus.active => (
      background: colors.primaryContainer,
      foreground: colors.onPrimaryContainer,
    ),
    ArtworkLifecycleStatus.sold => (
      background: colors.tertiaryContainer,
      foreground: colors.onTertiaryContainer,
    ),
    ArtworkLifecycleStatus.lost ||
    ArtworkLifecycleStatus.stolen ||
    ArtworkLifecycleStatus.removed => (
      background: colors.errorContainer,
      foreground: colors.onErrorContainer,
    ),
  };
}

IconData _lifecycleIcon(ArtworkLifecycleStatus status) {
  return switch (status) {
    ArtworkLifecycleStatus.active => Icons.check_circle_outline,
    ArtworkLifecycleStatus.sold => Icons.sell_outlined,
    ArtworkLifecycleStatus.lost => Icons.search_off_outlined,
    ArtworkLifecycleStatus.stolen => Icons.report_gmailerrorred_outlined,
    ArtworkLifecycleStatus.removed => Icons.remove_circle_outline,
  };
}

String _lifecycleDescription(ArtworkLifecycleStatus status) {
  return switch (status) {
    ArtworkLifecycleStatus.active =>
      'This artwork is treated as a current holding.',
    ArtworkLifecycleStatus.sold =>
      'This artwork is retained in your records but marked sold.',
    ArtworkLifecycleStatus.lost =>
      'This artwork is retained in your records but marked lost.',
    ArtworkLifecycleStatus.stolen =>
      'This artwork is retained in your records but marked stolen.',
    ArtworkLifecycleStatus.removed =>
      'This artwork is retained locally but removed from current holdings.',
  };
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
  const _CompletenessPanel({required this.fields});

  final List<PrototypeField> fields;

  @override
  Widget build(BuildContext context) {
    final reviewedCount = fields
        .where(
          (field) =>
              field.source == PrototypeSource.userConfirmed ||
              field.source == PrototypeSource.documentExtracted,
        )
        .length;
    final totalCount = fields.length;
    final progress = totalCount == 0 ? 0.0 : reviewedCount / totalCount;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Completeness', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Text(
            '$reviewedCount of $totalCount core fields are user-confirmed or reviewed.',
          ),
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
    final l10n = AppLocalizations.of(context);
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
          _StatusLine(
            icon: Icons.receipt_long_outlined,
            text: 'Purchase price: ${artwork.purchasePrice.value}.',
          ),
          _StatusLine(
            icon: Icons.price_check_outlined,
            text: l10n.userProvidedInsuranceValueLine(
              artwork.insuranceValue.value,
            ),
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

  if (record.lifecycleStatus != ArtworkLifecycleStatus.active) {
    if (record.lifecycleStatus != ArtworkLifecycleStatus.removed) {
      items.add(
        _IncompleteItem(
          icon: _lifecycleIcon(record.lifecycleStatus),
          title:
              '$title is marked ${record.lifecycleStatus.label.toLowerCase()}',
          body:
              'This record is retained locally but is not treated as a current incomplete holding.',
          actionLabel: 'Open record',
          routeName: AppRoutes.artworkDetails(record.id),
        ),
      );
    }
    return items;
  }

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
  if (record.lifecycleStatus != ArtworkLifecycleStatus.active) {
    return AppRoutes.artworkDetails(record.id);
  }

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

const _editableArtworkFields = [
  _EditableArtworkField(
    key: ArtworkFieldKeys.title,
    label: 'Title',
    helperText: 'Use your preferred record title.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.artist,
    label: 'Artist',
    helperText: 'Leave blank if the artist is still unknown.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.year,
    label: 'Year or date',
    helperText: 'Use a year, range, or date text you can support.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.medium,
    label: 'Medium or material',
    helperText: 'For example: oil on canvas, lithograph, bronze.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.dimensions,
    label: 'Dimensions',
    helperText: 'Include units, for example 60 x 80 cm.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.purchasePrice,
    label: 'Purchase price',
    helperText: 'Keep legacy text or add a structured amount and ISO currency.',
    usesStructuredMoney: true,
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.currentLocation,
    label: 'Current location',
    helperText: 'Private location label for your own records.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.insuranceValue,
    label: 'User-provided insurance value',
    helperText: 'Keep legacy text or add a structured amount and ISO currency.',
    keyboardType: TextInputType.text,
    usesStructuredMoney: true,
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.conditionNotes,
    label: 'Condition notes',
    helperText: 'Describe visible condition, damage, or frame notes.',
    maxLines: 4,
  ),
];

class _EditableArtworkField {
  const _EditableArtworkField({
    required this.key,
    required this.label,
    required this.helperText,
    this.keyboardType = TextInputType.text,
    this.maxLines = 1,
    this.usesStructuredMoney = false,
  });

  final String key;
  final String label;
  final String helperText;
  final TextInputType keyboardType;
  final int maxLines;
  final bool usesStructuredMoney;
}

bool _hasCompleteConfirmedCoreFields(Map<String, ArtworkFieldValue> fields) {
  return _coreFieldKeys.every((key) {
    final field = fields[key];
    return field != null &&
        field.value.trim().isNotEmpty &&
        field.source == ArtworkFieldSource.userConfirmed;
  });
}

class ArtworkRouteData {
  const ArtworkRouteData({
    required this.artwork,
    required this.isAiDraftReview,
    this.latestAiDraftJob,
    this.latestResearchJob,
  });

  final PrototypeArtwork artwork;
  final bool isAiDraftReview;
  final AiDraftJob? latestAiDraftJob;
  final ResearchJob? latestResearchJob;
}

Future<ArtworkRouteData> artworkDataForRoute(
  BuildContext context,
  String artworkId,
) async {
  final locale = Localizations.maybeLocaleOf(context) ?? const Locale('en');
  final dependencies = _maybeDependencies(context);
  final record = dependencies == null
      ? null
      : await dependencies.artworkRepository.get(artworkId);
  if (record == null) {
    return const ArtworkRouteData(
      artwork: prototypeArtwork,
      isAiDraftReview: true,
    );
  }

  final attachments = await dependencies!.artworkRepository
      .attachmentsForArtwork(record.id);
  final aiDraftJobs = await dependencies.artworkRepository
      .aiDraftJobsForArtwork(record.id);
  final researchJobs = await dependencies.artworkRepository
      .researchJobsForArtwork(record.id);
  return ArtworkRouteData(
    artwork: prototypeArtworkFromRecord(
      record,
      attachments: attachments,
      locale: locale,
    ),
    isAiDraftReview:
        aiDraftJobs.isNotEmpty &&
        aiDraftJobs.first.status == AiDraftJobStatus.completed,
    latestAiDraftJob: aiDraftJobs.isEmpty ? null : aiDraftJobs.first,
    latestResearchJob: researchJobs.isEmpty ? null : researchJobs.first,
  );
}

PrototypeArtwork prototypeArtworkFromRecord(
  ArtworkRecord record, {
  List<AttachmentRecord> attachments = const [],
  Locale locale = const Locale('en'),
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
    purchasePrice: _field(
      record,
      key: ArtworkFieldKeys.purchasePrice,
      label: 'Purchase price',
      fallback: 'Not set',
      locale: locale,
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
      locale: locale,
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
  Locale? locale,
}) {
  final value = record.field(key);
  return PrototypeField(
    label: label,
    value: value == null ? fallback : _displayFieldValue(value, locale: locale),
    source: _prototypeSource(value?.source ?? ArtworkFieldSource.unknown),
    note: value?.note ?? 'Confirm this field before using it in a report.',
  );
}

String _displayFieldValue(ArtworkFieldValue value, {Locale? locale}) {
  final activeLocale = locale ?? const Locale('en');
  return AppCurrencyFormatter.displayMoneyValue(
    locale: activeLocale,
    rawValue: value.value,
    amount: value.moneyAmount,
    currencyCode: value.moneyCurrencyCode,
  );
}

String? _normalizeMoneyAmount(String rawValue) {
  final trimmed = rawValue.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final normalized = trimmed.replaceAll(',', '.');
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(normalized)) {
    throw StateError(
      'Structured money amount must use digits with an optional decimal part.',
    );
  }
  return normalized;
}

String? _normalizeCurrencyCode(String rawValue) {
  final trimmed = rawValue.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final normalized = trimmed.toUpperCase();
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(normalized)) {
    throw StateError(
      'Structured money currency must be a three-letter ISO code.',
    );
  }
  return normalized;
}

String _userFacingEditError(Object error) {
  return error.toString().replaceFirst(
    RegExp(r'^(Bad state|FormatException):\s*'),
    '',
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
