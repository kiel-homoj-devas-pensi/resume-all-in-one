import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:resume_all_in_one_client/src/remote_ai_dialogs.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';

void main() {
  final content = ResumeData(
    profile: ResumeProfile(
      id: 'profile',
      fullName: '测试',
      headline: '参与移动端开发',
      email: '',
      phone: '',
      location: '',
    ),
  );

  Future<void> open(
    WidgetTester tester,
    ValueChanged<RemoteWritingContext?> result, {
    RemoteWritingContext? initial,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async => result(
                await showDialog<RemoteWritingContext>(
                  context: context,
                  builder: (_) => RemoteWritingContextDialog(
                    content: content,
                    initial: initial ?? RemoteWritingContext(),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('未明确核实的输入不会进入已确认材料，确认不改Canonical', (tester) async {
    RemoteWritingContext? result;
    await open(tester, (value) => result = value);
    await tester.enterText(find.byKey(const Key('AI完整事实输入')), '参与开发，未主导团队');
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('确认这一段AI事实')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('保存AI确认材料')));
    await tester.pumpAndSettle();
    expect(result!.confirmedFacts, isEmpty);
    expect(content.profile.headline, '参与移动端开发');

    await open(tester, (value) => result = value);
    await tester.enterText(find.byKey(const Key('AI完整事实输入')), '参与开发，未主导团队');
    await tester.ensureVisible(find.byKey(const Key('核实AI段落事实')));
    await tester.tap(find.byKey(const Key('核实AI段落事实')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('确认这一段AI事实')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('保存AI确认材料')));
    await tester.pumpAndSettle();
    expect(result!.confirmedFacts, {'/profile/headline': '参与开发，未主导团队'});
    expect(content.profile.headline, '参与移动端开发');
  });

  testWidgets('取消确认材料保持旧材料不变；修改文本撤销核实勾选', (tester) async {
    final initial = RemoteWritingContext(
      confirmedFacts: {'/profile/headline': '原事实'},
      constraints: ['保持中文'],
    );
    RemoteWritingContext? result;
    await open(tester, (value) => result = value, initial: initial);
    await tester.ensureVisible(find.byKey(const Key('核实AI段落事实')));
    await tester.tap(find.byKey(const Key('核实AI段落事实')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('AI完整事实输入')), '改变后的事实');
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byKey(const Key('核实AI段落事实'))).value,
      isFalse,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(initial.confirmedFacts, {'/profile/headline': '原事实'});
    expect(initial.constraints, ['保持中文']);
  });

  testWidgets('长期要求按明确保存保留，超限要求拒绝关闭对话框', (tester) async {
    RemoteWritingContext? result;
    await open(tester, (value) => result = value);
    await tester.ensureVisible(find.byKey(const Key('AI长期要求输入')));
    await tester.enterText(
      find.byKey(const Key('AI长期要求输入')),
      List.filled(13, '保持中文').join('\n'),
    );
    await tester.tap(find.byKey(const Key('保存AI确认材料')));
    await tester.pump();
    expect(result, isNull);
    expect(find.byType(RemoteWritingContextDialog), findsOneWidget);
    expect(find.text('长期要求最多12条，每条500字，合计3000字。'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('AI长期要求输入')), '只改项目描述\n不要改日期');
    await tester.tap(find.byKey(const Key('保存AI确认材料')));
    await tester.pumpAndSettle();
    expect(result!.constraints, ['只改项目描述', '不要改日期']);
  });

  for (final size in [const Size(320, 700), const Size(640, 280)]) {
    testWidgets('确认材料在窄屏或短横屏两倍字号仍可取消 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, (_) {});
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteWritingContextDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
