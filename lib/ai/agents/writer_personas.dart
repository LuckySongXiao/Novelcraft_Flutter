// 9 偏向写手人设库（多智能体写书固定编制：1 组长 + 9 写手）。
//
// 设计：
//   * 每个写手有固定槽位（slot 1..9）与偏向参数（keywords + biasPrompt）；
//   * 组长派活时按「组长指定 persona → 段落简介关键词匹配 → 槽位顺序」
//     三步落到具体写手（见 [matchPersona]）；
//   * 纯 Dart，无 Flutter / IO 依赖，可直接单测。
library;

/// 单个写手偏向人设。
class WriterPersona {
  const WriterPersona({
    required this.slot,
    required this.id,
    required this.nameZh,
    required this.nameEn,
    required this.keywords,
    required this.biasPrompt,
  });

  /// 固定槽位 1..9（对应组长分派 JSON 里的 agent 编号）。
  final int slot;

  /// 机器 ID（存档 / 日志 / state 分组用）。
  final String id;

  /// 中文名（进度文案与 UI 展示）。
  final String nameZh;

  /// 英文名（UI 英文态展示）。
  final String nameEn;

  /// 偏向关键词：组长段落计划的 brief/title 命中即优先派给该写手。
  final List<String> keywords;

  /// 偏向提示词：并入写手 system prompt，让该写手在自己擅长的维度发力。
  final String biasPrompt;

  String displayName(bool isEnglish) => isEnglish ? nameEn : nameZh;
}

/// 9 位偏向写手（顺序即槽位 1..9，勿乱）：
/// 打斗 / 聊天 / 搭讪 / 耍流氓 / 安抚人心 / 环境景物 / 心理刻画 / 悬疑伏笔 / 诙谐幽默。
const List<WriterPersona> kWriterPersonas = <WriterPersona>[
  WriterPersona(
    slot: 1,
    id: 'combat',
    nameZh: '打斗',
    nameEn: 'Combat',
    keywords: <String>[
      '打斗', '战斗', '交手', '搏杀', '厮杀', '比武', '出剑', '出刀', '追杀',
      '围攻', '偷袭', '对轰', '招式', '杀阵', '血战', '突围', '防备', '反击',
    ],
    biasPrompt:
        '擅长打斗场面：招式拆解具体、攻防节奏分明、力量与伤势有实感，'
        '打斗中穿插战局判断与险境应对，避免「一招定胜负」的敷衍写法。',
  ),
  WriterPersona(
    slot: 2,
    id: 'dialogue',
    nameZh: '聊天',
    nameEn: 'Dialogue',
    keywords: <String>[
      '对话', '聊天', '交谈', '问答', '谈话', '密谈', '议事', '讨论', '商议',
      '传音', '口信', '解释', '交代', '对谈', '叙话',
    ],
    biasPrompt:
        '擅长对话戏：台词符合人物身份与口吻，一来一往有机锋与潜台词，'
        '对话中推进信息差与关系变化，避免大段说明文式对白。',
  ),
  WriterPersona(
    slot: 3,
    id: 'flirt',
    nameZh: '搭讪',
    nameEn: 'Flirt',
    keywords: <String>[
      '搭讪', '结识', '寒暄', '调笑', '献殷勤', '试探', '眉眼', '初见',
      '结识', '约', '邀', '亲近', '好感',
    ],
    biasPrompt:
        '擅长搭讪与社交破冰：进退有度的试探、恰到好处的幽默与体贴，'
        '写好第一印象的微妙张力，避免油腻与冒犯式表达。',
  ),
  WriterPersona(
    slot: 4,
    id: 'rogue',
    nameZh: '耍流氓',
    nameEn: 'Rogue',
    keywords: <String>[
      '耍赖', '讹', '赖账', '痞', '混混', '使坏', '偷', '混入', '浑水摸鱼',
      '耍横', '无赖', '钻空子', '撬', '赌', '坑', '蒙',
    ],
    biasPrompt:
        '擅长市井痞气与不按常理出牌：小聪明、耍无赖、钻空子的桥段生动可信，'
        '痞而不恶、坏得有分寸，服务于剧情而非纯粹的胡闹。',
  ),
  WriterPersona(
    slot: 5,
    id: 'comfort',
    nameZh: '安抚人心',
    nameEn: 'Comfort',
    keywords: <String>[
      '安慰', '安抚', '宽慰', '劝解', '抹泪', '哭泣', '恐惧', '崩溃', '心结',
      '鼓励', '振作', '绝望', '无助', '开导', '陪伴',
    ],
    biasPrompt:
        '擅长安抚人心：情绪落点精准，先共情后托底，话语有温度不说教，'
        '把人物从崩溃边缘拉回来的过程写得可信动人。',
  ),
  WriterPersona(
    slot: 6,
    id: 'scenery',
    nameZh: '环境景物',
    nameEn: 'Scenery',
    keywords: <String>[
      '环境', '景色', '场景', '景物', '山', '雪', '雨', '风', '宫殿', '洞府',
      '坊市', '天色', '月光', '破晓', '暮色', '氛围', '布景',
    ],
    biasPrompt:
        '擅长环境景物描写：以景衬情、声光色味俱全，'
        '用环境细节暗示局势与人物心境，避免辞藻堆砌。',
  ),
  WriterPersona(
    slot: 7,
    id: 'psych',
    nameZh: '心理刻画',
    nameEn: 'Psychology',
    keywords: <String>[
      '心理', '内心', '心想', '暗道', '犹豫', '挣扎', '思绪', '回忆', '心念',
      '念头', '自我怀疑', '动机', '取舍', '心魔',
    ],
    biasPrompt:
        '擅长心理刻画：内心独白层次分明，写透动机、顾虑与挣扎，'
        '让转变有铺垫，避免直接替人物贴情绪标签。',
  ),
  WriterPersona(
    slot: 8,
    id: 'suspense',
    nameZh: '悬疑伏笔',
    nameEn: 'Suspense',
    keywords: <String>[
      '悬念', '伏笔', '谜', '秘密', '诡异', '异常', '窥视', '暗涌', '线索',
      '真相', '布局', '暗手', '危机', '不对劲',
    ],
    biasPrompt:
        '擅长悬疑与伏笔：信息按节奏释放、钩子留得住，'
        '铺好的伏笔记着回收，让读者带着问题往下读。',
  ),
  WriterPersona(
    slot: 9,
    id: 'humor',
    nameZh: '诙谐幽默',
    nameEn: 'Humor',
    keywords: <String>[
      '幽默', '搞笑', '滑稽', '笑话', '逗趣', '打趣', '插科打诨', '轻松',
      '欢脱', '闹', '拌嘴', '吐槽',
    ],
    biasPrompt:
        '擅长诙谐幽默：轻喜剧节奏松弛有度，梗服务于人物与剧情，'
        '紧张段落之后给出恰到好处的喘息。',
  ),
];

