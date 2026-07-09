import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../l10n/app_localizations.dart';
import '../ai/on_device_ai_draft_service.dart';
import '../app_dependencies.dart';
import '../app_routes.dart';
import '../billing/entitlement_plan.dart';
import '../intake/artwork_intake_service.dart';
import '../intake/supporting_attachment_service.dart';
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
      appBarTitle: 'Archivale',
      title: 'Private collection records',
      subtitle: 'Photograph, draft, confirm, preserve.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ArtworkHero(),
          const SizedBox(height: 16),
          const _Notice(
            icon: Icons.auto_awesome,
            text:
                'Photograph an artwork. Archivale drafts the record. You confirm the facts.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Keep your collection on this device, with backup in your Google account when you choose it.',
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
      title: 'Start your first artwork record',
      subtitle: 'Photograph, draft, confirm, preserve.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Notice(
            icon: Icons.privacy_tip_outlined,
            text:
                'Archivale helps you draft the record, but it does not determine authenticity or appraise value.',
          ),
          const SizedBox(height: 16),
          const _ProgressStrip(activeIndex: 0),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.add_a_photo_outlined,
            label: 'Photograph artwork',
            routeName: AppRoutes.onboardingFirstAdd,
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
      subtitle: 'Private by default',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Notice(
            icon: Icons.cloud_done_outlined,
            text:
                'Backup stays in your Google account only when you choose it.',
          ),
          SizedBox(height: 12),
          Text(
            'Your first record begins on this device, and every draft or document detail stays labeled for you to confirm.',
          ),
        ],
      ),
    );
  }
}

class SettingsPrivacyScreen extends StatelessWidget {
  const SettingsPrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PrototypeScreenFrame(
      title: 'Privacy',
      subtitle: 'Private by default',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Notice(
            icon: Icons.lock_outline,
            text:
                'Your artwork records stay private, and every draft stays under your review before it becomes part of the record.',
          ),
          SizedBox(height: 12),
          _StatusPanel(
            icon: Icons.fact_check_outlined,
            title: 'You confirm the facts',
            body:
                'Archivale can help draft details from photos and supporting records, but only your review turns them into trusted record details.',
          ),
          SizedBox(height: 12),
          _StatusPanel(
            icon: Icons.cloud_done_outlined,
            title: 'Backup stays in your account',
            body:
                'When you turn on backup, your records stay in your Google account so you can keep a second copy you control.',
          ),
        ],
      ),
    );
  }
}

class SettingsStorageScreen extends StatelessWidget {
  const SettingsStorageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PrototypeScreenFrame(
      title: 'Storage',
      subtitle: 'Keep records close at hand',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Notice(
            icon: Icons.phone_android_outlined,
            text:
                'Artwork photos, notes, and supporting records stay together on this device unless you choose backup.',
          ),
          SizedBox(height: 12),
          _StatusPanel(
            icon: Icons.inventory_2_outlined,
            title: 'One record, one place',
            body:
                'Receipts, certificates, condition notes, and report details stay grouped with the artwork record they support.',
          ),
          SizedBox(height: 12),
          _StatusPanel(
            icon: Icons.delete_outline,
            title: 'Delete local data with care',
            body:
                'Before you clear local records, make sure the archive you want to keep is already backed up or exported.',
          ),
        ],
      ),
    );
  }
}

class SettingsBackupScreen extends StatelessWidget {
  const SettingsBackupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PrototypeScreenFrame(
      title: 'Backup',
      subtitle: 'Keep a second copy you control',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Notice(
            icon: Icons.cloud_done_outlined,
            text:
                'Backup is the place to keep an extra copy of your collection in your own Google account.',
          ),
          SizedBox(height: 12),
          _StatusPanel(
            icon: Icons.cloud_off_outlined,
            title: 'Not connected yet',
            body:
                'Backup is not connected in this preview, so your records stay only on this device for now.',
          ),
          SizedBox(height: 12),
          _StatusPanel(
            icon: Icons.link_off_outlined,
            title: 'Disconnect backup',
            body:
                'When you pause backup, the records already saved on this device still stay with you.',
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
  Future<_CollectionHomeData>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = _maybeDependencies(context);
    _data ??= dependencies == null
        ? null
        : _loadCollectionHomeData(dependencies);
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = _maybeDependencies(context);
    if (dependencies != null) {
      return FutureBuilder<_CollectionHomeData>(
        future: _data,
        builder: (context, snapshot) {
          final data = snapshot.data ?? _CollectionHomeData.empty;
          return _CollectionHomeContent(
            records: data.records,
            currentActiveArtworkCount: data.currentActiveArtworkCount,
            entitlementState: data.entitlementState,
          );
        },
      );
    }

    return const _CollectionHomeContent(
      records: [],
      currentActiveArtworkCount: 0,
      entitlementState: EntitlementState(plan: EntitlementPlans.free),
    );
  }
}

class _CollectionHomeContent extends StatelessWidget {
  const _CollectionHomeContent({
    required this.records,
    required this.currentActiveArtworkCount,
    required this.entitlementState,
  });

  final List<_LocalArtworkSummary> records;
  final int currentActiveArtworkCount;
  final EntitlementState entitlementState;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final plan = entitlementState.plan;
    final canAddArtwork = plan.canAddActiveArtworks(
      currentActiveArtworkCount: currentActiveArtworkCount,
    );
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _Heading(
          title: 'Collection',
          subtitle: 'Your private artwork records',
        ),
        const SizedBox(height: 16),
        _LimitHint(
          currentActiveArtworkCount: currentActiveArtworkCount,
          entitlementState: entitlementState,
        ),
        const SizedBox(height: 16),
        if (records.isEmpty)
          _EmptyCollectionPanel(entitlementState: entitlementState)
        else ...[
          for (final summary in records) ...[
            _CollectionRecordPanel(summary: summary),
            const SizedBox(height: 12),
          ],
          if (canAddArtwork) ...[
            PrimaryActionButton(
              icon: Icons.add_a_photo_outlined,
              label: l10n.addArtworkAction,
              routeName: AppRoutes.collectionAdd,
            ),
            const SizedBox(height: 12),
            const SecondaryActionButton(
              icon: Icons.table_view_outlined,
              label: 'Import CSV',
              routeName: AppRoutes.collectionImportCsv,
            ),
          ] else
            _BillingGatePanel(
              currentActiveArtworkCount: currentActiveArtworkCount,
              entitlementState: entitlementState,
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
          title: 'Needs review',
          subtitle: 'Records worth another look',
        ),
        const SizedBox(height: 16),
        if (items.isEmpty)
          const _StatusPanel(
            icon: Icons.check_circle_outline,
            title: 'Nothing needs review',
            body:
                'As you confirm details and add supporting records, finished records leave this list.',
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

class ReportsHomeScreen extends StatefulWidget {
  const ReportsHomeScreen({super.key});

  @override
  State<ReportsHomeScreen> createState() => _ReportsHomeScreenState();
}

class _ReportsHomeScreenState extends State<ReportsHomeScreen> {
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
          return _ReportsHomeContent(records: snapshot.data ?? const []);
        },
      );
    }

    return const _ReportsHomeContent(records: []);
  }
}

class _ReportsHomeContent extends StatelessWidget {
  const _ReportsHomeContent({required this.records});

  final List<_LocalArtworkSummary> records;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.maybeLocaleOf(context) ?? const Locale('en');
    final firstSummary = records.isEmpty ? null : records.first;
    final firstArtwork = firstSummary == null
        ? null
        : prototypeArtworkFromRecord(
            firstSummary.record,
            attachments: firstSummary.attachments,
            locale: locale,
          );
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _Heading(
          title: 'Reports',
          subtitle:
              'Keep a clear record ready for insurance, estate, and personal files.',
        ),
        const SizedBox(height: 16),
        if (firstArtwork == null)
          const _StatusPanel(
            icon: Icons.inventory_2_outlined,
            title: 'No local records available',
            body:
                'Add or import an artwork before preparing a report or record export.',
          )
        else ...[
          _ReportSummary(artwork: firstArtwork),
          const SizedBox(height: 16),
          PrimaryActionButton(
            icon: Icons.picture_as_pdf_outlined,
            label: 'Preview artwork report',
            routeName: AppRoutes.artworkReportPreview(firstArtwork.id),
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.archive_outlined,
            label: 'Preview record export',
            routeName: AppRoutes.artworkExport(firstArtwork.id),
          ),
        ],
      ],
    );
  }
}

