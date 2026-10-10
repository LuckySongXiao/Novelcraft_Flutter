// 复读守卫回归自检（纯 Dart，离线直跑）：
//   dart --disable-dart-dev tools/repetition_guard_selftest.dart
//
// 覆盖：n-gram 重复率 / 连续重复行 / 段落级重复 / isDegenerate 综合判定 /
//       正常文本（散文、结构化大纲、短文本）不误杀。
import '../lib/ai/utils/repetition_guard.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool cond) {
  if (cond) {
    _passed++;
    print('  ok  $name');
  } else {
    _failed++;
    print('FAIL  $name');
  }
}

void main() {
  print('== A. 字符级 n-gram 重复率 ==');
  const String prose =
      '夜风从祠堂的檐角掠过，把供桌上最后一炷香吹得明明灭灭。'
      '陈九蹲在门槛后头，听见村道远处传来铃铛声，一下一下，像是从水底捞上来的。'
      '他知道那个时辰不该有人进村，可铃铛偏偏停在了村口的老槐树下。';
  final double proseRatio = RepetitionGuard.charNgramRepeatRatio(prose);
  print('  正常散文 ngram=$proseRatio');
  _check('A1 正常散文重复率低', proseRatio < 0.10);

  final String loop = '他要在这天夜里把祭祀做完，否则全村都要遭殃。' * 6;
  final double loopRatio = RepetitionGuard.charNgramRepeatRatio(loop);
  print('  循环复读 ngram=$loopRatio');
  _check('A2 循环复读重复率高', loopRatio > 0.60);

  _check(
    'A3 短文本证据不足返回0',
    RepetitionGuard.charNgramRepeatRatio('这是一句很短的话') == 0,
  );

  // 跨行/跨空格的同一句被打散也能抓住（归一化后仍是同一 shingle）
  final String broken = ('他要在这天夜里把祭祀做完，\n否则全村都要遭殃。' * 5);
  _check('A4 跨行复读仍可检出', RepetitionGuard.charNgramRepeatRatio(broken) > 0.60);

  print('== B. 连续重复行 ==');
  _check(
    'B1 紧邻重复行命中',
    RepetitionGuard.hasConsecutiveDuplicateLines(
      '第一句写到这里就算完了。\n第一句写到这里就算完了。\n另一句。',
    ),
  );
  _check(
    'B2 不紧邻不算',
    !RepetitionGuard.hasConsecutiveDuplicateLines(
      '第一句写到这里就算完了。\n另一句内容完全不同。\n第一句写到这里就算完了。',
    ),
  );
  _check(
    'B3 短行豁免',
    !RepetitionGuard.hasConsecutiveDuplicateLines('他说。\n他说。\n她说。'),
  );
  _check(
    'B4 空白形态差异仍命中',
    RepetitionGuard.hasConsecutiveDuplicateLines(
      '他要在这天夜里把祭祀做完。\n  他要在这天夜里把祭祀做完。  \n结尾。',
    ),
  );

  print('== C. 段落级重复率 ==');
  final String paraDup = List<String>.filled(
    5,
    '这一段反复出现，段落级检测应该抓住它，因为五段一模一样。',
  ).join('\n\n');
  _check('C1 全同段落命中', RepetitionGuard.paragraphRepeatRatio(paraDup) == 0.8);
  _check(
    'C2 少于4段不判',
    RepetitionGuard.paragraphRepeatRatio('段落一超过十二个字了吗。\n段落一超过十二个字了吗。') == 0,
  );
  _check('C3 全同段落判退化', RepetitionGuard.isDegenerate(paraDup));

  print('== D. isDegenerate 综合 ==');
  // +46 实测形态：双层前缀 + 模板句循环
  final String screenshotLike =
      '本章目标：本章目标：这一章要推进祭祀之夜的揭露，'
      '把陈九推到祠堂供桌前，让他亲眼看见牌位后面的夹层。本章目标：这一章要推进祭祀之夜的揭露，'
      '把陈九推到祠堂供桌前，让他亲眼看见牌位后面的夹层。本章目标：这一章要推进祭祀之夜的揭露，'
      '把陈九推到祠堂供桌前，让他亲眼看见牌位后面的夹层。本章目标：这一章要推进祭祀之夜的揭露。';
  _check('D1 复读样本判退化', RepetitionGuard.isDegenerate(screenshotLike));
  print('  diagnose: ${RepetitionGuard.diagnose(screenshotLike)}');

  const String outline =
      '本章目标：陈九在祭祀当夜发现牌位夹层里的血书\n'
      '承接上文：上一章结尾陈九把供桌上的香灰扫落在地\n'
      '核心冲突：族规与真相的撕扯\n'
      '关键转折：夹层血书指向陈九自己的父亲\n'
      '章末钩子：祠堂的门在身后闩上了\n'
      '出场人物：陈九、三叔公\n'
      '故事时间节点：祭祀当夜';
  _check('D2 正常结构化大纲不误杀', !RepetitionGuard.isDegenerate(outline));
  _check('D3 正常散文不误杀', !RepetitionGuard.isDegenerate(prose));
  _check('D4 短文本不判（清洗层另有门槛）', !RepetitionGuard.isDegenerate('本章目标：本章目标：短复读'));
  _check('D5 空文本安全', !RepetitionGuard.isDegenerate(''));

  print('== 结果 ==');
  print('passed=$_passed failed=$_failed');
  if (_failed > 0) {
    throw StateError('repetition_guard_selftest: $_failed 例失败');
  }
}