/// 固定团队编制。
const int kChapterTeamSize = 10; // 1 组长 + 9 写手
const int kWriterCount = 9;

/// 按槽位取人设（越界时钳制到 1..9）。
WriterPersona personaForSlot(int slot) {
  final int i = slot < 1 ? 1 : (slot > kWriterPersonas.length ? kWriterPersonas.length : slot);
  return kWriterPersonas[i - 1];
}

/// 按 id 取人设；未找到返回 null。
WriterPersona? personaById(String id) {
  for (final WriterPersona p in kWriterPersonas) {
    if (p.id == id) return p;
  }
  return null;
}

/// 段落任务 → 偏向写手匹配（纯函数）。
///
/// 规则：
///   1. `assignedPersonaId` 非空且能找到人设 → 直接采用（组长指定优先）；
///   2. 在 `title + brief` 里按关键词计数匹配，命中最多的人设胜出；
///      同分（含全部 0 分）按槽位顺序取第一个命中者 / 第一个槽位；
///   3. 无任何命中 → null（调用方按槽位顺序轮转兜底）。
WriterPersona? matchPersona(
  String title,
  String brief, {
  String? assignedPersonaId,
}) {
  if (assignedPersonaId != null && assignedPersonaId.trim().isNotEmpty) {
    final WriterPersona? assigned = personaById(assignedPersonaId.trim());
    if (assigned != null) return assigned;
  }
  final String text = '$title\n$brief';
  WriterPersona? best;
  int bestScore = 0;
  for (final WriterPersona p in kWriterPersonas) {
    int score = 0;
    for (final String kw in p.keywords) {
      if (text.contains(kw)) score++;
    }
    if (score > bestScore) {
      bestScore = score;
      best = p;
    } else if (score == bestScore && score > 0 && best == null) {
      best = p; // 同分时先到先得（槽位顺序）
    }
  }
  return best;
}

/// 供组长派活提示词使用的人设清单文本（列出 9 位写手的偏向）。
String describePersonasForPrompt({bool isEnglish = false}) {
  final StringBuffer sb = StringBuffer();
  for (final WriterPersona p in kWriterPersonas) {
    sb.writeln('- 写手${p.slot}（${p.displayName(isEnglish)}）：${p.biasPrompt}');
  }
  return sb.toString().trim();
}
