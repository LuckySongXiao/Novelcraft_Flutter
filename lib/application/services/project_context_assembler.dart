// 项目级 AI 上下文（读模型）。
//
// 对应 C# 两个文件：
// - `WPF/Models/ProjectContextData.cs`       → [ProjectContextData]
// - `WPF/Services/ProjectReadModelService.BuildAiContextDataAsync` / `BuildPromptSummary`
//   / `BuildSubsystemPromptContextAsync`     → [ProjectContextAssembler]
//
// 全部 AI 生成入口都应带上这份上下文，保证「新内容优先遵循项目基本信息、大纲建立在世界设定之上」。
//
// 与 C# 的差异：C# 的 `BuildAiContextDataAsync` 在异常时 `throw`（由 `ProjectContextAssembler`
// 兜住返回空对象）；Dart 侧让异常直接上抛（本项目服务层统一约定，见 `ProjectService` 注释）。
//
// 注：`PromptSummary` 里的 `【…】` 标题与「未设置 / 无摘要」等占位符是 **prompt 内容**，
// 按 C# 原样硬编码、不参与 UI 本地化（对应 HANDOFF 的中文三分法第 ③ 类）。
library;

import '../../data/database.dart';
import '../../data/repositories/character_repository.dart';
import '../../data/repositories/plot_repository.dart';
import '../../data/repositories/project_repository.dart';
import '../../data/repositories/world_setting_repository.dart';

/// 对应 C# `ProjectContextData`。
class ProjectContextData {
  const ProjectContextData({
    required this.projectId,
    required this.projectName,
    required this.projectDescription,
    required this.projectType,
    required this.projectTags,
    required this.projectNotes,
    required this.plotOutlines,
    required this.mainCharacters,
    required this.worldSettings,
    required this.promptSummary,
  });

  final String projectId;
  final String projectName;
  final String projectDescription;
  final String projectType;
  final String projectTags;
  final String projectNotes;

  /// 形如 `{Title}｜类型：{Type}｜{Description 或 无摘要}`
  final List<String> plotOutlines;

  /// 形如 `{Name}｜类型：{Type}｜{Background 或 无背景}`
  final List<String> mainCharacters;

  /// 形如 `{Name}｜类型：{Type}｜{Content 或 无内容}`
  final List<String> worldSettings;

  /// 可直接拼进 Prompt 的摘要（结构见 [ProjectContextAssembler.buildPromptSummary]）。
  final String promptSummary;

  /// 空上下文（无当前项目时使用）。
  static const ProjectContextData empty = ProjectContextData(
    projectId: '',
    projectName: '',
    projectDescription: '',
    projectType: '',
    projectTags: '',
    projectNotes: '',
    plotOutlines: <String>[],
    mainCharacters: <String>[],
    worldSettings: <String>[],
    promptSummary: '',
  );

  /// 仅用于补写 [promptSummary]（它由其余字段派生）。
  ProjectContextData withPromptSummary(String summary) => ProjectContextData(
        projectId: projectId,
        projectName: projectName,
        projectDescription: projectDescription,
        projectType: projectType,
        projectTags: projectTags,
        projectNotes: projectNotes,
        plotOutlines: plotOutlines,
        mainCharacters: mainCharacters,
        worldSettings: worldSettings,
        promptSummary: summary,
      );
}

/// 对应 C# `ProjectContextAssembler`（组合 `ProjectReadModelService` 的 AI 上下文部分）。
class ProjectContextAssembler {
  ProjectContextAssembler({
    required ProjectRepository projects,
    required PlotRepository plots,
    required CharacterRepository characters,
    required WorldSettingRepository worldSettings,
  })  : _projects = projects,
        _plots = plots,
        _characters = characters,
        _worldSettings = worldSettings;

  final ProjectRepository _projects;
  final PlotRepository _plots;
  final CharacterRepository _characters;
  final WorldSettingRepository _worldSettings;

  /// 对应 C# `BuildAiContextDataAsync(projectId)`。
  ///
  /// 取数与排序**逐字对齐**：
  /// - 剧情：`importance` 降序 → `title` 升序 → `take(5)`
  /// - 角色：`importance` 降序 → `name` 升序 → `take(10)`
  /// - 设定：`importance` 降序 → `name` 升序 → `take(10)`
  ///
  /// 项目查不到时按 C# 的 `project?.X ?? string.Empty` 继续构建（而不是提前返回空对象）——
  /// 此时 `PromptSummary` 的项目字段全部落到 `未设置` 占位。
  Future<ProjectContextData> build(String projectId) async {
    final ProjectRow? project = await _projects.getById(projectId);

    final List<PlotRow> plots = await _plots.getByProjectId(projectId);
    final List<String> plotOutlines = _sortedByImportanceThen<PlotRow>(
      plots,
      (PlotRow p) => p.importance,
      (PlotRow p) => p.title,
    )
        .take(5)
        .map((PlotRow p) => '${p.title}｜类型：${p.type}｜'
            '${_isBlank(p.description) ? '无摘要' : p.description}')
        .toList();

    final List<CharacterRow> characters =
        await _characters.getByProjectId(projectId);
    final List<String> mainCharacters = _sortedByImportanceThen<CharacterRow>(
      characters,
      (CharacterRow c) => c.importance,
      (CharacterRow c) => c.name,
    )
        .take(10)
        .map((CharacterRow c) => '${c.name}｜类型：${c.type}｜'
            '${_isBlank(c.background) ? '无背景' : c.background}')
        .toList();

    final List<WorldSettingRow> settings =
        await _worldSettings.getByProjectId(projectId);
    final List<String> worldSettings = _sortedByImportanceThen<WorldSettingRow>(
      settings,
      (WorldSettingRow s) => s.importance,
      (WorldSettingRow s) => s.name,
    )
        .take(10)
        .map((WorldSettingRow s) => '${s.name}｜类型：${s.type}｜'
            '${_isBlank(s.content) ? '无内容' : s.content}')
        .toList();

    final ProjectContextData data = ProjectContextData(
      projectId: projectId,
      projectName: project?.name ?? '',
      projectDescription: project?.description ?? '',
      projectType: project?.type ?? '',
      projectTags: project?.tags ?? '',
      projectNotes: project?.notes ?? '',
      plotOutlines: plotOutlines,
      mainCharacters: mainCharacters,
      worldSettings: worldSettings,
      promptSummary: '',
    );
    return data.withPromptSummary(buildPromptSummary(data));
  }

