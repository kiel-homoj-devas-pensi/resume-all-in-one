import 'dart:async';

import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:path_provider/path_provider.dart';

import 'app_theme.dart';
import 'app_theme_controller.dart';
import 'legal_consent_controller.dart';
import 'legal_consent_repository.dart';
import 'legal_consent_pages.dart';
import 'local_agent_check_service.dart';
import 'local_data_management_service.dart';
import 'local_resume_suggestion_service.dart';
import 'gateway_api_client.dart';
import 'remote_account_service.dart';
import 'remote_operation_journal.dart';
import 'remote_task_draft_store.dart';
import 'guest_credential_store.dart';
import 'remote_resume_ai_service.dart';
import 'resume_file_exporter.dart';
import 'resume_home_page.dart';
import 'resume_import_file_picker.dart';
import 'resume_workspace_controller.dart';

final class ResumeAllInOneApp extends StatefulWidget {
  const ResumeAllInOneApp({
    super.key,
    required this.repository,
    required this.settingsRepository,
    required this.localAgentCheckService,
    this.localResumeSuggestionService,
    required this.localDataManagementService,
    required this.accessPolicy,
    required this.fileExporter,
    required this.importFilePicker,
    this.gatewayApi,
    this.databaseToClose,
    this.operationJournal,
    this.reviewRepository,
    this.taskDraftStore,
    this.guestCredentialStore,
    this.legalConsentController,
  });

  final ResumeRepository repository;
  final DriftAppSettingsRepository settingsRepository;
  final LocalAgentCheckService localAgentCheckService;
  final LocalResumeSuggestionService? localResumeSuggestionService;
  final LocalDataManagementService localDataManagementService;
  final CapabilityAccessPolicy accessPolicy;
  final ResumeFileExporter fileExporter;
  final ResumeImportFilePicker importFilePicker;
  final GatewayApi? gatewayApi;
  final LocalStorageDatabase? databaseToClose;
  final RemoteOperationJournal? operationJournal;
  final DriftRemoteReviewRepository? reviewRepository;
  final RemoteTaskDraftStore? taskDraftStore;
  final GuestCredentialStore? guestCredentialStore;

  /// The app owns this controller, including an explicitly supplied instance.
  final LegalConsentController? legalConsentController;

  @override
  State<ResumeAllInOneApp> createState() => _ResumeAllInOneAppState();
}

final class _ResumeAllInOneAppState extends State<ResumeAllInOneApp> {
  late final ResumeWorkspaceController _controller;
  late final AppThemeController _themeController;
  late final LegalConsentController _legalConsent;
  bool _startupResolved = false;
  bool _introductionComplete = false;

  @override
  void initState() {
    super.initState();
    _legalConsent =
        widget.legalConsentController ??
        LegalConsentController(
          repository: FileLegalConsentRepository(
            rootDirectory: getApplicationSupportDirectory,
          ),
        );
    unawaited(_initializeLegalConsent());
    _themeController = AppThemeController(
      settingsRepository: widget.settingsRepository,
    );
    unawaited(_themeController.initialize());
    final remoteAccountService = RemoteAccountService(
      gatewayApi: widget.gatewayApi,
      operationJournal: widget.operationJournal,
      guestCredentialStore: widget.guestCredentialStore,
    );
    _controller = ResumeWorkspaceController(
      legalConsent: _legalConsent,
      repository: widget.repository,
      settingsRepository: widget.settingsRepository,
      localAgentCheckService: widget.localAgentCheckService,
      localResumeSuggestionService: widget.localResumeSuggestionService,
      localDataManagementService: widget.localDataManagementService,
      accessPolicy: widget.accessPolicy,
      fileExporter: widget.fileExporter,
      importFilePicker: widget.importFilePicker,
      remoteAccountService: remoteAccountService,
      remoteResumeAiService: RemoteResumeAiService(
        accountService: remoteAccountService,
        reviewRepository: widget.reviewRepository,
        taskDraftStore: widget.taskDraftStore,
      ),
      reviewRepository: widget.reviewRepository,
    );
    _legalConsent.bindNetworkPreference(() => _controller.networkEnabled);
  }

  Future<void> _initializeLegalConsent() async {
    await _legalConsent.initialize();
    if (!mounted) return;
    setState(() {
      _startupResolved = true;
      _introductionComplete = !_legalConsent.needsIntroduction;
    });
  }

  @override
  void dispose() {
    _themeController.dispose();
    _controller.dispose();
    _legalConsent.dispose();
    final database = widget.databaseToClose;
    if (database != null) {
      unawaited(database.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppThemeScope(
      controller: _themeController,
      child: ListenableBuilder(
        listenable: _themeController,
        builder: (context, child) => MaterialApp(
          title: '简历全能帮',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: _themeController.mode,
          themeAnimationDuration: const Duration(milliseconds: 220),
          themeAnimationCurve: Curves.easeOutCubic,
          home: !_startupResolved
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : !_introductionComplete
              ? Stack(
                  children: [
                    Scaffold(appBar: AppBar(title: const Text('简历全能帮'))),
                    const ModalBarrier(
                      dismissible: false,
                      color: Colors.black54,
                    ),
                    LegalConsentIntroduction(
                      controller: _legalConsent,
                      onContinue: () async {
                        if (_legalConsent.canUseRemoteServices) {
                          await _controller.setNetworkEnabled(true);
                        }
                        if (mounted) {
                          setState(() => _introductionComplete = true);
                        }
                      },
                    ),
                  ],
                )
              : child,
        ),
        child: ResumeHomePage(controller: _controller),
      ),
    );
  }
}