class SettingsHomeScreen extends StatelessWidget {
  const SettingsHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dependencies = _maybeDependencies(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _Heading(
          title: 'Settings',
          subtitle: 'Privacy, storage, backup, and exports',
        ),
        const SizedBox(height: 16),
        if (dependencies != null) ...[
          FutureBuilder<EntitlementState>(
            future: dependencies.entitlementService.currentState(),
            builder: (context, snapshot) {
              final entitlementState =
                  snapshot.data ??
                  const EntitlementState(plan: EntitlementPlans.free);
              return _PlanStatusPanel(entitlementState: entitlementState);
            },
          ),
          const SizedBox(height: 12),
        ],
        const _Notice(
          icon: Icons.lock_outline,
          text:
              'Choose how your records stay private, where they are kept, and when to save a second copy.',
        ),
        const SizedBox(height: 12),
        const _StatusPanel(
          icon: Icons.privacy_tip_outlined,
          title: 'Privacy',
          body:
              'Review how Archivale keeps drafts separate from the record you confirm.',
        ),
        const SizedBox(height: 12),
        const SecondaryActionButton(
          icon: Icons.privacy_tip_outlined,
          label: 'Review privacy',
          routeName: AppRoutes.settingsPrivacy,
        ),
        const SizedBox(height: 12),
        const _StatusPanel(
          icon: Icons.storage_outlined,
          title: 'Storage',
          body:
              'See how artwork photos, notes, and supporting records stay organized on this device.',
        ),
        const SizedBox(height: 12),
        const SecondaryActionButton(
          icon: Icons.storage_outlined,
          label: 'Review storage',
          routeName: AppRoutes.settingsStorage,
        ),
        const SizedBox(height: 12),
        const _StatusPanel(
          icon: Icons.cloud_done_outlined,
          title: 'Backup',
          body:
              'Keep a second copy in your Google account when backup is available.',
        ),
        const SizedBox(height: 12),
        const SecondaryActionButton(
          icon: Icons.cloud_done_outlined,
          label: 'Review backup',
          routeName: AppRoutes.settingsBackup,
        ),
        const SizedBox(height: 12),
        const _StatusPanel(
          icon: Icons.ios_share_outlined,
          title: 'Archive export preview',
          body:
              'Review what an export includes before you move or store a copy of your archive.',
        ),
        const SizedBox(height: 12),
        const SecondaryActionButton(
          icon: Icons.archive_outlined,
          label: 'Review archive export',
          routeName: AppRoutes.settingsExport,
        ),
      ],
    );
  }
}

class _PlanStatusPanel extends StatelessWidget {
  const _PlanStatusPanel({required this.entitlementState});

  final EntitlementState entitlementState;

  @override
  Widget build(BuildContext context) {
    final plan = entitlementState.plan;
    final billingCopy = switch (entitlementState.billingStatus) {
      EntitlementBillingStatus.available =>
        'You can review plan previews here. In-app upgrades are not available in this build yet.',
      EntitlementBillingStatus.unavailable =>
        'You can review plan previews here, but in-app upgrades are unavailable on this device right now.',
      EntitlementBillingStatus.notConfigured =>
        'You can review plan previews here, but in-app upgrades are not available in this preview yet.',
    };

    return _StatusPanel(
      icon: Icons.workspace_premium_outlined,
      title: '${plan.name} plan',
      body:
          '${_planArtworkLimitCopy(plan)}, ${_planResearchDraftCopy(plan)}. Existing records remain editable and exportable. $billingCopy',
    );
  }
}

class AddArtworkScreen extends StatelessWidget {
  const AddArtworkScreen({super.key, this.isOnboardingFirstAdd = false});

  final bool isOnboardingFirstAdd;

  @override
  Widget build(BuildContext context) {
    final dependencies = _maybeDependencies(context);
    return PrototypeScreenFrame(
      title: 'Add artwork',
      subtitle: 'Start a lasting record with one artwork image',
      child: dependencies == null
          ? _AddArtworkActions(isOnboardingFirstAdd: isOnboardingFirstAdd)
          : FutureBuilder<_CreationGate>(
              future: _loadCreationGate(dependencies),
              builder: (context, snapshot) {
                return _AddArtworkActions(
                  gate: snapshot.data,
                  isOnboardingFirstAdd: isOnboardingFirstAdd,
                );
              },
            ),
    );
  }
}

class _AddArtworkActions extends StatelessWidget {
  const _AddArtworkActions({this.gate, required this.isOnboardingFirstAdd});

  final _CreationGate? gate;
  final bool isOnboardingFirstAdd;

  @override
  Widget build(BuildContext context) {
    final gate = this.gate;
    final isAllowed = gate == null || gate.canAddRequestedArtworkCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _ProgressStrip(activeIndex: 0),
        const SizedBox(height: 20),
        if (isAllowed) ...[
          const _EvidencePhotoGuide(),
          const SizedBox(height: 16),
          PrimaryActionButton(
            icon: Icons.photo_camera_outlined,
            label: 'Photograph artwork',
            routeName: AppRoutes.capture,
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.photo_library_outlined,
            label: 'Choose artwork photo',
            routeName: AppRoutes.import,
          ),
        ] else
          _BillingGatePanel(
            currentActiveArtworkCount: gate.currentActiveArtworkCount,
            entitlementState: gate.entitlementState,
          ),
        const SizedBox(height: 12),
        _StatusPanel(
          icon: Icons.attach_file,
          title: 'Add supporting records next',
          body: isOnboardingFirstAdd
              ? 'Create the artwork record first, then add supporting photos and records when they are ready.'
              : 'Begin with the main artwork image, then add labels, receipts, and other supporting records when ready.',
        ),
        const SizedBox(height: 20),
        const _Notice(
          icon: Icons.auto_awesome,
          text:
              'Archivale keeps draft details separate until you confirm them.',
        ),
      ],
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
  Future<_CreationGate>? _creationGate;
  ArtworkIntakeResult? _result;
  AiDraftJob? _aiDraftJob;
  OnDeviceAiCapability? _aiCapability;
  ArtworkIntakeException? _failure;
  bool _isBusy = false;
  bool _isAiDraftBusy = false;
  bool _isAiDownloadBusy = false;

  bool get _isImport => widget.mode == 'import';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = _maybeDependencies(context);
    _creationGate ??= dependencies == null
        ? null
        : _loadCreationGate(dependencies);
  }

  @override
  Widget build(BuildContext context) {
    if (_maybeDependencies(context) == null) {
      return _StaticCaptureImportScreen(mode: widget.mode);
    }

    final creationGate = _creationGate;
    if (creationGate != null && _result == null) {
      return FutureBuilder<_CreationGate>(
        future: creationGate,
        builder: (context, snapshot) {
          final gate = snapshot.data;
          if (gate == null) {
            return PrototypeScreenFrame(
              title: _isImport ? 'Choose artwork photo' : 'Photograph artwork',
              subtitle: 'Preparing your record',
              child: const _StatusPanel(
                icon: Icons.workspace_premium_outlined,
                title: 'Checking room for a new record',
                body:
                    'Making sure this collection can open one more active record.',
              ),
            );
          }
          if (!gate.canAddRequestedArtworkCount) {
            return PrototypeScreenFrame(
              title: _isImport ? 'Choose artwork photo' : 'Photograph artwork',
              subtitle: 'Collection capacity',
              child: _BillingGatePanel(
                currentActiveArtworkCount: gate.currentActiveArtworkCount,
                entitlementState: gate.entitlementState,
              ),
            );
          }
          return _buildIntakeFrame();
        },
      );
    }

    return _buildIntakeFrame();
  }

  Widget _buildIntakeFrame() {
    return PrototypeScreenFrame(
      title: _isImport ? 'Choose artwork photo' : 'Photograph artwork',
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
            aiCapability: _aiCapability,
            failure: _failure,
            attachmentStore: AppDependencyScope.of(context).attachmentStore,
            isAiDownloadBusy: _isAiDownloadBusy,
            onDownloadAiModel: _isAiDownloadBusy
                ? null
                : _downloadOnDeviceAiModel,
            onCheckAiAvailability: _isAiDownloadBusy
                ? null
                : _checkOnDeviceAiAvailability,
            onRetryAiDraft: _isAiDraftBusy ? null : _retryPrivateAiDraft,
          ),
          const SizedBox(height: 12),
          if (_result == null) ...[
            const _EvidencePhotoGuide(),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 20),
          if (_result == null) ...[
            _ActionButton(
              icon: _isImport
                  ? Icons.photo_library_outlined
                  : Icons.photo_camera_outlined,
              label: _isImport ? 'Choose artwork photo' : 'Open camera',
              onPressed: _isBusy ? null : _runIntake,
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.restore_outlined,
              label: 'Recover last import',
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
      final dependencies = AppDependencyScope.of(context);
      await _ensureCanCreateArtwork(dependencies);
      final service = dependencies.createIntakeService();
      return _isImport ? service.importImage() : service.captureImage();
    });
  }

  Future<void> _recoverLostImage() async {
    await _withBusyState(() async {
      final dependencies = AppDependencyScope.of(context);
      await _ensureCanCreateArtwork(dependencies);
      final recovered = await dependencies
          .createIntakeService()
          .recoverLostImage();
      if (recovered == null) {
        throw const ArtworkIntakeException(
          ArtworkIntakeFailure.sourceUnavailable,
          'No previous import was found.',
        );
      }
      return recovered;
    });
  }

  Future<void> _ensureCanCreateArtwork(AppDependencies dependencies) async {
    final gate = await _loadCreationGate(dependencies);
    if (mounted) {
      setState(() {
        _creationGate = Future.value(gate);
      });
    }
    if (gate.canAddRequestedArtworkCount) {
      return;
    }

    throw const ArtworkIntakeException(
      ArtworkIntakeFailure.sourceUnavailable,
      'This plan already holds all of its active records. Existing records stay editable and exportable.',
    );
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
        _aiCapability = null;
        _isAiDownloadBusy = false;
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
    final capability = await _safeCheckOnDeviceAiAvailability(service);

    if (!mounted) {
      return;
    }
    setState(() {
      _aiDraftJob = draftJob;
      _aiCapability = capability;
      _isAiDraftBusy = false;
    });
  }

  Future<void> _downloadOnDeviceAiModel() async {
    final result = _result;
    if (result == null) {
      return;
    }

    final service = AppDependencyScope.of(
      context,
    ).createOnDeviceAiDraftService();
    setState(() => _isAiDownloadBusy = true);
    final capability = await _safeDownloadOnDeviceAiModel(service);

    if (!mounted) {
      return;
    }
    setState(() {
      _aiCapability = capability;
      _isAiDownloadBusy = false;
    });
    if (capability?.canRunDraft ?? false) {
      await _runPrivateAiDraft(result);
    }
  }

  Future<void> _checkOnDeviceAiAvailability() async {
    final result = _result;
    if (result == null) {
      return;
    }

    final service = AppDependencyScope.of(
      context,
    ).createOnDeviceAiDraftService();
    setState(() => _isAiDownloadBusy = true);
    final capability = await _safeCheckOnDeviceAiAvailability(service);

    if (!mounted) {
      return;
    }
    setState(() {
      _aiCapability = capability;
      _isAiDownloadBusy = false;
    });
    if (capability?.canRunDraft ?? false) {
      await _runPrivateAiDraft(result);
    }
  }

  Future<void> _retryPrivateAiDraft() async {
    final result = _result;
    if (result == null) {
      return;
    }
    await _runPrivateAiDraft(result);
  }

  Future<OnDeviceAiCapability?> _safeCheckOnDeviceAiAvailability(
    OnDeviceAiDraftService service,
  ) async {
    try {
      return await service.checkAvailability();
    } on Exception {
      return null;
    }
  }

  Future<OnDeviceAiCapability?> _safeDownloadOnDeviceAiModel(
    OnDeviceAiDraftService service,
  ) async {
    try {
      return await service.downloadModel();
    } on Exception {
      return const OnDeviceAiCapability(
        availability: OnDeviceAiAvailability.downloadFailed,
        message:
            'On-device AI download could not finish yet. Try again after checking AICore.',
      );
    }
  }
}