  /// 对应 C# `BuildSubsystemPromptContextAsync(projectId, subsystemName, extraConstraints)`。
  ///
  /// 失败时返回空字符串（不阻断局部生成能力）。
  Future<String> buildSubsystemPromptContext(
    String projectId,
    String subsystemName, {
    List<String> extraConstraints = const <String>[],
  }) async {
    if (projectId.isEmpty || _isBlank(subsystemName)) return '';
    try {
      final ProjectContextData ctx = await build(projectId);
      final List<String> lines = <String>[];
      if (!_isBlank(ctx.promptSummary)) {
        lines.add(ctx.promptSummary);
        lines.add('');
      }
      lines.add('【$subsystemName生成约束】');
      lines.add('- 只能生成$subsystemName相关内容，不得输出正文、完整大纲、角色小传或无关模块。');
      lines.add('- 必须优先遵循项目基础信息，再遵循已有世界设定和大纲。');
      lines.add('- 层级顺序必须保持为：项目基础信息 -> 世界观 -> 大纲 -> 配套设定 -> 正文写作。');
      for (final String c in extraConstraints) {
        if (!_isBlank(c)) lines.add('- $c');
      }
      return lines.join('\n').trim();
    } on Object {
      return '';
    }
  }

  /// 对应 C# `BuildPromptSummary(contextData)`。
  ///
  /// ⚠ 三段顺序是 **世界设定 → 剧情大纲 → 主要角色**（与「项目基础信息 → 世界观 → 大纲 → 配套设定」
  /// 的表述顺序不同，勿写反）。取条数上限依次 5 / 5 / 8。
  ///
  /// ⚠ C# **没有字符级截断**（只在「取几条」层面限制），单条内容全量进 prompt —— 此处保持一致。
  static String buildPromptSummary(ProjectContextData data) {
    final List<String> lines = <String>[];
    lines.add('【项目基本信息】');
    lines.add('项目名称：${_emptyAsPlaceholder(data.projectName)}');
    lines.add('项目类型：${_emptyAsPlaceholder(data.projectType)}');
    lines.add('项目描述：${_emptyAsPlaceholder(data.projectDescription)}');
    lines.add('项目标签：${_emptyAsPlaceholder(data.projectTags)}');
    lines.add('项目备注：${_emptyAsPlaceholder(data.projectNotes)}');
    lines.add('');
    _appendList(lines, '【已有世界设定】', data.worldSettings, 5);
    lines.add('');
    _appendList(lines, '【已有剧情大纲】', data.plotOutlines, 5);
    lines.add('');
    _appendList(lines, '【主要角色】', data.mainCharacters, 8);
    lines.add('');
    lines.add('【生成约束】');
    lines.add('- 新生成内容必须优先遵循项目基本信息。');
    lines.add('- 大纲必须建立在世界设定之上。');
    lines.add('- 其他设定必须按“项目基础信息 -> 世界观 -> 大纲 -> 配套设定 -> 正文写作”的顺序保持一致。');
    return lines.join('\n').trim();
  }

  static void _appendList(
    List<String> lines,
    String heading,
    List<String> items,
    int take,
  ) {
    lines.add(heading);
    if (items.isEmpty) {
      lines.add('- 暂无');
      return;
    }
    for (final String item in items.take(take)) {
      lines.add('- $item');
    }
  }

  /// 对应 C# `OrderByDescending(importance).ThenBy(name/title)`。
  static Iterable<T> _sortedByImportanceThen<T>(
    List<T> source,
    int Function(T) importance,
    String Function(T) name,
  ) {
    final List<T> copy = List<T>.of(source);
    copy.sort((T a, T b) {
      final int byImportance = importance(b).compareTo(importance(a));
      if (byImportance != 0) return byImportance;
      return name(a).compareTo(name(b));
    });
    return copy;
  }

  static String _emptyAsPlaceholder(String? value) =>
      _isBlank(value) ? '未设置' : value!.trim();

  static bool _isBlank(String? value) => value == null || value.trim().isEmpty;
}