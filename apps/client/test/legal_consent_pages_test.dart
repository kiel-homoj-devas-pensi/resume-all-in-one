import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/app_theme.dart';
import 'package:resume_all_in_one_client/src/legal_consent_controller.dart';
import 'package:resume_all_in_one_client/src/legal_consent_pages.dart';
import 'package:resume_all_in_one_client/src/legal_consent_repository.dart';
import 'package:resume_all_in_one_client/src/legal_documents.dart';

void main() {
  testWidgets('主动联网后再次拒绝保留不再提醒，只有主动取消才恢复启动提示', (tester) async {
    final repository = _MemoryLegalRepository();
    final first = await _controller(repository);
    await first.continueLocally(suppressReminder: true);
    await _intro(tester, first, () {});
    await _reveal(tester, find.byKey(const Key('不再提醒当前版本')));
    expect(_checkbox(tester, '不再提醒当前版本').value, isTrue);
    await _reveal(tester, find.byKey(const Key('仅使用本地功能')));
    await tester.tap(find.byKey(const Key('仅使用本地功能')));
    await tester.pumpAndSettle();
    expect(repository.entries.last.record.suppressReminder, isTrue);
    final restarted = await _controller(repository);
    expect(restarted.needsIntroduction, isFalse);
    expect(restarted.canSendNetworkRequest, isFalse);
    await _intro(tester, restarted, () {});
    await _reveal(tester, find.byKey(const Key('不再提醒当前版本')));
    await tester.tap(find.byKey(const Key('不再提醒当前版本')));
    await _reveal(tester, find.byKey(const Key('仅使用本地功能')));
    await tester.tap(find.byKey(const Key('仅使用本地功能')));
    await tester.pumpAndSettle();
    expect(repository.entries.last.record.suppressReminder, isFalse);
    final optedIn = await _controller(repository);
    expect(optedIn.needsIntroduction, isTrue);
    expect(optedIn.canSendNetworkRequest, isFalse);
    first.dispose();
    restarted.dispose();
    optedIn.dispose();
  });
  testWidgets('单次发送界面可离线打开同一隐私政策，阅读不产生同意记录', (tester) async {
    final repository = _MemoryLegalRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showBundledPrivacyPolicy(context),
              child: const Text('查看接收方政策'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看接收方政策'));
    await tester.pumpAndSettle();
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.text('版本：1.10'), findsOneWidget);
    expect(find.text('已定稿；当前使用规则随主动同意适用'), findsOneWidget);
    expect(find.textContaining('计划公开生效：2027-01-01'), findsOneWidget);
    expect(repository.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('首次弹窗正文默认折叠，展开阅读不产生同意', (tester) async {
    final controller = await _controller(_MemoryLegalRepository());
    await _intro(tester, controller, () {});
    expect(find.byKey(const Key('首次使用协议弹窗')), findsOneWidget);
    expect(find.textContaining('1.0用户协议正文'), findsNothing);
    expect(controller.hasOpenedDocument('terms'), isFalse);
    await _reveal(tester, find.byKey(const Key('阅读terms')));
    await tester.tap(find.byKey(const Key('阅读terms')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1.0用户协议正文'), findsOneWidget);
    expect(controller.hasOpenedDocument('terms'), isTrue);
    expect(controller.records, isEmpty);
    expect(controller.canUseRemoteServices, isFalse);
    controller.dispose();
  });

  testWidgets('阅读不代替同意，双文档和双勾选后可明确同意', (tester) async {
    final repository = _MemoryLegalRepository();
    final controller = await _controller(repository);
    var continued = false;
    await _intro(tester, controller, () => continued = true);

    await _reveal(tester, find.byKey(const Key('同意并继续')));
    expect(_acceptButton(tester).onPressed, isNull);
    expect(controller.records, isEmpty);
    await _readCurrentDocuments(tester);
    expect(controller.records, isEmpty);

    await _reveal(tester, find.byKey(const Key('同意用户协议')));
    expect(_checkbox(tester, '同意用户协议').value, isFalse);
    await tester.tap(find.byKey(const Key('同意用户协议')));
    await tester.pump();
    await _reveal(tester, find.byKey(const Key('同意隐私政策')));
    expect(_checkbox(tester, '同意隐私政策').value, isFalse);
    await tester.tap(find.byKey(const Key('同意隐私政策')));
    await tester.pump();
    await _reveal(tester, find.byKey(const Key('同意并继续')));
    expect(_acceptButton(tester).onPressed, isNull);
    await _reveal(tester, find.byKey(const Key('确认已满18周岁')));
    expect(_checkbox(tester, '确认已满18周岁').value, isFalse);
    await tester.tap(find.byKey(const Key('确认已满18周岁')));
    await tester.pump();
    await _reveal(tester, find.byKey(const Key('同意并继续')));
    expect(_acceptButton(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('同意并继续')));
    await tester.pumpAndSettle();

    expect(continued, isTrue);
    expect(controller.canUseRemoteServices, isTrue);
    expect(controller.needsIntroduction, isFalse);
    expect(controller.records.single.action, LegalConsentAction.accepted);
    expect(controller.records.single.adultConfirmed, isTrue);
    controller.dispose();
  });

  testWidgets('草案不可同意，不再提醒与本地选择独立且持久化', (tester) async {
    final repository = _MemoryLegalRepository();
    final draft = _bundle(published: false);
    final controller = await _controller(repository, bundle: draft);
    var continued = false;
    await _intro(tester, controller, () => continued = true);

    await _reveal(tester, find.byKey(const Key('同意用户协议')));
    expect(_checkbox(tester, '同意用户协议').onChanged, isNull);
    await _reveal(tester, find.byKey(const Key('同意并继续')));
    expect(_acceptButton(tester).onPressed, isNull);
    await _reveal(tester, find.byKey(const Key('不再提醒当前版本')));
    expect(_checkbox(tester, '不再提醒当前版本').value, isFalse);
    await tester.tap(find.byKey(const Key('不再提醒当前版本')));
    await tester.pump();
    expect(controller.records, isEmpty);
    expect(controller.canUseRemoteServices, isFalse);
    await _reveal(tester, find.byKey(const Key('仅使用本地功能')));
    await tester.tap(find.byKey(const Key('仅使用本地功能')));
    await tester.pumpAndSettle();

    expect(continued, isTrue);
    expect(controller.canUseRemoteServices, isFalse);
    expect(controller.records.single.action, LegalConsentAction.localOnly);
    expect(controller.records.single.adultConfirmed, isFalse);
    expect(controller.records.single.suppressReminder, isTrue);
    expect(controller.needsIntroduction, isFalse);
    final reloaded = await _controller(repository, bundle: draft);
    expect(reloaded.needsIntroduction, isFalse);
    expect(reloaded.canUseRemoteServices, isFalse);
    reloaded.dispose();
    controller.dispose();
  });

  testWidgets('本地选择未勾不再提醒时保留下一次提醒', (tester) async {
    final repository = _MemoryLegalRepository();
    final controller = await _controller(repository);
    await _intro(tester, controller, () {});
    await _reveal(tester, find.byKey(const Key('仅使用本地功能')));
    await tester.tap(find.byKey(const Key('仅使用本地功能')));
    await tester.pumpAndSettle();
    expect(controller.records.single.suppressReminder, isFalse);
    final nextLaunch = await _controller(repository);
    expect(nextLaunch.needsIntroduction, isTrue);
    nextLaunch.dispose();
    expect(controller.canUseRemoteServices, isFalse);
    controller.dispose();
  });

  testWidgets('草案待填信息集中展开查看，不遮挡文档入口', (tester) async {
    final controller = await _controller(
      _MemoryLegalRepository(),
      bundle: _bundle(published: false),
    );
    await _intro(tester, controller, () {});
    expect(find.text('待填写信息（1项）'), findsOneWidget);
    expect(find.text('服务提供者：________（待补充；待负责人核实）'), findsNothing);
    await tester.tap(find.byKey(const Key('查看待填写信息')));
    await tester.pumpAndSettle();
    expect(find.text('服务提供者：________（待补充；待负责人核实）'), findsOneWidget);
    await _reveal(tester, find.byKey(const Key('阅读terms')));
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('保存同意失败不会继续，明确选择仍保留供重试', (tester) async {
    final repository = _MemoryLegalRepository()..failAppend = true;
    final controller = await _controller(repository);
    var continued = false;
    await _intro(tester, controller, () => continued = true);
    await _readCurrentDocuments(tester);
    for (final key in ['同意用户协议', '同意隐私政策', '确认已满18周岁']) {
      await _reveal(tester, find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
    }
    await _reveal(tester, find.byKey(const Key('同意并继续')));
    await tester.tap(find.byKey(const Key('同意并继续')));
    await tester.pumpAndSettle();
    expect(continued, isFalse);
    expect(controller.canUseRemoteServices, isFalse);
    expect(controller.errorMessage, isNotNull);
    await _reveal(tester, find.byKey(const Key('同意用户协议')));
    expect(_checkbox(tester, '同意用户协议').value, isTrue);
    await _reveal(tester, find.byKey(const Key('同意隐私政策')));
    expect(_checkbox(tester, '同意隐私政策').value, isTrue);
    controller.dispose();
  });

  testWidgets('中心可复制离线全文，阅读旧快照不会用当前文档替代', (tester) async {
    final repository = _MemoryLegalRepository();
    final old = await _controller(repository, bundle: _bundle(version: '旧版'));
    old.markDocumentOpened('terms');
    old.markDocumentOpened('privacy');
    expect(
      await old.accept(
        adultConfirmed: true,
        termsChecked: true,
        privacyChecked: true,
      ),
      isTrue,
    );
    old.dispose();
    final controller = await _controller(
      repository,
      bundle: _bundle(version: '新版'),
    );
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await _center(tester, controller);
    final oldTerms = find.text('阅读记录中的用户协议（旧版）');
    await _reveal(tester, oldTerms);
    await tester.tap(oldTerms);
    await tester.pumpAndSettle();
    expect(find.textContaining('版本：旧版'), findsOneWidget);
    expect(clipboard, isNull);
    await _reveal(tester, find.byKey(const Key('复制文档全文')));
    await tester.tap(find.byKey(const Key('复制文档全文')));
    await tester.pumpAndSettle();
    expect(clipboard, contains('旧版用户协议正文'));
    expect(clipboard, isNot(contains('新版用户协议正文')));
    expect(controller.records, hasLength(1));
    expect(controller.canUseRemoteServices, isFalse);
    controller.dispose();
  });

  testWidgets('撤回先说明数据影响，取消不撤回，确认后停止联网', (tester) async {
    final controller = await _controller(_MemoryLegalRepository());
    controller.markDocumentOpened('terms');
    controller.markDocumentOpened('privacy');
    await controller.accept(
      adultConfirmed: true,
      termsChecked: true,
      privacyChecked: true,
    );
    await _center(tester, controller);
    await _reveal(tester, find.byKey(const Key('撤回协议同意')));
    await tester.tap(find.byKey(const Key('撤回协议同意')));
    await tester.pumpAndSettle();
    expect(find.textContaining('本地简历、历史版本和已导出的文件不会因此被删除'), findsOneWidget);
    expect(find.textContaining('不能撤销已经发送的请求'), findsOneWidget);
    await tester.tap(find.text('保留同意'));
    await tester.pumpAndSettle();
    expect(controller.canUseRemoteServices, isTrue);
    await tester.tap(find.byKey(const Key('撤回协议同意')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('确认撤回同意')));
    await tester.pumpAndSettle();
    expect(controller.canUseRemoteServices, isFalse);
    expect(controller.records.last.action, LegalConsentAction.withdrawn);
    controller.dispose();
  });

  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    for (final dark in [false, true]) {
      testWidgets('协议页 ${size.width}×${size.height} 双倍字体 dark=$dark 可读并本地继续', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = await _controller(
          _MemoryLegalRepository(),
          bundle: _bundle(published: false),
        );
        var continued = false;
        await _intro(
          tester,
          controller,
          () => continued = true,
          dark: dark,
          scale: 2,
        );
        await _readCurrentDocuments(tester);
        await _reveal(tester, find.byKey(const Key('不再提醒当前版本')));
        await tester.tap(find.byKey(const Key('不再提醒当前版本')));
        await tester.pump();
        await _reveal(tester, find.byKey(const Key('仅使用本地功能')));
        await tester.tap(find.byKey(const Key('仅使用本地功能')));
        await tester.pumpAndSettle();
        expect(continued, isTrue);
        expect(tester.takeException(), isNull);
        controller.dispose();
      });
    }
  }
}

Future<void> _intro(
  WidgetTester tester,
  LegalConsentController controller,
  VoidCallback onContinue, {
  bool dark = false,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark : AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: LegalConsentIntroduction(
        controller: controller,
        onContinue: onContinue,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _center(
  WidgetTester tester,
  LegalConsentController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showLegalCenter(context, controller),
            child: const Text('打开协议中心'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开协议中心'));
  await tester.pumpAndSettle();
}

Future<void> _readCurrentDocuments(WidgetTester tester) async {
  for (final id in ['terms', 'privacy']) {
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(0);
    await tester.pump();
    final expansion = find.byKey(Key('阅读$id'));
    final button = find.descendant(
      of: expansion,
      matching: find.byType(ListTile),
    );
    await _reveal(tester, button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    // Opening a folded document is independent of the explicit consent.
    expect(tester.widget<ExpansionTile>(expansion).initiallyExpanded, isFalse);
    await _reveal(tester, button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 80,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

FilledButton _acceptButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('同意并继续')));

CheckboxListTile _checkbox(WidgetTester tester, String key) =>
    tester.widget<CheckboxListTile>(find.byKey(Key(key)));

Future<LegalConsentController> _controller(
  _MemoryLegalRepository repository, {
  LegalBundle? bundle,
}) async {
  final controller = LegalConsentController(
    repository: repository,
    loadBundle: () async => bundle ?? _bundle(),
    clock: () => DateTime.utc(2026, 10, 19, 8),
  );
  await controller.initialize();
  return controller;
}

LegalBundle _bundle({bool published = true, String version = '1.0'}) =>
    LegalBundle.fromJson({
      'schemaVersion': 1,
      'bundleId': 'test-$version',
      'status': published ? 'published' : 'draft',
      'publishedAt': published ? '2026-10-19' : null,
      'effectiveAt': published ? '2026-10-19' : null,
      'operator': {
        'name': '合成测试提供者',
        'contactEmail': 'synthetic@example.invalid',
        'contactAddress': '合成测试地址',
      },
      'documents': [
        for (final entry in {'terms': '用户协议', 'privacy': '隐私政策'}.entries)
          {
            'id': entry.key,
            'title': entry.value,
            'version': version,
            'sections': [
              {
                'id': 'scope',
                'heading': '适用范围',
                'important': true,
                'paragraphs': ['$version${entry.value}正文；本地功能可独立使用。'],
              },
            ],
          },
      ],
      'pendingFields': published
          ? <Map<String, dynamic>>[]
          : [
              {'key': 'operator.name', 'label': '服务提供者', 'reason': '待负责人核实'},
            ],
    });

final class _MemoryLegalRepository implements LegalConsentRepository {
  final entries = <LegalConsentEntry>[];
  bool failAppend = false;

  @override
  Future<List<LegalConsentEntry>> load() async => List.of(entries);

  @override
  Future<void> append(LegalConsentEntry entry) async {
    if (failAppend) throw StateError('合成写入故障');
    entries.add(entry);
  }

  @override
  Future<void> clear() async => entries.clear();
}
