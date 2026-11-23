import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/remote_task_draft_store.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17);
  RemoteTaskDraft draft(String owner, String id) => RemoteTaskDraft(
    owner: owner,
    id: id,
    kind: 'compose',
    createdAtUtc: now,
    expiresAtUtc: now.add(const Duration(days: 7)),
    material: const {'sourceText': '合成材料：参与学校页面练习'},
    submittedPersonalDataShared: true,
  );
  test(
    'task survives restart, stays owner isolated and expires without extending',
    () async {
      final root = await Directory.systemTemp.createTemp('resume-task-draft-');
      addTearDown(() => root.delete(recursive: true));
      final store = RemoteTaskDraftStore(
        rootDirectory: () async => root,
        clock: () => now,
      );
      await store.save(draft('owner-a', 'task-a'));
      final restored = RemoteTaskDraftStore(
        rootDirectory: () async => root,
        clock: () => now,
      );
      expect(
        (await restored.read('owner-a')).single.material['sourceText'],
        contains('学校'),
      );
      expect(await restored.read('owner-b'), isEmpty);
      final expired = RemoteTaskDraftStore(
        rootDirectory: () async => root,
        clock: () => now.add(const Duration(days: 7)),
      );
      expect(await expired.read('owner-a'), isEmpty);
      final encoded = (await restored.read('owner-a')).single.toJson();
      expect(encoded.containsKey('confirmedInputSharing'), isFalse);
      expect(encoded.containsKey('sessionToken'), isFalse);
    },
  );
  test(
    'concurrent saves preserve independent tasks and removal is owner bound',
    () async {
      final store = RemoteTaskDraftStore(clock: () => now);
      await Future.wait([
        for (var i = 0; i < 10; i++) store.save(draft('a', 'task-$i')),
      ]);
      await store.remove('b', 'task-0');
      expect(await store.read('a'), hasLength(10));
      await store.remove('a', 'task-0');
      expect(await store.read('a'), hasLength(9));
    },
  );
  test(
    'expiry removes material on read and clear also replaces corrupt storage',
    () async {
      final root = await Directory.systemTemp.createTemp('task-retirement-');
      addTearDown(() => root.delete(recursive: true));
      var clock = now;
      final store = RemoteTaskDraftStore(
        rootDirectory: () async => root,
        clock: () => clock,
      );
      await store.save(draft('a', 'task'));
      clock = now.add(const Duration(days: 7));
      expect(await store.read('a'), isEmpty);
      final file = File('${root.path}/ai_task_drafts_v1.json');
      expect(await file.readAsString(), isNot(contains('合成材料')));
      await file.writeAsString('{corrupt');
      final reopened = RemoteTaskDraftStore(rootDirectory: () async => root);
      await reopened.clear();
      expect(await reopened.read('a'), isEmpty);
      expect(await file.readAsString(), contains('"tasks":[]'));
    },
  );
  test('credentials and sending consent cannot be task material fields', () {
    for (final key in ['password', 'sessionToken', 'confirmedInputSharing']) {
      expect(
        () => RemoteTaskDraft(
          owner: 'a',
          id: 'x',
          kind: 'compose',
          createdAtUtc: now,
          expiresAtUtc: now.add(const Duration(days: 1)),
          material: {key: 'not-a-secret-test-value'},
        ),
        throwsFormatException,
      );
    }
  });
}
