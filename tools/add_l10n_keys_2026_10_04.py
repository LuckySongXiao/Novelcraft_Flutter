#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把本批次新增的 Flutter 词条追加到 lib/l10n/strings.g.dart 的
zhStrings / enStrings 两张表末尾。

strings.g.dart 由 csv_to_dart.py 从 C# CSV 生成，但 Flutter 侧新增的词条
（本仓库已有 690+ 条同样做法）直接追加在两张表尾部；本脚本保证 zh/en 一一对应、
幂等（已存在的 key 跳过）。
"""
import io
import os
import re

SRC = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "lib", "l10n", "strings.g.dart",
)

ENTRIES = [
    # ---- 设置页首卡：写作工艺 Prompt 模板入口 ----
    ("Set.WritingPrompt", "写作工艺 Prompt 模板", "Writing Process Prompt Templates"),
    ("Set.WritingPromptDesc", "编辑各节点提示词、保存多套模板并选择生效模板",
     "Edit the prompt for each node, keep multiple template sets and choose the active one"),
    # ---- Prompt 模板页 ----
    ("WPS.Title", "写作工艺 Prompt 模板", "Writing Process Prompt Templates"),
    ("WPS.Intro",
     "每个节点可保存多套模板。选择并保存后生效，重启后保留。多智能体写书任务使用启动时的配置；运行中的任务请结束后再重启。资源模板按中文 / English 分开配置。",
     "Each node can keep multiple template sets. The selection takes effect after saving and survives a restart. "
     "Multi-agent book tasks use the configuration captured at launch, so finish running tasks before restarting. "
     "Resource templates are configured separately for Chinese and English."),
    ("WPS.LoadFailed", "读取模板失败：{0}", "Failed to load templates: {0}"),
    ("WPS.LoadWarning",
     "已保存的提示词配置损坏或不兼容，当前使用内置模板；原配置未覆盖。保存新配置会替换原配置。",
     "The saved prompt configuration is corrupt or incompatible; built-in templates are in use and the original "
     "configuration was left untouched. Saving a new configuration will replace it."),
    ("WPS.CurrentFmt", "当前：{0} · 自定义 {1} 套", "Current: {0} · {1} custom set(s)"),
    ("WPS.BuiltinDefault", "内置默认", "Built-in default"),
    ("WPS.NodeTemplate", "该节点使用的模板（保存后生效）",
     "Template used by this node (applies after saving)"),
    ("WPS.CopyAsNew", "复制为新模板", "Duplicate as new template"),
    ("WPS.DeleteCurrent", "删除当前模板", "Delete current template"),
    ("WPS.Saving", "保存中…", "Saving…"),
    ("WPS.Save", "保存模板与选择", "Save templates & selection"),
    ("WPS.TemplateName", "模板名称", "Template name"),
    ("WPS.ReadonlyHint",
     "内置模板只读，点击“复制为新模板”后可修改。必须保留动态变量；派活、验收等节点还需保留原 JSON 字段结构，正文节点保持仅输出正文的要求。",
     "Built-in templates are read-only — click \u201cDuplicate as new template\u201d to edit one. All dynamic variables "
     "must be kept; dispatch and acceptance nodes must also keep their original JSON field structure, and body-text "
     "nodes must still be required to output body text only."),
    ("WPS.VariablesRef", "动态变量参考（{0}）", "Dynamic variables ({0})"),
    ("WPS.BodyLabel", "Prompt 正文", "Prompt body"),
    ("WPS.UnsavedTitle", "有未保存的修改", "Unsaved changes"),
    ("WPS.UnsavedBody", "离开将放弃本节点尚未保存的编辑和模板选择。",
     "Leaving will discard the unsaved edits and template selection for this node."),
    ("WPS.ContinueEditing", "继续编辑", "Keep editing"),
    ("WPS.Discard", "放弃修改", "Discard changes"),
    ("WPS.Saved", "模板和当前选择已保存", "Templates and selection saved"),
    ("WPS.CustomName", "自定义模板 {0}", "Custom template {0}"),
    ("WPS.Err.Empty", "提示词不能为空", "The prompt cannot be empty"),
    ("WPS.Err.TooLong", "提示词不能超过 64000 字符",
     "The prompt cannot exceed 64000 characters"),
    ("WPS.Err.UnknownVars", "未知变量：{0}", "Unknown variables: {0}"),
    ("WPS.Err.MissingVars", "请保留动态变量：{0}", "Keep these dynamic variables: {0}"),
    ("WPS.Err.BrokenBraces", "变量括号不完整，请使用 {{变量名}}",
     "Unbalanced variable braces — use {{variableName}}"),
    ("WPS.Err.Duplicate", "模板名称和标识不能为空或重复",
     "Template names and IDs must not be empty or duplicated"),
    ("WPS.Err.ActiveMissing", "选中的模板不存在",
     "The selected template no longer exists"),
    # ---- 客座读者与 13B 高级审查员卡片 ----
    ("BRS.Title", "客座读者与 13B 高级审查员", "Guest Readers & 13B Senior Reviewer"),
    ("BRS.Intro",
     "7B 会读取客座意见，再向 13B 请教；13B 可认可 7B 或提出修订意见。平台与模型从已配置的供应商中下拉选择，拉到模型列表即可直接选用。",
     "The 7B reviewer reads the guest comments and then consults the 13B reviewer, which either approves the 7B "
     "review or proposes revisions. Pick the provider and model from the providers you have already configured — "
     "once a model list is fetched you can select models directly."),
    ("BRS.SeniorPlatform", "13B 审查员平台", "13B reviewer provider"),
    ("BRS.SeniorModel", "13B 审查员模型", "13B reviewer model"),
    ("BRS.GuestName", "读者称呼", "Reader name"),
    ("BRS.Platform", "平台", "Provider"),
    ("BRS.Model", "模型", "Model"),
    ("BRS.GuestTaste", "人类品味/关注点", "Human taste / focus"),
    ("BRS.PickPlatform", "选择已配置平台", "Choose a configured provider"),
    ("BRS.PlatformDefault", "（使用平台默认模型）", "(Use the provider's default model)"),
    ("BRS.Saved", "审查团队配置已保存", "Review team settings saved"),
    ("BRS.GuestDefaultName", "客座读者 {0}", "Guest reader {0}"),
    ("BRS.GuestDefaultTaste", "普通读者：关注可读性、节奏和情绪是否自然",
     "Ordinary reader: cares about readability, pacing and whether the emotions feel natural"),
    # ---- 项目概览的审查按钮 ----
    ("PO.AuditArchive", "审查并校准项目档案", "Audit & Calibrate Project Archive"),
    ("PO.ReviewBook", "7B 全书审查并改进", "7B Full-book Review & Improve"),
    ("PO.ViewReviewComments", "查看审查留言", "View Review Comments"),
    ("PO.AuditConsistentFmt", "项目与写作档案一致：{0} 条",
     "Project and writing archive are consistent: {0} entries"),
    ("PO.AuditCalibratedFmt", "档案校准完成：修正/移除 {0} 条，剩余异常 {1} 条",
     "Calibration complete: {0} fixed/removed, {1} anomalies remaining"),
    ("PO.NoChapters", "项目暂无章节正文", "This project has no chapter text yet"),
    ("PO.ReviewDialogBodyFmt",
     "将逐章读取 {0} 章正文、大纲和上下文。7B 先写审查留言，发现异常后交给 3B 改写并回写版本。",
     "Reads the text, outline and context of all {0} chapters one by one. The 7B reviewer writes the review comments "
     "first, and anything flagged as anomalous is handed to the 3B writer to rewrite and write back as a new version."),
    ("PO.Start", "开始", "Start"),
    ("PO.ReviewDoneFmt", "审查完成：已审查 {0} 章，3B 已改进 {1} 章。留言已保存。",
     "Review complete: {0} chapter(s) reviewed, {1} improved by 3B. Comments saved."),
    ("PO.ReviewComments", "7B 审查留言", "7B Review Comments"),
    ("PO.NoComments", "暂无留言，请先运行全书审查",
     "No comments yet — run the full-book review first"),
    ("PO.CommentBodyFmt", "{0}\n建议：{1}", "{0}\nSuggestion: {1}"),
    # ---- 顶部导航条 / 设置入口 ----
    ("Shell.Settings", "设置", "Settings"),
    ("Shell.MorePages", "更多页面", "More pages"),
    ("Shell.TL.Title", "时间线", "Timeline"),
    ("MAG.Running", "写作中，查看进度", "Writing — view progress"),
    ("MAG.Elapsed", "已用时", "Elapsed"),
    ("MAG.ElapsedHint", "思考型模型单步可能需要数分钟，请耐心等待；单次调用超时自动跳过",
     "A reasoning model may take several minutes per step — please be patient. "
     "A single call that times out is skipped automatically."),
    # ---- 章节正文 AI 面板 ----
    ("RAI.Rewrite", "重写", "Rewrite"),
    ("RAI.Polish", "润色", "Polish"),
    ("RAI.Expand", "扩写", "Expand"),
    ("RAI.Continue", "续写", "Continue"),
    ("RAI.Toggle", "AI 选节助手", "AI selection assistant"),
    ("RAI.NeedSelection", "请先在正文中选中一段文字，再使用 AI 操作",
     "Select some text in the body first, then use an AI action"),
    ("RAI.NoProvider",
     "没有可用的 AI 服务，请先到「AI 配置」注册并设置默认模型",
     "No AI service is available. Register a provider and set a default model in AI Configuration first."),
    ("RAI.RequireHint", "附加要求（可空），如：更凝练 / 加入雨景 / 对话多一点",
     "Extra requirement (optional), e.g. more concise / add a rain scene / more dialogue"),
    ("RAI.Copied", "已复制 AI 结果", "AI result copied"),
    ("RAI.CopyResult", "复制结果", "Copy result"),
    ("RAI.ResultTitle", "{0} 结果", "{0} result"),
    ("RAI.Result", "AI", "AI"),
    ("RAI.Original", "原文", "Original"),
    # ---- 导入导出 / 项目管理：EPUB ----
    ("IE.EpubPicking", "选择 EPUB 保存位置", "Choose where to save the EPUB"),
    ("IE.EpubExporting", "正在打包 EPUB 电子书…", "Packaging the EPUB e-book…"),
    ("IE.EpubDone", "EPUB 导出完成：{0} 章 → {1}",
     "EPUB export complete: {0} chapter(s) → {1}"),
    ("IE.EpubBtn", "导出 EPUB 电子书…", "Export EPUB e-book…"),
    ("PM.ExportEpub", "导出电子书", "Export e-book"),
    # ---- 章节 AI 状态同步 ----
    ("SYN.AIDoneFmt", "AI 抽取：更新 {0} 项（人物 {1} · 势力 {2} · 设定 {3} · 剧情 {4}）",
     "AI extraction: {0} update(s) (characters {1} · factions {2} · settings {3} · plot {4})"),
    # ---- 多智能体写作：阶段 / 动态矩阵 / 长条 ----
    ("MAG.Phase.Queued", "排队中", "Queued"),
    ("MAG.Phase.Planning", "组长派活", "Lead assigning work"),
    ("MAG.Phase.Writing", "写手成稿", "Writers drafting"),
    ("MAG.Phase.Accepting", "组长验收", "Lead reviewing"),
    ("MAG.Phase.Rework", "打回返工", "Sent back for rework"),
    ("MAG.Phase.LeaderFix", "组长补写", "Lead filling in"),
    ("MAG.Phase.Polishing", "拼接定稿", "Assembly & polish"),
    ("MAG.Phase.Done", "已完成", "Completed"),
    ("MAG.Phase.Failed", "失败", "Failed"),
    ("MAG.Starting", "正在启动多智能体协同写作…",
     "Starting multi-agent collaborative writing…"),
    ("MAG.UnexpectedErrorFmt", "生成过程出现未预期错误：{0}",
     "Unexpected error during generation: {0}"),
    ("MAG.WritingShort", "写作中", "Writing"),
    ("MAG.ConfigurePrompts", "配置各工艺节点 Prompt 模板",
     "Configure Prompt templates for process nodes"),
    ("MAG.Matrix.Title", "写作动态", "Writing Activity"),
    ("MAG.Matrix.RunningFmt", "写作中 · {0}", "Writing · {0}"),
    ("MAG.Matrix.DoneFmt", "写作结束 · {0}", "Writing finished · {0}"),
    ("MAG.Matrix.None", "当前没有进行中的写书任务。",
     "There is no book-writing task in progress."),
    ("MAG.Matrix.ElapsedFmt", "　·　已用时 {0}", " · Elapsed {0}"),
    ("MAG.Matrix.Hint", "章节规划完成后，此处将实时显示各团队的写作进度",
     "Once chapter planning finishes, each team's writing progress shows here in real time"),
    ("MAG.Matrix.Close", "关闭（后台继续）", "Close (keep running in background)"),
    ("MAG.Suffix.Done", "落库定稿", "Final draft saved"),
    ("MAG.Suffix.Draft", "草稿", "Draft"),
    ("MAG.Suffix.OutlineReady", "大纲就绪", "Outline ready"),
    ("Common.DurationMSFmt", "{0}分{1}秒", "{0}m {1}s"),
    ("Common.DurationSFmt", "{0}秒", "{0}s"),
    ("Common.CharCountFmt", "{0} 字", "{0} chars"),
    # ---- 章节正文 AI 面板（补充）----
    ("RAI.StaleSelection", "选区已改变，已丢弃过期结果，请重新处理。",
     "The selection changed, so the stale result was discarded — please run it again."),
    ("RAI.ValidationFailedFmt", "处理未通过校验，原文未修改：{0}",
     "Processing failed validation; the original text was not modified: {0}"),
    # ---- 导入导出：EPUB 缺省章名 ----
    ("IE.EpubChapterN", "第 {0} 章", "Chapter {0}"),
    # ---- AI 健康面板 ----
    ("AIH.AgentState.StatesValueFmt", "{0} / 10（1 组长 + 9 写手）",
     "{0} / 10 (1 lead + 9 writers)"),
    # ---- 设定补同步按钮 ----
    ("PSS.Title", "从已完成章节补同步设定", "Back-fill Settings from Completed Chapters"),
    ("PSS.Body",
     "将按卷章顺序读取已完成正文，调用 MainAgent 抽取人物与各类设定，"
     "新增有正文依据的档案并追加履历。会消耗模型调用；正文不会修改。"
     "失败项保留重试机会，已成功且未变化的章节跳过。请先启用 AI 状态抽取。",
     "Reads the completed chapter text in volume/chapter order, asks the MainAgent to extract characters and the "
     "various settings, creates archive entries that the text actually supports, and appends histories. This consumes "
     "model calls; the body text is never modified. Failed items can be retried, and chapters that already succeeded "
     "without changes are skipped. Enable AI state extraction first."),
    ("PSS.Start", "开始同步", "Start sync"),
    ("PSS.Reading", "正在读取章节…", "Reading chapters…"),
    ("PSS.AiDisabled", "请先到 AI 配置启用 AI 状态抽取",
     "Enable AI state extraction in AI Configuration first"),
    ("PSS.SyncingFmt", "同步《{0}》…", "Syncing \u201c{0}\u201d…"),
    ("PSS.DoneFmt", "同步完成：成功 {0} 章，跳过 {1} 章，失败 {2} 章。",
     "Sync complete: {0} succeeded, {1} skipped, {2} failed."),
    ("PSS.FailedFmt", "同步未完成：{0}", "Sync did not finish: {0}"),
    ("PSS.Running", "正在同步设定…", "Syncing settings…"),
    ("PSS.Button", "从已完成章节补同步人物与设定",
     "Back-fill characters & settings from completed chapters"),
    # ---- AI 配置页（内置引擎 / 端点）----
    ("AICfg.GpuFreeFmt", "{0} · 空闲 {1}GB", "{0} · {1}GB free"),
    ("AICfg.EngineStarted", "✅ 内置引擎已启动（/v1/server/status 可查能力与显存）",
     "✅ Built-in engine started (/v1/server/status reports capabilities and VRAM)"),
    ("AICfg.EngineLaunchFailedFmt", "启动失败：\n{0}", "Launch failed:\n{0}"),
    ("AICfg.NoDiagnostics", "无诊断信息", "No diagnostics available"),
    ("AICfg.Cuda13", "CUDA 13.2（新驱动推荐）",
     "CUDA 13.2 (recommended for new drivers)"),
    ("AICfg.Cuda12", "CUDA 12.9（兼容旧驱动）",
     "CUDA 12.9 (for older drivers)"),
    ("AICfg.FastDefault", "fast（默认）", "fast (default)"),
    ("AICfg.EndpointConfig", "端点配置（独立于上方当前端点）",
     "Endpoint profile (independent of the current endpoint above)"),
    ("AICfg.FollowCurrentEndpoint", "兼容旧配置：跟随当前端点（建议选择固定配置）",
     "Legacy config: follow the current endpoint (a fixed profile is recommended)"),
    ("AICfg.DeletedProfileFmt", "已删除配置：{0}", "Deleted profile: {0}"),
]


def esc(s: str) -> str:
    return (s.replace("\\", "\\\\").replace("'", "\\'").replace("$", r"\$")
            .replace("\n", "\\n"))


def main() -> None:
    with io.open(SRC, encoding="utf-8") as f:
        text = f.read()

    zh_start = text.index("const Map<String, String> zhStrings")
    en_start = text.index("const Map<String, String> enStrings")
    blocks = {
        "zh": text[zh_start:en_start],
        "en": text[en_start:],
    }

    added_zh = []
    added_en = []
    for key, zh, en in ENTRIES:
        if "'%s':" % key in blocks["zh"]:
            continue
        added_zh.append("  '%s': '%s'," % (esc(key), esc(zh)))
        added_en.append("  '%s': '%s'," % (esc(key), esc(en)))

    if not added_zh:
        print("无新增词条（全部已存在）")
        return

    def append_before_close(block: str, lines) -> str:
        idx = block.rindex("};")
        # 保留缩进，插到 `};` 之前
        return block[:idx] + "\n".join(lines) + "\n" + block[idx:]

    blocks["zh"] = append_before_close(blocks["zh"], added_zh)
    blocks["en"] = append_before_close(blocks["en"], added_en)

    out = (text[:zh_start] + blocks["zh"] + blocks["en"])
    with io.open(SRC, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("新增 %d 条词条 → %s" % (len(added_zh), SRC))


if __name__ == "__main__":
    main()
