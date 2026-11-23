import 'package:resume_all_in_one_client/src/cloud_sync_contracts.dart';

Map<String, Object?> syntheticCloudOptions({bool enabled = true}) {
  final policy = <String, Object?>{
    'policyVersion': 'synthetic-v1',
    'region': 'local-synthetic',
    'contentRetentionDays': 7,
    'backupRetentionDays': 30,
    'resourceIdentity': 'synthetic-fixture',
  };
  return {
    'protocolVersion': '0.1.0',
    'enabled': enabled,
    'developmentOnly': true,
    'scope': 'canonicalDocument',
    'policy': enabled ? policy : null,
    'policyFingerprint': enabled
        ? CloudSyncPolicy.fromJson(policy).fingerprint
        : null,
    'maximumSnapshotBytes': 49152,
    'maximumRequestBytes': 65536,
    'maximumResponseBytes': 65536,
    'maximumPageSize': 50,
    'cursorLifetimeSeconds': 900,
  };
}
