import 'dart:convert';

import 'package:crypto/crypto.dart';

const gatewayCloudProtocolVersion = '0.1.0';

/// 政策信息不等于同意；首次上传仍须逐文档确认准确指纹。
final class CloudSyncPolicy {
  const CloudSyncPolicy._({
    required this.policyVersion,
    required this.region,
    required this.contentRetentionDays,
    required this.backupRetentionDays,
    required this.resourceIdentity,
  });

  final String policyVersion;
  final String region;
  final int contentRetentionDays;
  final int backupRetentionDays;
  final String resourceIdentity;

  factory CloudSyncPolicy.fromJson(Map<String, Object?> value) {
    _keys(value, const {
      'policyVersion',
      'region',
      'contentRetentionDays',
      'backupRetentionDays',
      'resourceIdentity',
    });
    return CloudSyncPolicy._(
      policyVersion: _label(value['policyVersion']),
      region: _label(value['region']),
      resourceIdentity: _label(value['resourceIdentity']),
      contentRetentionDays: _integer(value['contentRetentionDays'], 0, 3650),
      backupRetentionDays: _integer(value['backupRetentionDays'], 0, 3650),
    );
  }

  String get fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            // 与服务端 sorted keys 的紧凑 UTF-8 JSON 完全相同。
            'backupRetentionDays': backupRetentionDays,
            'contentRetentionDays': contentRetentionDays,
            'policyVersion': policyVersion,
            'region': region,
            'resourceIdentity': resourceIdentity,
            'scope': 'canonicalDocument',
          }),
        ),
      )
      .toString();
}

final class CloudSyncOptions {
  const CloudSyncOptions._({
    required this.enabled,
    required this.policy,
    required this.policyFingerprint,
    required this.maximumSnapshotBytes,
    required this.maximumRequestBytes,
    required this.maximumResponseBytes,
    required this.maximumPageSize,
    required this.cursorLifetimeSeconds,
  });

  final bool enabled;
  final CloudSyncPolicy? policy;
  final String? policyFingerprint;
  final int maximumSnapshotBytes;
  final int maximumRequestBytes;
  final int maximumResponseBytes;
  final int maximumPageSize;
  final int cursorLifetimeSeconds;

  factory CloudSyncOptions.fromJson(Map<String, Object?> value) {
    _keys(value, const {
      'protocolVersion',
      'enabled',
      'developmentOnly',
      'scope',
      'policy',
      'policyFingerprint',
      'maximumSnapshotBytes',
      'maximumRequestBytes',
      'maximumResponseBytes',
      'maximumPageSize',
      'cursorLifetimeSeconds',
    });
    if (value['protocolVersion'] != gatewayCloudProtocolVersion ||
        value['developmentOnly'] != true ||
        value['scope'] != 'canonicalDocument' ||
        value['enabled'] is! bool) {
      throw const FormatException('Invalid cloud options');
    }
    final enabled = value['enabled']! as bool;
    final rawPolicy = value['policy'];
    final fingerprint = value['policyFingerprint'];
    CloudSyncPolicy? policy;
    if (enabled) {
      if (rawPolicy is! Map<String, Object?> || fingerprint is! String) {
        throw const FormatException('Missing cloud policy');
      }
      policy = CloudSyncPolicy.fromJson(rawPolicy);
      if (fingerprint != policy.fingerprint) {
        throw const FormatException('Cloud policy fingerprint mismatch');
      }
    } else if (rawPolicy != null || fingerprint != null) {
      throw const FormatException('Disabled cloud has a policy');
    }
    final requestBytes = _integer(value['maximumRequestBytes'], 1, 65536);
    final snapshotBytes = _integer(value['maximumSnapshotBytes'], 1, 49152);
    if (snapshotBytes > requestBytes) {
      throw const FormatException('Invalid cloud limits');
    }
    return CloudSyncOptions._(
      enabled: enabled,
      policy: policy,
      policyFingerprint: fingerprint as String?,
      maximumSnapshotBytes: snapshotBytes,
      maximumRequestBytes: requestBytes,
      maximumResponseBytes: _integer(value['maximumResponseBytes'], 1, 65536),
      maximumPageSize: _integer(value['maximumPageSize'], 1, 50),
      cursorLifetimeSeconds: _integer(value['cursorLifetimeSeconds'], 1, 900),
    );
  }
}

abstract interface class GatewayCloudApi {
  Future<CloudSyncOptions> readCloudOptions();
}

void _keys(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    throw const FormatException('Invalid cloud fields');
  }
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('Invalid cloud integer');
  }
  return value;
}

String _label(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$').hasMatch(value) ||
      value.length > 64 ||
      value.contains('\n')) {
    throw const FormatException('Invalid cloud label');
  }
  return value;
}
