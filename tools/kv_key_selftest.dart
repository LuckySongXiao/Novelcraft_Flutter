// 存储键净化 / 路径拼接 / 项目进度派生量自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/kv_key_selftest.dart
//
// 三个纯函数放在同一个脚本里（都只有寥寥几条断言，且都是 2026-10-09 的修复）：
//   A 组 `sanitizeStoreKey`  —— 键含 `:` 会让 native 端写盘抛异常并被静默吞掉
//      （审查留言永远为空 / 章节同步防重永远失效的直接原因）；
//   B 组 `progressFromChapterCounts` —— 「完成进度」此前恒为 0，因为派生规则根本不存在。
//   D 组 `storeFileName` / `storeFilePath` / `storeKeyFromFileName` —— 路径拼接。
//      ⚠ D3/D4 是**回归锁**：`key_value_store_native.dart` 曾写成
//      `'...${sep}$_fileOf(key)'`，而 `$identifier` 只插值简单标识符 ——
//      插进去的是**函数对象**，`(key)` 退化为字面文本，启动即
//      `PathNotFoundException (errno 123)`。类型检查发现不了（插值函数是合法 Dart），
//      只能靠这几条断言钉死。
import '../lib/application/models/stats.dart';
import '../lib/data/storage/store_key.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, {String detail = ''}) {
  if (ok) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name${detail.isEmpty ? '' : '\n  $detail'}');
  }
}

void eqStr(String name, String got, String want) {
  check(name, got == want, detail: 'want=«$want»\n  got =«$got»');
}

void eqNum(String name, double got, double want) {
  check(name, (got - want).abs() < 0.0001, detail: 'want=$want got=$got');
}

void main() {
  print('===== A. sanitizeStoreKey =====');

  // 🔴 本轮正主 1：审查留言的键
  eqStr('A1 审查留言键的冒号被替换',
      sanitizeStoreKey('046ed58f-6442-4d27-8689-b75a4606f8d0:5d511cbf-9051'),
      '046ed58f-6442-4d27-8689-b75a4606f8d0_5d511cbf-9051');

  // 🔴 本轮正主 2：章节同步防重签名
  eqStr('A2 防重签名键的冒号被替换',
      sanitizeStoreKey('last_success_v2:abc-123'), 'last_success_v2_abc-123');

  eqStr('A3 本来合法的键原样保留',
      sanitizeStoreKey('provider_cfg.deepseek'), 'provider_cfg.deepseek');
  eqStr('A4 中文键保留（便于人肉排查）',
      sanitizeStoreKey('ui_prefs.界面'), 'ui_prefs.界面');
  eqStr('A5 反斜杠 / 正斜杠被替换',
      sanitizeStoreKey(r'a\b/c'), 'a_b_c');
  eqStr('A6 通配与保留字符被替换',
      sanitizeStoreKey('a<b>c"d|e?f*g'), 'a_b_c_d_e_f_g');
  eqStr('A7 控制字符被替换', sanitizeStoreKey('a\u0000b\u001fc'), 'a_b_c');
  eqStr('A8 结尾的点被去掉（Windows 不允许）',
      sanitizeStoreKey('weird.'), 'weird');
  eqStr('A9 结尾空格被去掉', sanitizeStoreKey('weird   '), 'weird');
  eqStr('A10 全非法也有兜底名', sanitizeStoreKey(':::'), '___');
  eqStr('A11 空串有兜底名', sanitizeStoreKey(''), '_');
  // 幂等：listKeys 返回的已是净化后的键，再拿去 readJson 必须仍然解析到同一条记录
  eqStr('A12 净化幂等',
      sanitizeStoreKey(sanitizeStoreKey('a:b:c')), sanitizeStoreKey('a:b:c'));

  print('===== B. progressFromChapterCounts =====');

  eqNum('B1 无章节 → 0', progressFromChapterCounts(0, 0), 0);
  eqNum('B2 全部完成 → 100', progressFromChapterCounts(27, 27), 100);
  eqNum('B3 27/30 → 90', progressFromChapterCounts(27, 30), 90);
  eqNum('B4 一章未写 → 0', progressFromChapterCounts(0, 30), 0);
  eqNum('B5 取整前的精度（1/3）', progressFromChapterCounts(1, 3), 100 / 3);
  eqNum('B6 分子超分母被夹到 100', progressFromChapterCounts(35, 30), 100);
  eqNum('B7 负数被夹到 0', progressFromChapterCounts(-1, 30), 0);

  print('===== D. 文件名 / 路径拼接（含 errno 123 回归锁）=====');

  eqStr('D1 文件名带 .json 后缀',
      storeFileName('provider_cfg.deepseek'), 'provider_cfg.deepseek.json');
  eqStr('D2 文件名同样经过冒号净化',
      storeFileName('pid:cid'), 'pid_cid.json');

  // ⚠ 回归锁：这一串一旦出现在路径里，Windows 启动就会炸 errno 123。
  const String sep = '\\';
  final String p = storeFilePath(r'C:\x\internal', 'pid:cid', sep);
  eqStr('D3 路径拼接正确', p, r'C:\x\internal\pid_cid.json');
  check('D4 路径不得含函数对象文本（errno 123 回归锁）',
      !p.contains('Closure') && !p.contains('Function(') && !p.contains('static'),
      detail: 'got=«$p»');
  check('D5 路径不含任何 Windows 非法字符',
      !RegExp(r'[<>:"|?*]').hasMatch(p.replaceFirst(r'C:', '')),
      detail: 'got=«$p»');

  eqStr('D6 Linux 分隔符', storeFilePath('/a/b', 'k', '/'), '/a/b/k.json');

  // listKeys 的契约：返回的键走 readJson 必须命中同一个文件（互为逆运算）
  eqStr('D7 文件名 → 键 往返',
      storeKeyFromFileName(storeFileName('a:b')), 'a_b');
  eqStr('D8 只剥结尾的 .json（键名中间含它也不能削）',
      storeKeyFromFileName('a.json.b.json'), 'a.json.b');
  eqStr('D9 没有后缀时原样返回',
      storeKeyFromFileName('plain'), 'plain');
  eqStr('D10 往返幂等（读回再写回不会漂移）',
      storeFileName(storeKeyFromFileName(storeFileName('x:y.json'))),
      storeFileName('x:y.json'));

  print('===============================');
  print('pass=$pass  fail=$fail');
  if (fail > 0) {
    print('SELFTEST FAILED');
    throw StateError('$fail case(s) failed');
  }
  print('SELFTEST OK');
}
