// 9 偏向写手人设完备性与匹配规则测试。
//
// 运行：flutter test test/writer_personas_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/agents/writer_personas.dart';

void main() {
  group('kWriterPersonas（9 偏向人设）', () {
    test('恰好 9 位，槽位 1..9 连续不重复', () {
      expect(kWriterPersonas.length, 9);
      for (int i = 0; i < kWriterPersonas.length; i++) {
        expect(kWriterPersonas[i].slot, i + 1, reason: '槽位必须连续');
      }
      expect(
        kWriterPersonas.map((WriterPersona p) => p.id).toSet().length,
        9,
        reason: 'id 必须唯一',
      );
    });

    test('用户点名的 5 种偏向全部在列', () {
      final Set<String> ids = kWriterPersonas.map((WriterPersona p) => p.id).toSet();
      expect(ids, containsAll(<String>['combat', 'dialogue', 'flirt', 'rogue', 'comfort']));
    });

    test('用户选定的 4 种偏向全部在列', () {
      final Set<String> ids = kWriterPersonas.map((WriterPersona p) => p.id).toSet();
      expect(ids, containsAll(<String>['scenery', 'psych', 'suspense', 'humor']));
    });

    test('每个人设的关键词与偏向提示词非空', () {
      for (final WriterPersona p in kWriterPersonas) {
        expect(p.keywords, isNotEmpty, reason: '${p.id} 缺关键词');
        expect(p.biasPrompt.trim(), isNotEmpty, reason: '${p.id} 缺偏向提示词');
        expect(p.nameZh.trim(), isNotEmpty);
        expect(p.nameEn.trim(), isNotEmpty);
      }
    });
  });

  group('matchPersona（派活匹配）', () {
    test('组长指定 persona 优先', () {
      final WriterPersona? p = matchPersona(
        '夜袭',
        '一场恶战',
        assignedPersonaId: 'humor',
      );
      expect(p?.id, 'humor');
    });

    test('关键词命中偏向写手（打斗）', () {
      final WriterPersona? p = matchPersona('刀光剑影', '双方交手，招式往来，血战到底');
      expect(p?.id, 'combat');
    });

    test('关键词命中安抚人心', () {
      final WriterPersona? p = matchPersona('崩溃边缘', '她抹着泪，他低声安慰，劝她重新振作');
      expect(p?.id, 'comfort');
    });

    test('无命中返回 null（调用方按槽位轮转兜底）', () {
      expect(matchPersona('推进', '普通剧情段落'), isNull);
    });

    test('personaById / personaForSlot 边界钳制', () {
      expect(personaById('nonexistent'), isNull);
      expect(personaForSlot(0).slot, 1);
      expect(personaForSlot(99).slot, 9);
      expect(personaForSlot(5).id, 'comfort');
    });

    test('describePersonasForPrompt 覆盖全部 9 个写手', () {
      final String text = describePersonasForPrompt();
      for (final WriterPersona p in kWriterPersonas) {
        expect(text, contains(p.nameZh), reason: '派活提示词必须列出写手${p.slot}');
      }
    });
  });
}
