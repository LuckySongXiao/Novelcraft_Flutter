/// 项目状态 —— 对应 Core/Enums/ProjectStatus.cs
///
/// ⚠ 该枚举在 C# 的 Core / Application 两层**完全未被引用**：
/// 实体里 `Status` 一律用 string 存储。它实际只被 WPF 层当作下拉选项词典使用，
/// 因此 Dart 侧保留它并补上中文标签，供 UI 直接消费。
enum ProjectStatus {
  planning(0, 'Planning', '规划中'),
  inProgress(1, 'InProgress', '进行中'),
  paused(2, 'Paused', '暂停'),
  completed(3, 'Completed', '已完成'),
  cancelled(4, 'Cancelled', '已取消'),
  published(5, 'Published', '已发布'),
  archived(6, 'Archived', '归档');

  const ProjectStatus(this.value, this.code, this.labelZh);

  final int value;
  final String code;
  final String labelZh;

  static ProjectStatus? fromValue(int v) {
    for (final e in values) {
      if (e.value == v) return e;
    }
    return null;
  }

  static ProjectStatus? fromCode(String code) {
    for (final e in values) {
      if (e.code == code) return e;
    }
    return null;
  }
}

/// 角色类型 —— 对应 Core/Enums/CharacterType.cs
enum CharacterType {
  protagonist(0, 'Protagonist', '主角'),
  mainSupporting(1, 'MainSupporting', '主配'),
  supporting(2, 'Supporting', '次配'),
  guest(3, 'Guest', '客串'),
  extra(4, 'Extra', '龙套'),
  cannon(5, 'Cannon', '炮灰'),
  antagonist(6, 'Antagonist', '反派'),
  neutral(7, 'Neutral', '中立');

  const CharacterType(this.value, this.code, this.labelZh);

  final int value;
  final String code;
  final String labelZh;

  static CharacterType? fromValue(int v) {
    for (final e in values) {
      if (e.value == v) return e;
    }
    return null;
  }

  static CharacterType? fromCode(String code) {
    for (final e in values) {
      if (e.code == code) return e;
    }
    return null;
  }
}

/// 人物关系类型 —— 对应 Core/Enums/RelationshipType.cs
enum RelationshipType {
  lover(0, 'Lover', '恋人'),
  family(1, 'Family', '亲情'),
  friend(2, 'Friend', '友情'),
  masterStudent(3, 'MasterStudent', '师徒'),
  enemy(4, 'Enemy', '敌对'),
  rival(5, 'Rival', '竞争'),
  ally(6, 'Ally', '盟友'),
  loveRival(7, 'LoveRival', '情敌'),
  swornBrother(8, 'SwornBrother', '结义'),
  spouse(9, 'Spouse', '结发'),
  superior(10, 'Superior', '上下级'),
  colleague(11, 'Colleague', '同事'),
  stranger(12, 'Stranger', '陌生人');

  const RelationshipType(this.value, this.code, this.labelZh);

  final int value;
  final String code;
  final String labelZh;

  static RelationshipType? fromValue(int v) {
    for (final e in values) {
      if (e.value == v) return e;
    }
    return null;
  }

  static RelationshipType? fromCode(String code) {
    for (final e in values) {
      if (e.code == code) return e;
    }
    return null;
  }
}
