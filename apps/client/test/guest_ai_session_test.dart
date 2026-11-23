import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/guest_credential_store.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';

void main() {
  test(
    'anonymous credential survives restart; session stays in memory and no phone login occurs',
    () async {
      final root = await Directory.systemTemp.createTemp('guest-session-');
      addTearDown(() => root.delete(recursive: true));
      final api = _GuestApi();
      RemoteAccountService open() => RemoteAccountService(
        gatewayApi: api,
        guestCredentialStore: GuestCredentialStore(
          rootDirectory: () async => root,
        ),
      );
      final first = open();
      await first.startGuest();
      expect(first.snapshot.isGuest, isTrue);
      expect(first.snapshot.privileges, isNull);
      expect(first.snapshot.maskedPhone, isNull);
      expect(
        first.snapshot.accessByCapability.values.every(
          (e) => e.monthlyLimit == 1,
        ),
        isTrue,
      );
      await expectLater(
        first.createRecoveryCode('Test123'),
        throwsA(isA<RemoteAccountInputException>()),
      );
      final owner = first.accountId;
      first.signOutLocally();
      expect(first.snapshot.isGuest, isFalse);
      final restarted = open();
      expect(restarted.snapshot.isSignedIn, isFalse);
      await restarted.startGuest();
      expect(restarted.accountId, owner);
      expect(api.credentials, hasLength(2));
      expect(api.credentials.first, api.credentials.last);
      expect(api.phoneLogins, 0);
      expect(api.privilegeCalls, 0);
      final file = File('${root.path}/guest_installation_v1.key');
      expect(await file.readAsString(), api.credentials.first);
    },
  );

  test(
    'concurrent reads share one credential, corrupt data fails closed, explicit wipe removes it',
    () async {
      final root = await Directory.systemTemp.createTemp('guest-credential-');
      addTearDown(() => root.delete(recursive: true));
      final store = GuestCredentialStore(rootDirectory: () async => root);
      final credentials = await Future.wait(
        List.generate(4, (_) => store.getOrCreate()),
      );
      expect(credentials.toSet(), hasLength(1));
      final file = File('${root.path}/guest_installation_v1.key');
      await file.writeAsString('damaged');
      final reopened = GuestCredentialStore(rootDirectory: () async => root);
      await expectLater(reopened.getOrCreate(), throwsFormatException);
      expect(await file.readAsString(), 'damaged');
      await reopened.clear();
      expect(await file.exists(), isFalse);
      expect(await reopened.getOrCreate(), isNot(credentials.first));
    },
  );
}

final class _GuestApi
    implements GatewayApi, GatewayGuestApi, GatewayPrivilegesApi {
  final credentials = <String>[];
  int phoneLogins = 0;
  int privilegeCalls = 0;
  @override
  Future<GatewayGuestSession> createGuestSession(
    String installationSecret,
  ) async {
    credentials.add(installationSecret);
    return GatewayGuestSession(
      guestId: 'guest-synthetic',
      session: GatewaySession(
        token: 'guest-memory-session',
        expiresAtUtc: DateTime.utc(2030),
      ),
    );
  }

  @override
  Future<GatewayAccountPrivileges?> readPrivileges({
    required String sessionToken,
  }) async {
    privilegeCalls++;
    throw StateError('Guests must not request account entitlements');
  }

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async => GatewayAccessSnapshot(
    capability: capability,
    plan: GatewaySubscriptionPlan.free,
    allowed: true,
    reason: 'allowed',
    remainingMonthlyBasicGenerations:
        capability == RemoteAiCapability.basicResumeCompose ? 1 : null,
    monthlyLimit: 1,
    remainingMonthlyGenerations: 1,
  );
  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async {
    phoneLogins++;
    throw StateError('No phone login');
  }

  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async => throw StateError('No fake identity');
  @override
  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  }) async => throw UnimplementedError();
  @override
  void close() {}
}