class SupportingPhotoIntakeScreen extends StatefulWidget {
  const SupportingPhotoIntakeScreen({
    super.key,
    required this.artworkId,
    required this.mode,
  });

  final String artworkId;
  final String mode;

  @override
  State<SupportingPhotoIntakeScreen> createState() =>
      _SupportingPhotoIntakeScreenState();
}

class _SupportingPhotoIntakeScreenState
    extends State<SupportingPhotoIntakeScreen> {
  Future<ArtworkRecord?>? _recordFuture;
  SupportingAttachmentResult? _result;
  ArtworkIntakeException? _failure;
  bool _isBusy = false;

  bool get _isImport => widget.mode == 'import';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = _maybeDependencies(context);
    _recordFuture ??= dependencies == null
        ? Future<ArtworkRecord?>.value(null)
        : dependencies.artworkRepository.get(widget.artworkId);
  }

  @override
  Widget build(BuildContext context) {
    if (_maybeDependencies(context) == null) {
      return _StaticSupportingPhotoIntakeScreen(
        artworkId: widget.artworkId,
        mode: widget.mode,
      );
    }

    return FutureBuilder<ArtworkRecord?>(
      future: _recordFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const PrototypeScreenFrame(
            title: 'Supporting photo',
            subtitle: 'Loading artwork record',
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final record = snapshot.data;
        if (record == null) {
          return const PrototypeScreenFrame(
            title: 'Supporting photo',
            subtitle: 'Artwork unavailable',
            child: _StatusPanel(
              icon: Icons.error_outline,
              title: 'Record not found',
              body:
                  'Return to Collection and reopen the artwork before adding supporting records.',
            ),
          );
        }

        final title =
            record.field(ArtworkFieldKeys.title)?.value ?? 'Untitled artwork';
        return PrototypeScreenFrame(
          title: _isImport
              ? 'Import supporting photo'
              : 'Take supporting photo',
          subtitle: title,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _ProgressStrip(activeIndex: 2),
              const SizedBox(height: 16),
              _SupportingPhotoStatePanel(
                isImport: _isImport,
                isBusy: _isBusy,
                result: _result,
                failure: _failure,
                attachmentStore: AppDependencyScope.of(context).attachmentStore,
              ),
              const SizedBox(height: 12),
              if (_result == null) ...[
                const _EvidencePhotoGuide(isFollowUp: true),
                const SizedBox(height: 12),
                const _StatusPanel(
                  icon: Icons.lock_outline,
                  title: 'Saved with this artwork',
                  body:
                      'This photo stays with this artwork as a supporting record. Your main artwork image stays as it is.',
                ),
                const SizedBox(height: 20),
                _ActionButton(
                  icon: _isImport
                      ? Icons.photo_library_outlined
                      : Icons.photo_camera_outlined,
                  label: _isImport
                      ? 'Choose a supporting photo'
                      : 'Take a supporting photo',
                  onPressed: _isBusy ? null : _runIntake,
                ),
              ] else ...[
                PrimaryActionButton(
                  icon: Icons.folder_copy_outlined,
                  label: 'View supporting records',
                  routeName: AppRoutes.artworkDocuments(widget.artworkId),
                ),
                const SizedBox(height: 12),
                SecondaryActionButton(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'Report preview',
                  routeName: AppRoutes.artworkReportPreview(widget.artworkId),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _runIntake() async {
    setState(() {
      _isBusy = true;
      _failure = null;
    });

    try {
      final service = AppDependencyScope.of(
        context,
      ).createSupportingAttachmentService();
      final result = _isImport
          ? await service.importSupportingPhoto(widget.artworkId)
          : await service.captureSupportingPhoto(widget.artworkId);
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

class _SupportingPhotoStatePanel extends StatelessWidget {
  const _SupportingPhotoStatePanel({
    required this.isImport,
    required this.isBusy,
    required this.result,
    required this.failure,
    required this.attachmentStore,
  });

  final bool isImport;
  final bool isBusy;
  final SupportingAttachmentResult? result;
  final ArtworkIntakeException? failure;
  final LocalAttachmentStore attachmentStore;

  @override
  Widget build(BuildContext context) {
    if (isBusy) {
      return _StatusPanel(
        icon: Icons.hourglass_top,
        title: isImport ? 'Opening photo picker' : 'Opening camera',
        body: isImport
            ? 'Choose one photo to keep with this artwork as a supporting record.'
            : 'Take one photo to keep with this artwork as a supporting record.',
      );
    }

    final result = this.result;
    if (result != null) {
      return Column(
        children: [
          _StatusPanel(
            icon: isImport
                ? Icons.file_upload_outlined
                : Icons.camera_alt_outlined,
            title: isImport
                ? 'Supporting photo imported'
                : 'Supporting photo captured',
            body:
                'Added to this artwork as a supporting record. Your main artwork image is unchanged.',
          ),
          const SizedBox(height: 12),
          _PrimaryArtworkImagePreview(
            file: attachmentStore.fileFor(result.attachment),
            semanticLabel: 'Supporting record photo',
            unavailableLabel: 'Supporting photo preview unavailable',
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
            ? 'Supporting photo cancelled'
            : 'Supporting photo needs attention',
        body: '${failure.message} You can try again when ready.',
      );
    }

    return _StatusPanel(
      icon: isImport
          ? Icons.photo_library_outlined
          : Icons.photo_camera_outlined,
      title: isImport ? 'Choose from your photos' : 'Use your camera',
      body:
          'Add a label, signature, reverse side, frame, receipt, or condition photo that helps preserve the record.',
    );
  }
}

class _StaticSupportingPhotoIntakeScreen extends StatelessWidget {
  const _StaticSupportingPhotoIntakeScreen({
    required this.artworkId,
    required this.mode,
  });

  final String artworkId;
  final String mode;

  @override
  Widget build(BuildContext context) {
    final isImport = mode == 'import';

    return PrototypeScreenFrame(
      title: isImport ? 'Import supporting photo' : 'Take supporting photo',
      subtitle: 'Supporting record photo',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ProgressStrip(activeIndex: 2),
          const SizedBox(height: 16),
          const _EvidencePhotoGuide(isFollowUp: true),
          const SizedBox(height: 12),
          _StatusPanel(
            icon: isImport ? Icons.file_upload_outlined : Icons.camera_alt,
            title: isImport
                ? 'Supporting photo imported'
                : 'Supporting photo captured',
            body:
                'Added to this artwork as a supporting record. Your main artwork image is unchanged.',
          ),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.folder_copy_outlined,
            label: 'View supporting records',
            routeName: AppRoutes.artworkDocuments(artworkId),
          ),
        ],
      ),
    );
  }
}

class _StaticCaptureImportScreen extends StatelessWidget {
  const _StaticCaptureImportScreen({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final isImport = mode == 'import';

    return PrototypeScreenFrame(
      title: isImport ? 'Choose artwork photo' : 'Photograph artwork',
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
            title: isImport ? 'Artwork photo added' : 'Artwork photographed',
            body:
                'Your draft record is ready to review. If the import is interrupted, Archivale can help you pick it back up later.',
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
  String? _researchError;
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
          const _EvidencePhotoGuide(isFollowUp: true),
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
          SecondaryActionButton(
            icon: Icons.add_photo_alternate_outlined,
            label: 'Add supporting photo',
            routeName: AppRoutes.artworkSupportingPhotoImport(
              widget.artwork.id,
            ),
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
              'User approved the selected artwork image, draft details, and notes for Archivale research help.',
          consentState: ResearchConsentState.approved,
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
        _showResearchConsent = false;
        _researchError = _researchFailureMessage(error);
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
    final recordStateLabel = _prototypeRecordStateLabel(completenessFields);

    return PrototypeScreenFrame(
      title: artwork.title.value,
      subtitle: recordStateLabel,
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
          _CompletenessPanel(
            fields: completenessFields,
            recordStateLabel: recordStateLabel,
          ),
          const SizedBox(height: 16),
          for (final field in displayedFields) ...[
            FieldSourceTile(field: _detailDisplayField(field)),
            const SizedBox(height: 10),
          ],
          PrimaryActionButton(
            icon: Icons.edit_note_outlined,
            label: 'Edit record details',
            routeName: AppRoutes.artworkEdit(artwork.id),
          ),
          const SizedBox(height: 12),
          PrimaryActionButton(
            icon: Icons.add_photo_alternate_outlined,
            label: 'Add supporting records',
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
              'This private record and its files stay on this device, but the artwork will no longer count as a current holding.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Mark as removed'),
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
      if (record.lifecycleStatus != ArtworkLifecycleStatus.active &&
          status == ArtworkLifecycleStatus.active) {
        final gate = await _loadCreationGate(dependencies);
        if (!gate.canAddRequestedArtworkCount) {
          throw StateError(
            'This plan already holds all of its active records. Existing records stay editable and exportable.',
          );
        }
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
            title: 'Edit private record',
            subtitle: 'Loading your saved details',
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final record = snapshot.requireData;
        if (record == null) {
          return const PrototypeScreenFrame(
            title: 'Edit private record',
            subtitle: 'Saved record unavailable',
            child: _StatusPanel(
              icon: Icons.error_outline,
              title: 'Record not found',
              body:
                  'Return to Collection and open this artwork again before editing.',
            ),
          );
        }

        _seedControllers(record);

        return PrototypeScreenFrame(
          title: 'Edit private record',
          subtitle: 'Confirm the details you want to keep',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Notice(
                icon: Icons.verified_user_outlined,
                text:
                    'Saved edits are marked User confirmed. AI and research suggestions stay separate until you review and save them.',
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
                    helperMaxLines: field.helperMaxLines,
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
                            helperText:
                                'Numbers only. Leave out the currency symbol.',
                            helperMaxLines: 2,
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
                            helperText: 'Use USD, EUR, or NOK.',
                            helperMaxLines: 2,
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
                  title: 'Could not save this record',
                  body: _errorMessage!,
                ),
                const SizedBox(height: 14),
              ],
              _ActionButton(
                icon: Icons.save_outlined,
                label: _isSaving ? 'Saving...' : 'Save confirmed details',
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
      final fieldValue = value?.value ?? '';
      _controllers[field.key]!.text =
          _isPlaceholderCoreFieldValue(field.key, fieldValue) ? '' : fieldValue;
      if (field.usesStructuredMoney) {
        final usesPlaceholder = _isPlaceholderCoreFieldValue(
          field.key,
          fieldValue,
        );
        _moneyAmountControllers[field.key]!.text = usesPlaceholder
            ? ''
            : value?.moneyAmount ?? '';
        _moneyCurrencyControllers[field.key]!.text = usesPlaceholder
            ? ''
            : value?.moneyCurrencyCode ?? '';
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
            '${field.label} needs both an amount and a three-letter currency code.',
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

        final previousValue = record.field(field.key);
        final isPlaceholder = _isPlaceholderCoreFieldValue(field.key, value);
        final shouldConfirm = !isPlaceholder;
        fields[field.key] = ArtworkFieldValue(
          value: value,
          source: shouldConfirm
              ? ArtworkFieldSource.userConfirmed
              : (previousValue?.source ?? ArtworkFieldSource.unknown),
          note: shouldConfirm
              ? 'Saved as part of your confirmed record.'
              : (previousValue?.note ??
                    'Please confirm this detail before you rely on it.'),
          lastConfirmedAt: shouldConfirm ? now : previousValue?.lastConfirmedAt,
          moneyAmount: normalizedAmount,
          moneyCurrencyCode: normalizedCurrency,
        );
      }

      final updatedRecord = record.copyWith(
        recordState: _hasCompleteReviewedCoreFields(fields)
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
                'Supporting records help preserve context for this artwork. They do not prove authenticity.',
          ),
          const SizedBox(height: 16),
          if (artwork.documents.isEmpty)
            const _StatusPanel(
              icon: Icons.folder_copy_outlined,
              title: 'No supporting records yet',
              body:
                  'Add photos of labels, signatures, backs, frames, receipts, condition details, or provenance notes when they help tell the record clearly.',
            )
          else
            for (final document in artwork.documents) ...[
              DocumentTile(document: document),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 12),
          PrimaryActionButton(
            icon: Icons.photo_camera_outlined,
            label: 'Take supporting photo',
            routeName: AppRoutes.artworkSupportingPhotoCapture(artwork.id),
          ),
          const SizedBox(height: 12),
          SecondaryActionButton(
            icon: Icons.photo_library_outlined,
            label: 'Import supporting photo',
            routeName: AppRoutes.artworkSupportingPhotoImport(artwork.id),
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.block_outlined,
            title: 'Add paper records as photos for now',
            body:
                'For now, photograph receipts, certificates, auction records, gallery notes, or estate papers and keep them with this artwork.',
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.warning_amber_outlined,
            title: 'Attachment needs attention',
            body:
                'If one of these private files goes missing later, the record details stay here and you can add the photo again.',
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
      subtitle:
          'Ready a clear record for insurance conversations, estate organization, and personal files.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ProgressStrip(activeIndex: 3),
          const SizedBox(height: 16),
          _ReportSummary(artwork: artwork),
          const SizedBox(height: 16),
          const _StatusPanel(
            icon: Icons.fact_check_outlined,
            title: 'What the report includes',
            body:
                'Confirmed details, supporting record list, report date, and any user-provided insurance value.',
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.block_outlined,
            title: 'What it does not do',
            body:
                'No authenticity finding, appraisal, legal advice, or promise of insurance acceptance.',
          ),
          const SizedBox(height: 20),
          PrimaryActionButton(
            icon: Icons.ios_share_outlined,
            label: 'Preview record export',
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
      title: 'Record export preview',
      subtitle:
          'Keep a portable record for family, estate, and personal files.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReportSummary(artwork: artwork),
          const SizedBox(height: 16),
          const _LimitHint(
            currentActiveArtworkCount: 0,
            entitlementState: EntitlementState(plan: EntitlementPlans.free),
          ),
          const SizedBox(height: 16),
          const _StatusPanel(
            icon: Icons.archive_outlined,
            title: 'What the export includes',
            body:
                'Artwork details, how each detail was recorded, supporting record details, and report date.',
          ),
          const SizedBox(height: 12),
          const _StatusPanel(
            icon: Icons.picture_as_pdf_outlined,
            title: 'Insurance value note',
            body:
                'Any insurance value stays labeled as user-provided in the PDF record.',
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
      appBar: AppBar(title: Text(appBarTitle ?? 'Archivale')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
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
    final colors = _sourceColors(context, field.source);

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
    final colors = _sourceColors(context, document.source);

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
    required this.aiCapability,
    required this.failure,
    required this.attachmentStore,
    required this.isAiDownloadBusy,
    required this.onDownloadAiModel,
    required this.onCheckAiAvailability,
    required this.onRetryAiDraft,
  });

  final bool isImport;
  final bool isBusy;
  final bool isAiDraftBusy;
  final ArtworkIntakeResult? result;
  final AiDraftJob? aiDraftJob;
  final OnDeviceAiCapability? aiCapability;
  final ArtworkIntakeException? failure;
  final LocalAttachmentStore attachmentStore;
  final bool isAiDownloadBusy;
  final VoidCallback? onDownloadAiModel;
  final VoidCallback? onCheckAiAvailability;
  final VoidCallback? onRetryAiDraft;

  @override
  Widget build(BuildContext context) {
    if (isBusy) {
      return const _StatusPanel(
        icon: Icons.hourglass_top,
        title: 'Preparing your artwork record',
        body:
            'Use your camera or photo library. Archivale saves only the image you choose for this record.',
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
                ? 'Recovered artwork photo'
                : isImport
                ? 'Artwork photo added'
                : 'Artwork photographed',
            body:
                'Your record draft is ready to review. You can return from Collection and keep building it later.',
          ),
          const SizedBox(height: 12),
          _PrimaryArtworkImagePreview(
            file: attachmentStore.fileFor(result.primaryImage),
          ),
          const SizedBox(height: 12),
          _AiDraftStatusPanel(
            isBusy: isAiDraftBusy,
            draftJob: aiDraftJob,
            capability: aiCapability,
            isActionBusy: isAiDownloadBusy,
            onDownload: onDownloadAiModel,
            onCheckAgain: onCheckAiAvailability,
            onRetryDraft: onRetryAiDraft,
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
            ? 'No photo selected'
            : 'Could not start this record',
        body:
            '${failure.message} Try again when ready. Archivale only adds the photo you choose.',
      );
    }

    return _StatusPanel(
      icon: isImport
          ? Icons.photo_library_outlined
          : Icons.photo_camera_outlined,
      title: isImport ? 'Choose artwork photo' : 'Use camera',
      body:
          'Start with one clear artwork image. Archivale copies only that photo into your private record.',
    );
  }
}

class _AiDraftStatusPanel extends StatelessWidget {
  const _AiDraftStatusPanel({
    required this.isBusy,
    required this.draftJob,
    this.capability,
    this.isActionBusy = false,
    this.onDownload,
    this.onCheckAgain,
    this.onRetryDraft,
  });

  final bool isBusy;
  final AiDraftJob? draftJob;
  final OnDeviceAiCapability? capability;
  final bool isActionBusy;
  final VoidCallback? onDownload;
  final VoidCallback? onCheckAgain;
  final VoidCallback? onRetryDraft;

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
        icon: _unavailableIcon(capability),
        title: _unavailableTitle(capability),
        body: _unavailableBody(draftJob, capability),
        footer: _buildActionFooter(),
      ),
      AiDraftJobStatus.failed => _StatusPanel(
        icon: Icons.error_outline,
        title: 'Private AI draft failed',
        body:
            '${draftJob.errorMessage ?? 'The draft could not be created.'} You can continue manually.',
        footer: _buildActionFooter(),
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

  IconData _unavailableIcon(OnDeviceAiCapability? capability) {
    return switch (capability?.availability) {
      OnDeviceAiAvailability.downloadable => Icons.download_outlined,
      OnDeviceAiAvailability.downloading => Icons.downloading_outlined,
      OnDeviceAiAvailability.downloadFailed => Icons.error_outline,
      _ => Icons.offline_bolt_outlined,
    };
  }

  String _unavailableTitle(OnDeviceAiCapability? capability) {
    return switch (capability?.availability) {
      OnDeviceAiAvailability.downloadable => 'On-device AI download ready',
      OnDeviceAiAvailability.downloading => 'On-device AI downloading',
      OnDeviceAiAvailability.downloadFailed => 'On-device AI download failed',
      _ => 'On-device AI unavailable',
    };
  }

  String _unavailableBody(
    AiDraftJob draftJob,
    OnDeviceAiCapability? capability,
  ) {
    final message =
        capability?.message ??
        draftJob.errorMessage ??
        'This device or build cannot run a private AI draft yet.';
    return '$message No photo was sent online.';
  }

  Widget? _buildActionFooter() {
    final action = _resolveAction();
    if (action == null) {
      return null;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _ActionButton(
        icon: action.$1,
        label: action.$2,
        onPressed: isActionBusy ? null : action.$3,
      ),
    );
  }

  (IconData, String, VoidCallback?)? _resolveAction() {
    final capability = this.capability;
    if (capability == null) {
      return null;
    }

    return switch (capability.availability) {
      OnDeviceAiAvailability.downloadable => (
        Icons.download_outlined,
        'Download on-device AI',
        onDownload,
      ),
      OnDeviceAiAvailability.downloading => (
        Icons.refresh_outlined,
        'Check again',
        onCheckAgain,
      ),
      OnDeviceAiAvailability.downloadFailed => (
        Icons.refresh_outlined,
        'Retry download',
        onDownload,
      ),
      OnDeviceAiAvailability.available
          when draftJob != null &&
              draftJob!.status != AiDraftJobStatus.completed =>
        (Icons.auto_awesome_outlined, 'Retry local draft', onRetryDraft),
      _ => null,
    };
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
          if (isFollowUp) ...[
            const _EvidenceGuideItem(
              icon: Icons.crop_free_outlined,
              text:
                  'Close-ups of the signature or maker marks, frame labels, stickers, and reverse-side notes.',
            ),
            const _EvidenceGuideItem(
              icon: Icons.description_outlined,
              text: 'Receipts, certificates, auction, or provenance papers.',
            ),
          ] else ...[
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
              text:
                  'Dimensions, medium/material, condition, and frame details.',
            ),
            const _EvidenceGuideItem(
              icon: Icons.description_outlined,
              text:
                  'Receipts, certificates, gallery, auction, or estate papers.',
            ),
          ],
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
  final String? error;
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
        title: 'Research unavailable',
        body:
            'Archivale research is not available right now. Keep reviewing the draft and use your notes or supporting documents for now.',
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
      final errorMessage = error!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusPanel(
            icon: Icons.error_outline,
            title: 'Research unavailable',
            body: errorMessage,
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
            label: 'Research this draft',
            onPressed: onStart,
          ),
        ],
      ),
    );
  }
}

String _researchFailureMessage(Object error) {
  if (error is ResearchConsentRequiredException) {
    return 'Research consent needs to be reviewed before Archivale can run source-backed research.';
  }
  if (error is InvalidResearchResponseException) {
    return 'Archivale found a problem with the research result and could not display it safely. Continue reviewing your draft and try again later.';
  }
  if (error is DisallowedResearchSourceException) {
    return 'Archivale could not verify this research response. Please try again later.';
  }
  return 'Archivale could not finish source-backed research right now. Please try again.';
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
            'If you continue, Archivale may use the selected artwork image or thumbnail, the draft details on this screen, your notes, and a short private summary to look for museum, archive, and auction references. Your full collection stays private.',
          ),
          const SizedBox(height: 12),
          const _Notice(
            icon: Icons.fact_check_outlined,
            text:
                'Results are source-backed suggestions. They do not confirm authenticity, attribution certainty, or value.',
          ),
          const SizedBox(height: 12),
          _ActionButton(
            icon: Icons.check_circle_outline,
            label: isBusy ? 'Researching...' : 'Start source-backed research',
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
                'Archivale did not find a reliable source-backed match yet. Keep the draft, add documents, or return with clearer detail photos.',
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

    final summary = _comparableSignalsSummary(signals, sourceHits);

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.comparableSourceSignalsTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(summary),
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

String _comparableSignalsSummary(
  List<ComparableValueSignal> signals,
  List<ResearchSourceHit> sourceHits,
) {
  var sourceBackedCount = 0;
  var hiddenCount = 0;

  for (final signal in signals) {
    final kind = _effectiveComparableKind(signal, sourceHits);
    if (kind != signal.kind) {
      hiddenCount += 1;
      continue;
    }
    if (kind == ComparableValueKind.publicEstimate ||
        kind == ComparableValueKind.comparableSaleSignal) {
      sourceBackedCount += 1;
    }
  }

  if (sourceBackedCount > 0) {
    final signalWord = sourceBackedCount == 1 ? 'signal' : 'signals';
    return '$sourceBackedCount source-backed comparable $signalWord. These are source context only, not an appraisal.';
  }

  if (hiddenCount > 0) {
    final signalWord = hiddenCount == 1 ? 'signal was' : 'signals were';
    return '$hiddenCount comparable $signalWord hidden because linked sources are missing or could not be verified.';
  }

  return 'No comparable sale or public estimate was available from verified sources.';
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
        color: _nestedPanelColor(context),
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

String _researchSourceTypeLabel(ResearchSourceType type) {
  return switch (type) {
    ResearchSourceType.museumCollection => 'Museum collection',
    ResearchSourceType.culturalHeritageApi => 'Cultural archive',
    ResearchSourceType.gallery => 'Gallery',
    ResearchSourceType.artistFoundation => 'Artist foundation',
    ResearchSourceType.auctionHouse => 'Auction house',
    ResearchSourceType.reference ||
    ResearchSourceType.unknown => 'Reference source',
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
            colors: _sourceColors(context, PrototypeSource.aiSuggested),
          ),
          const SizedBox(height: 12),
          if (sourceHit != null) ...[
            Text('Source: ${sourceHit.sourceName}'),
            Text(
              'Source type: ${_researchSourceTypeLabel(sourceHit.sourceType)}',
            ),
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
        color: _nestedPanelColor(context),
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
                  colors: _sourceColors(context, PrototypeSource.aiSuggested),
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
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Archivale: Art Records',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 7),
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 7),
        Text(
          subtitle,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ArtworkHero extends StatelessWidget {
  const _ArtworkHero();

  @override
  Widget build(BuildContext context) {
    final colors = _artworkHeroColors(context);

    return AspectRatio(
      aspectRatio: 4 / 3,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.border),
          boxShadow: _panelShadow(context),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _ArtworkPainter(colors)),
            ),
            const Positioned(
              top: 14,
              left: 14,
              child: _MiniLabel(text: 'Private record'),
            ),
            const Positioned(
              left: 14,
              bottom: 12,
              child: _MiniLabel(text: 'Collector record example'),
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
    this.semanticLabel = 'Primary artwork image',
    this.unavailableLabel = 'Primary image preview unavailable',
  });

  static const imageKey = ValueKey('primary-artwork-image-preview');
  static const placeholderKey = ValueKey('primary-artwork-image-placeholder');

  final File? file;
  final bool isCompact;
  final String semanticLabel;
  final String unavailableLabel;

  @override
  Widget build(BuildContext context) {
    final file = this.file;
    final canAttemptImage = file != null && file.existsSync();
    final colors = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: isCompact ? 16 / 9 : 4 / 3,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            border: Border.all(color: colors.outlineVariant),
          ),
          child: canAttemptImage
              ? Image.file(
                  file,
                  key: imageKey,
                  fit: BoxFit.cover,
                  semanticLabel: semanticLabel,
                  errorBuilder: (context, error, stackTrace) {
                    return _PrimaryImagePlaceholder(label: unavailableLabel);
                  },
                )
              : _PrimaryImagePlaceholder(label: unavailableLabel),
        ),
      ),
    );
  }
}

class _PrimaryImagePlaceholder extends StatelessWidget {
  const _PrimaryImagePlaceholder({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      key: _PrimaryArtworkImagePreview.placeholderKey,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.collections_bookmark_outlined,
              size: 38,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtworkPainter extends CustomPainter {
  const _ArtworkPainter(this.colors);

  final _ArtworkHeroColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.wall);
    final frameRect = Rect.fromLTWH(
      size.width * .18,
      size.height * .17,
      size.width * .64,
      size.height * .58,
    );
    final matRect = frameRect.deflate(size.shortestSide * .035);
    final artRect = matRect.deflate(size.shortestSide * .055);
    canvas.drawRRect(
      RRect.fromRectAndRadius(frameRect, const Radius.circular(3)),
      Paint()..color = colors.frame,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(matRect, const Radius.circular(2)),
      Paint()..color = colors.mat,
    );
    canvas.drawRect(artRect, Paint()..color = colors.artwork);
    canvas.drawPath(
      Path()
        ..moveTo(artRect.left, artRect.bottom)
        ..lineTo(artRect.left + artRect.width * .34, artRect.top)
        ..lineTo(artRect.left + artRect.width * .58, artRect.bottom)
        ..close(),
      Paint()..color = colors.inner,
    );
    canvas.drawPath(
      Path()
        ..moveTo(artRect.left + artRect.width * .42, artRect.bottom)
        ..lineTo(artRect.right, artRect.top + artRect.height * .18)
        ..lineTo(artRect.right, artRect.bottom)
        ..close(),
      Paint()..color = colors.accent.withValues(alpha: .86),
    );
    canvas.drawOval(
      Rect.fromCircle(
        center: Offset(
          artRect.left + artRect.width * .68,
          artRect.top + artRect.height * .27,
        ),
        radius: size.shortestSide * .055,
      ),
      Paint()..color = colors.accent,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(frameRect.deflate(4), const Radius.circular(2)),
      Paint()
        ..color = colors.frameLine
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final ledgerTop = size.height * .8;
    canvas.drawLine(
      Offset(size.width * .18, ledgerTop),
      Offset(size.width * .82, ledgerTop),
      Paint()
        ..color = colors.frameLine
        ..strokeWidth = 1.4,
    );
    canvas.drawLine(
      Offset(size.width * .25, ledgerTop + 12),
      Offset(size.width * .57, ledgerTop + 12),
      Paint()
        ..color = colors.frameLine.withValues(alpha: .58)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _ArtworkPainter oldDelegate) {
    return oldDelegate.colors != colors;
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _panelColor(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        boxShadow: _panelShadow(context),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
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
          overflow: TextOverflow.ellipsis,
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

_BadgeColors _sourceColors(BuildContext context, PrototypeSource source) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  if (isDark) {
    return switch (source) {
      PrototypeSource.userConfirmed => const _BadgeColors(
        Color(0xFF183326),
        Color(0xFF6FA27A),
        Color(0xFFD2ECD7),
      ),
      PrototypeSource.documentExtracted => const _BadgeColors(
        Color(0xFF172E3B),
        Color(0xFF75A6C7),
        Color(0xFFD5E8F4),
      ),
      PrototypeSource.aiSuggested => const _BadgeColors(
        Color(0xFF3A2B12),
        Color(0xFFD0A75C),
        Color(0xFFFFE4AA),
      ),
      PrototypeSource.unknown => const _BadgeColors(
        Color(0xFF302A36),
        Color(0xFFA698B4),
        Color(0xFFE9DDF2),
      ),
    };
  }

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
    'Photograph',
    'Review draft',
    'Attach records',
    'Preserve',
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
                  : _panelColor(context),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: index <= activeIndex
                    ? colorScheme.primary
                    : colorScheme.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${index + 1}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: index <= activeIndex
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _steps[index],
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: index <= activeIndex
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
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
          _IconMedallion(icon: icon),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _LimitHint extends StatelessWidget {
  const _LimitHint({
    required this.currentActiveArtworkCount,
    required this.entitlementState,
  });

  final int currentActiveArtworkCount;
  final EntitlementState entitlementState;

  @override
  Widget build(BuildContext context) {
    final plan = entitlementState.plan;
    final remaining = plan.remainingActiveArtworkSlots(
      currentActiveArtworkCount,
    );
    final usage = plan.activeArtworkLimit == null
        ? '$currentActiveArtworkCount active records'
        : '$currentActiveArtworkCount of ${plan.activeArtworkLimit} active records';
    final remainingCopy = remaining == null
        ? 'Your plan has room for your full collection.'
        : remaining == 0
        ? 'This plan is at capacity. Existing records stay editable and exportable.'
        : '$remaining more active record${remaining == 1 ? '' : 's'} can be added in this plan.';

    return _StatusPanel(
      icon: Icons.workspace_premium_outlined,
      title: '${plan.name} plan: $usage',
      body:
          '$remainingCopy ${_planResearchDraftCopy(plan)} included each month.',
    );
  }
}

class _EmptyCollectionPanel extends StatelessWidget {
  const _EmptyCollectionPanel({required this.entitlementState});

  final EntitlementState entitlementState;

  @override
  Widget build(BuildContext context) {
    final plan = entitlementState.plan;
    final canAddArtwork = plan.canAddActiveArtworks(
      currentActiveArtworkCount: 0,
    );

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ArtworkHero(),
          const SizedBox(height: 14),
          Text(
            'No artworks yet',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text(
            'Begin with one artwork photo, then keep notes, supporting records, and report-ready details together.',
          ),
          const SizedBox(height: 16),
          if (canAddArtwork) ...[
            PrimaryActionButton(
              icon: Icons.add_a_photo_outlined,
              label: 'Add artwork',
              routeName: AppRoutes.collectionAdd,
            ),
            const SizedBox(height: 12),
            const SecondaryActionButton(
              icon: Icons.table_view_outlined,
              label: 'Import CSV',
              routeName: AppRoutes.collectionImportCsv,
            ),
          ] else
            _BillingGatePanel(
              currentActiveArtworkCount: 0,
              entitlementState: entitlementState,
            ),
        ],
      ),
    );
  }
}

class _BillingGatePanel extends StatelessWidget {
  const _BillingGatePanel({
    required this.currentActiveArtworkCount,
    required this.entitlementState,
  });

  final int currentActiveArtworkCount;
  final EntitlementState entitlementState;

  @override
  Widget build(BuildContext context) {
    final plan = entitlementState.plan;
    final nextPlans = EntitlementPlans.all
        .where(
          (candidate) => candidate.canAddActiveArtworks(
            currentActiveArtworkCount: currentActiveArtworkCount,
          ),
        )
        .where((candidate) => candidate.id != plan.id)
        .toList(growable: false);
    final suggestedPlan = nextPlans.isEmpty
        ? EntitlementPlans.archive
        : nextPlans.first;
    return _StatusPanel(
      icon: Icons.workspace_premium_outlined,
      title: '${plan.name} plan is at capacity',
      body:
          'You already have $currentActiveArtworkCount active artwork${currentActiveArtworkCount == 1 ? '' : 's'} in this plan. Existing records stay editable and exportable. ${suggestedPlan.name} plan preview includes ${_planArtworkLimitBenefitCopy(suggestedPlan)} and ${_planResearchDraftCopy(suggestedPlan)} at ${suggestedPlan.priceLabel}. ${_upgradePreviewCopy(entitlementState.billingStatus)}',
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
    final recordStateLabel = _recordStateLabel(record);

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(width: 10),
              _IconMedallion(icon: Icons.collections_bookmark_outlined),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _RecordStateBadge(label: recordStateLabel),
              _LifecycleBadge(status: lifecycleStatus),
            ],
          ),
          const SizedBox(height: 12),
          _PrimaryArtworkImagePreview(
            file: summary.primaryImageFile,
            isCompact: true,
          ),
          const SizedBox(height: 12),
          _StatusLine(
            icon: Icons.photo_library_outlined,
            text: record.primaryImageAttachmentId == null
                ? 'Add a primary image for this record.'
                : 'Primary image saved on this device.',
          ),
          _StatusLine(
            icon: Icons.attach_file,
            text: supportingCount == 0
                ? 'No supporting records added yet.'
                : '$supportingCount supporting record${supportingCount == 1 ? '' : 's'} added.',
          ),
          _StatusLine(
            icon: incompleteCount == 0
                ? Icons.check_circle_outline
                : Icons.rule_folder_outlined,
            text: incompleteCount == 0
                ? 'Nothing else needs review for this record.'
                : '$incompleteCount detail${incompleteCount == 1 ? '' : 's'} still ${incompleteCount == 1 ? 'needs' : 'need'} review.',
          ),
          if (lifecycleStatus != ArtworkLifecycleStatus.active)
            _StatusLine(
              icon: Icons.inventory_2_outlined,
              text:
                  'Marked ${lifecycleStatus.label.toLowerCase()}; kept in your record history.',
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
                  'Record status',
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
              'Could not update record status: $errorMessage',
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
      'This artwork counts as part of your current holdings.',
    ArtworkLifecycleStatus.sold =>
      'This record stays in your archive and is marked sold.',
    ArtworkLifecycleStatus.lost =>
      'This record stays in your archive and is marked lost.',
    ArtworkLifecycleStatus.stolen =>
      'This record stays in your archive and is marked stolen.',
    ArtworkLifecycleStatus.removed =>
      'This private record stays on this device and no longer counts as a current holding.',
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
    return attachments.where(_isSupportingRecordAttachment).length;
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
  const _CompletenessPanel({
    required this.fields,
    required this.recordStateLabel,
  });

  final List<PrototypeField> fields;
  final String recordStateLabel;

  @override
  Widget build(BuildContext context) {
    final reviewedCount = fields.where(_isReviewedPrototypeField).length;
    final totalCount = fields.length;
    final progress = totalCount == 0 ? 0.0 : reviewedCount / totalCount;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconMedallion(icon: Icons.fact_check_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Record review',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                '$reviewedCount/$totalCount',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(value: progress, minHeight: 8),
          ),
          const SizedBox(height: 10),
          Text(
            '$reviewedCount of $totalCount core fields are confirmed by you or supported by document review.',
          ),
          const SizedBox(height: 10),
          _StatusLine(
            icon: Icons.verified_user_outlined,
            text: 'Record state: $recordStateLabel',
          ),
          const _StatusLine(
            icon: Icons.inventory_2_outlined,
            text:
                'Supporting records can document provenance, condition, and location, but they stay separate from your confirmed fields.',
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
    final locale = Localizations.maybeLocaleOf(context) ?? const Locale('en');
    final reportDate = DateFormat.yMMMMd(
      locale.toLanguageTag(),
    ).format(DateTime.now());
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ReportDocumentHeader(),
          const SizedBox(height: 14),
          Text(
            artwork.title.value,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text('Report date: $reportDate'),
          const SizedBox(height: 8),
          const _StatusLine(
            icon: Icons.check_circle_outline,
            text: 'Confirmed fields are included.',
          ),
          _StatusLine(
            icon: Icons.attach_file,
            text: artwork.documents.isEmpty
                ? 'No supporting records are attached yet.'
                : '${artwork.documents.length} supporting record${artwork.documents.length == 1 ? '' : 's'} listed.',
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
    this.footer,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconMedallion(icon: icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(body),
                ...?(footer == null ? null : <Widget>[footer!]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportDocumentHeader extends StatelessWidget {
  const _ReportDocumentHeader();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.primary.withValues(alpha: .45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _IconMedallion(icon: Icons.picture_as_pdf_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Private art-record report',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconMedallion extends StatelessWidget {
  const _IconMedallion({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.primary.withValues(alpha: .35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 20, color: colorScheme.primary),
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

class _CollectionHomeData {
  const _CollectionHomeData({
    required this.records,
    required this.currentActiveArtworkCount,
    required this.entitlementState,
  });

  static const empty = _CollectionHomeData(
    records: [],
    currentActiveArtworkCount: 0,
    entitlementState: EntitlementState(plan: EntitlementPlans.free),
  );

  final List<_LocalArtworkSummary> records;
  final int currentActiveArtworkCount;
  final EntitlementState entitlementState;
}

class _CreationGate {
  const _CreationGate({
    required this.currentActiveArtworkCount,
    required this.entitlementState,
    this.requestedAdditionalArtworkCount = 1,
  });

  final int currentActiveArtworkCount;
  final EntitlementState entitlementState;
  final int requestedAdditionalArtworkCount;

  bool get canAddRequestedArtworkCount {
    return entitlementState.plan.canAddActiveArtworks(
      currentActiveArtworkCount: currentActiveArtworkCount,
      additionalArtworkCount: requestedAdditionalArtworkCount,
    );
  }
}

Future<_CollectionHomeData> _loadCollectionHomeData(
  AppDependencies dependencies,
) async {
  final records = await _loadLocalArtwork(dependencies);
  final activeArtworkCount = records
      .where(
        (summary) =>
            summary.record.lifecycleStatus == ArtworkLifecycleStatus.active,
      )
      .length;
  final entitlementState = await dependencies.entitlementService.currentState();
  return _CollectionHomeData(
    records: records,
    currentActiveArtworkCount: activeArtworkCount,
    entitlementState: entitlementState,
  );
}

Future<_CreationGate> _loadCreationGate(
  AppDependencies dependencies, {
  int requestedAdditionalArtworkCount = 1,
}) async {
  final records = await dependencies.artworkRepository.list();
  final activeArtworkCount = records
      .where(
        (record) => record.lifecycleStatus == ArtworkLifecycleStatus.active,
      )
      .length;
  final entitlementState = await dependencies.entitlementService.currentState();
  return _CreationGate(
    currentActiveArtworkCount: activeArtworkCount,
    entitlementState: entitlementState,
    requestedAdditionalArtworkCount: requestedAdditionalArtworkCount,
  );
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
              'This record stays in your archive, but it is not treated as an active artwork that needs review.',
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
      .where(_isSupportingRecordAttachment)
      .length;

  if (record.recordState != ArtworkRecordState.verifiedByYou ||
      reviewCount > 0) {
    items.add(
      _IncompleteItem(
        icon: Icons.rate_review_outlined,
        title: '$title needs review',
        body: reviewCount == 0
            ? 'Review this record before you rely on it in a report or export.'
            : '$reviewCount field${reviewCount == 1 ? '' : 's'} still need your confirmation before this record is ready for a report or export.',
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
            '$missingCount core field${missingCount == 1 ? '' : 's'} still need a value before this record feels complete.',
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
        title: '$title needs supporting records',
        body: supportingCount == 0
            ? 'Add a supporting photo, receipt, certificate, appraisal, auction record, or provenance note when available.'
            : '$supportingCount supporting record${supportingCount == 1 ? '' : 's'} added; review whether this artwork still needs more context.',
        actionLabel: 'Attach supporting records',
        routeName: AppRoutes.artworkDocuments(record.id),
      ),
    );
  }

  return items;
}

List<ArtworkFieldValue> _fieldsNeedingReview(ArtworkRecord record) {
  return _coreFieldKeys
      .map((key) => MapEntry(key, record.field(key)))
      .where((entry) {
        final field = entry.value;
        return field != null && !_isReviewedCoreField(field, key: entry.key);
      })
      .map((entry) => entry.value!)
      .toList(growable: false);
}

String _reviewSafeRoute(ArtworkRecord record) {
  if (record.lifecycleStatus != ArtworkLifecycleStatus.active) {
    return AppRoutes.artworkDetails(record.id);
  }

  if (_isVerifiedRecord(record)) {
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
            field?.source == ArtworkFieldSource.unknown ||
            _isPlaceholderCoreFieldValue(key, value);
      })
      .toList(growable: false);
}

String _planArtworkLimitCopy(EntitlementPlan plan) {
  final limit = plan.activeArtworkLimit;
  return limit == null
      ? 'Room for your full active collection'
      : 'Room for up to $limit active records';
}

String _planArtworkLimitBenefitCopy(EntitlementPlan plan) {
  final limit = plan.activeArtworkLimit;
  return limit == null
      ? 'room for your full active collection'
      : 'room for up to $limit active records';
}

String _planResearchDraftCopy(EntitlementPlan plan) {
  return '${plan.monthlyAiCredits} Archivale AI research draft${plan.monthlyAiCredits == 1 ? '' : 's'} each month';
}

String _upgradePreviewCopy(EntitlementBillingStatus billingStatus) {
  return switch (billingStatus) {
    EntitlementBillingStatus.available =>
      'Preview only in this build. In-app upgrades are not available yet.',
    EntitlementBillingStatus.unavailable =>
      'Preview only in this build. In-app upgrades are unavailable on this device right now.',
    EntitlementBillingStatus.notConfigured =>
      'Preview only in this build. In-app upgrades are not available in this preview yet.',
  };
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
    helperText: 'Record the title you use for this work.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.artist,
    label: 'Artist',
    helperText: 'Leave blank until the artist is confirmed.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.year,
    label: 'Year or date',
    helperText: 'Enter a year, range, or date you can support.',
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
    helperText: 'Legacy text is fine, or add amount and currency.',
    helperMaxLines: 2,
    usesStructuredMoney: true,
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.currentLocation,
    label: 'Current location',
    helperText:
        'Private location label for storage, display, or loan tracking.',
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.insuranceValue,
    label: 'User-provided insurance value',
    helperText:
        'User-provided only. Add an amount with a three-letter currency code when helpful.',
    keyboardType: TextInputType.text,
    helperMaxLines: 2,
    usesStructuredMoney: true,
  ),
  _EditableArtworkField(
    key: ArtworkFieldKeys.conditionNotes,
    label: 'Condition notes',
    helperText:
        'Record visible condition, damage, framing, or treatment notes.',
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
    this.helperMaxLines = 1,
    this.usesStructuredMoney = false,
  });

  final String key;
  final String label;
  final String helperText;
  final TextInputType keyboardType;
  final int maxLines;
  final int helperMaxLines;
  final bool usesStructuredMoney;
}

PrototypeField _detailDisplayField(PrototypeField field) {
  if (!_isPlaceholderPrototypeFieldValue(field.label, field.value)) {
    return field;
  }

  final guidanceValue = switch (field.label) {
    'Title' => 'Title pending review.',
    'Artist' => 'Artist not yet confirmed.',
    'Year' => 'Year pending review.',
    'Medium' => 'Medium pending review.',
    'Dimensions' => 'Dimensions pending review.',
    'Purchase price' => 'Purchase price not recorded.',
    'Current location' => 'Location pending review.',
    'User-provided insurance value' => 'Insurance value pending review.',
    'Condition notes' => 'Condition notes pending review.',
    _ => field.value,
  };

  return PrototypeField(
    label: field.label,
    value: guidanceValue,
    source: field.source,
    note: 'This detail still needs your review before you rely on it.',
  );
}

bool _hasCompleteReviewedCoreFields(Map<String, ArtworkFieldValue> fields) {
  return _coreFieldKeys.every((key) {
    final field = fields[key];
    return field != null && _isReviewedCoreField(field, key: key);
  });
}

bool _isVerifiedRecord(ArtworkRecord record) {
  return record.recordState == ArtworkRecordState.verifiedByYou &&
      _hasCompleteReviewedCoreFields(record.fields);
}

String _recordStateLabel(ArtworkRecord record) {
  if (_isVerifiedRecord(record)) {
    return ArtworkRecordState.verifiedByYou.label;
  }
  return record.recordState == ArtworkRecordState.verifiedByYou
      ? ArtworkRecordState.needsReview.label
      : record.recordState.label;
}

bool _isReviewedCoreField(ArtworkFieldValue field, {required String key}) {
  final value = field.value.trim();
  if (value.isEmpty || _isPlaceholderCoreFieldValue(key, value)) {
    return false;
  }
  return field.source == ArtworkFieldSource.userConfirmed ||
      field.source == ArtworkFieldSource.documentExtracted;
}

String _prototypeRecordStateLabel(List<PrototypeField> fields) {
  return fields.every(_isReviewedPrototypeField)
      ? ArtworkRecordState.verifiedByYou.label
      : ArtworkRecordState.needsReview.label;
}

bool _isReviewedPrototypeField(PrototypeField field) {
  final value = field.value.trim();
  if (value.isEmpty || _isPlaceholderPrototypeFieldValue(field.label, value)) {
    return false;
  }
  return field.source == PrototypeSource.userConfirmed ||
      field.source == PrototypeSource.documentExtracted;
}

bool _isPlaceholderCoreFieldValue(String key, String value) {
  final normalized = _normalizePlaceholderValue(value);
  return switch (key) {
    ArtworkFieldKeys.title => normalized == 'untitled artwork',
    ArtworkFieldKeys.artist => normalized == 'unknown',
    ArtworkFieldKeys.year =>
      normalized == 'unknown' || normalized == 'could not determine',
    ArtworkFieldKeys.medium ||
    ArtworkFieldKeys.dimensions ||
    ArtworkFieldKeys.currentLocation ||
    ArtworkFieldKeys.conditionNotes =>
      normalized == 'needs review' || normalized == 'unknown',
    ArtworkFieldKeys.purchasePrice => normalized == 'not set',
    ArtworkFieldKeys.insuranceValue =>
      normalized == 'not set' ||
          normalized == 'needs review' ||
          normalized == 'unknown',
    _ => false,
  };
}

bool _isPlaceholderPrototypeFieldValue(String label, String value) {
  final normalizedLabel = label.trim().toLowerCase();
  final key = switch (normalizedLabel) {
    'title' => ArtworkFieldKeys.title,
    'artist' => ArtworkFieldKeys.artist,
    'year' => ArtworkFieldKeys.year,
    'medium' => ArtworkFieldKeys.medium,
    'dimensions' => ArtworkFieldKeys.dimensions,
    'purchase price' => ArtworkFieldKeys.purchasePrice,
    'current location' => ArtworkFieldKeys.currentLocation,
    'user-provided insurance value' => ArtworkFieldKeys.insuranceValue,
    'condition notes' => ArtworkFieldKeys.conditionNotes,
    _ => '',
  };
  return key.isNotEmpty && _isPlaceholderCoreFieldValue(key, value);
}

String _normalizePlaceholderValue(String value) {
  return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
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
    artwork: _detailArtworkFromRecord(
      prototypeArtworkFromRecord(
        record,
        attachments: attachments,
        locale: locale,
      ),
    ),
    isAiDraftReview:
        aiDraftJobs.isNotEmpty &&
        aiDraftJobs.first.status == AiDraftJobStatus.completed,
    latestAiDraftJob: aiDraftJobs.isEmpty ? null : aiDraftJobs.first,
    latestResearchJob: researchJobs.isEmpty ? null : researchJobs.first,
  );
}

PrototypeArtwork _detailArtworkFromRecord(PrototypeArtwork artwork) {
  return PrototypeArtwork(
    id: artwork.id,
    title: _detailDisplayField(artwork.title),
    artist: _detailDisplayField(artwork.artist),
    year: _detailDisplayField(artwork.year),
    medium: _detailDisplayField(artwork.medium),
    dimensions: _detailDisplayField(artwork.dimensions),
    purchasePrice: _detailDisplayField(artwork.purchasePrice),
    location: _detailDisplayField(artwork.location),
    insuranceValue: _detailDisplayField(artwork.insuranceValue),
    condition: _detailDisplayField(artwork.condition),
    documents: artwork.documents,
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
        .where(_isSupportingRecordAttachment)
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
    throw StateError('Enter digits with an optional decimal amount.');
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
    throw StateError('Use a three-letter currency code such as USD.');
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

bool _isSupportingRecordAttachment(AttachmentRecord attachment) {
  return attachment.role == AttachmentRole.supportingPhoto ||
      attachment.role == AttachmentRole.supportingDocument;
}

PrototypeDocument _documentFromAttachment(AttachmentRecord attachment) {
  return PrototypeDocument(
    type: attachment.isSupportingPhoto
        ? 'Supporting photo'
        : _attachmentTypeLabel(attachment.type),
    fileName: attachment.fileName,
    source: _prototypeSource(attachment.source),
    note: attachment.notes ?? 'Saved with this artwork as a supporting record.',
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
        color: Theme.of(context).colorScheme.surface.withValues(alpha: .88),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

Color _panelColor(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  if (Theme.of(context).brightness == Brightness.dark) {
    return Color.alphaBlend(
      colors.primary.withValues(alpha: .06),
      colors.surface,
    );
  }
  return const Color(0xFFFFFCF6);
}

Color _nestedPanelColor(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  if (Theme.of(context).brightness == Brightness.dark) {
    return Color.alphaBlend(
      colors.secondary.withValues(alpha: .06),
      colors.surface,
    );
  }
  return const Color(0xFFF8F0E3);
}

List<BoxShadow> _panelShadow(BuildContext context) {
  if (Theme.of(context).brightness == Brightness.dark) {
    return const [];
  }
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: .05),
      offset: const Offset(0, 10),
      blurRadius: 28,
    ),
  ];
}

typedef _ArtworkHeroColors = ({
  Color background,
  Color border,
  Color wall,
  Color mat,
  Color artwork,
  Color inner,
  Color accent,
  Color frame,
  Color frameLine,
});

_ArtworkHeroColors _artworkHeroColors(BuildContext context) {
  if (Theme.of(context).brightness == Brightness.dark) {
    return const (
      background: Color(0xFF151B18),
      border: Color(0xFF66563B),
      wall: Color(0xFF151B18),
      mat: Color(0xFFE6DCC8),
      artwork: Color(0xFF1E3E39),
      inner: Color(0xFF8B5E46),
      accent: Color(0xFFD9BE78),
      frame: Color(0xFF6C5630),
      frameLine: Color(0xFFEAD7A6),
    );
  }

  return const (
    background: Color(0xFFF0E5D3),
    border: Color(0xFFC8A15A),
    wall: Color(0xFFF0E5D3),
    mat: Color(0xFFFFFAEF),
    artwork: Color(0xFF24466F),
    inner: Color(0xFF1D6A5E),
    accent: Color(0xFFD9B66F),
    frame: Color(0xFF57432C),
    frameLine: Color(0xFFECD7A4),
  );
}
