import 'package:drift_flutter/drift_flutter.dart';
import 'package:entitlements/entitlements.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_storage/local_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/legal_consent_controller.dart';
import 'src/legal_consent_repository.dart';
import 'src/legal_gateway_transport.dart';
import 'src/local_agent_composition.dart';
import 'src/local_data_management_service.dart';
import 'src/gateway_api_client.dart';
import 'src/remote_operation_journal.dart';
import 'src/remote_task_draft_store.dart';
import 'src/guest_credential_store.dart';
import 'src/resume_file_exporter.dart';
import 'src/resume_import_file_picker.dart';

export 'src/app.dart' show ResumeAllInOneApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledFontLicense();

  final database = LocalStorageDatabase(
    driftDatabase(name: 'resume_all_in_one'),
  );
  final resumeRepository = DriftResumeRepository(database);
  final legalConsent = LegalConsentController(
    repository: FileLegalConsentRepository(
      rootDirectory: getApplicationSupportDirectory,
    ),
  );
  runApp(
    ResumeAllInOneApp(
      legalConsentController: legalConsent,
      repository: resumeRepository,
      settingsRepository: DriftAppSettingsRepository(database),
      localAgentCheckService: createOfflineLocalAgentCheckService(
        resumeRepository: resumeRepository,
        auditRepository: DriftAgentAuditRepository(database),
      ),
      localDataManagementService: LocalDataManagementService(
        repository: DriftLocalDataRepository(database),
        rootDirectory: getApplicationDocumentsDirectory,
      ),
      accessPolicy: CapabilityAccessPolicy.mvp(),
      fileExporter: ResumeFileExporter(
        rootDirectory: getApplicationDocumentsDirectory,
      ),
      importFilePicker: const SystemResumeImportFilePicker(),
      gatewayApi: _createConfiguredGatewayApi(legalConsent),
      operationJournal: RemoteOperationJournal(
        rootDirectory: getApplicationSupportDirectory,
      ),
      guestCredentialStore: GuestCredentialStore(
        rootDirectory: getApplicationSupportDirectory,
      ),
      taskDraftStore: RemoteTaskDraftStore(
        rootDirectory: getApplicationSupportDirectory,
      ),
      reviewRepository: DriftRemoteReviewRepository(database),
      databaseToClose: database,
    ),
  );
}

/// 字体随 PDF 功能打包，完整许可与版权告知也通过 Flutter 的许可页提供。
void registerBundledFontLicense() {
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString(
      'packages/document_io/assets/fonts/OFL-1.1.txt',
    );
    yield LicenseEntryWithLineBreaks(const ['Noto Sans SC'], license);
  });
}

GatewayApi? _createConfiguredGatewayApi(LegalConsentController legalConsent) {
  const gatewayBaseUrl = String.fromEnvironment('AGENT_GATEWAY_BASE_URL');
  if (gatewayBaseUrl.trim().isEmpty) {
    return null;
  }
  try {
    return GatewayApiClient(
      baseUri: Uri.parse(gatewayBaseUrl),
      transport: LegalGatewayHttpTransport(
        transport: DartIoGatewayHttpTransport(),
        legalConsent: legalConsent,
      ),
      originalResultRecoveryEnabled: true,
      // Android 模拟器调试本地 Gateway 时允许 HTTP；release 仍强制 HTTPS。
      allowInsecureHttp: kDebugMode,
    );
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}
