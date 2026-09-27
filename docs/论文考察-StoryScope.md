# 论文考察：StoryScope（arXiv:2604.03136v6）对 NovelCraft 的可取之处

**论文**：*StoryScope: Investigating idiosyncrasies in AI fiction*
Russell, Rajendhran, Pham, Iyyer, Wieting · 2026-04-03 提交 / v6 2026-08-10 · cs.CL

## 一、论文做了什么

三段式管线，把 61,608 篇小说（10,272 个提示词 × 人类 + 5 个 LLM 平行写作，每篇约 5,000 字）映射为每篇 **304 个话语层叙事特征**：

1. **模板抽取**（NarraBench）：按 10 个叙事维度（Agent/SocialNetwork/Event/Plot/Structure/Setting/Time/Revelation/Perspective/Style）从散文抽结构化 JSON（状态轨迹用箭头表示）
2. **跨来源成对比较**：同一提示词的 6 个版本两两对比，源身份匿名、展示顺序随机化
3. **特征发现**：10 个专家提示词按维度提出封闭式判别特征，3 次运行取并集去重

**核心结论**：
- **仅凭叙事特征（不含风格信号）即可 93.2% macro-F1 区分人/AI**，68.4% 六方归属；抹掉表面 AI 痕迹（em-dash、「delve」这类）后只掉 1.6 个百分点——**表面风格会被模型迭代消除，话语层结构差异才是持久的**
- 30 个核心特征保留 84.8% 的性能
- 模型指纹可分（人类 32 个指纹特征 vs Kimi 3 个）

## 二、论文实证的「AI 叙事五倾向」（对人/AI 检测贡献最大的核心特征）

| 维度 | AI 倾向 vs 人类 |
|---|---|
| 主题显式 | 77% 由叙述者明说主题/教训（人类 52%）；对话沦为哲理辩论（59% vs 34%） |
| 因果整洁 | 单线叙事 79% 无支线（人类 57%）；主角驱动结局 69% vs 46% |
| 时间线性 | 人类更多闪回/时间跳跃/非线性/延迟揭示 |
| 感官超写 | AI 过度描写身体与环境感官细节 |
| 和解模板 | 结局以内心释怀收束 47% vs 27%；人类容忍歧义/未决 |

## 三、对 NovelCraft 的可取之处（按落地优先级）

### P0 ✅ 已落地（本次提交）
1. **反 AI 味五戒注入写作链**：`lib/ai/utils/anti_ai_flavor.dart` 把五倾向固化为
   「禁令 + 出路」双段式指南，注入 WriterAgent 的 GenerateChapterContent /
   ContinueChapter / PolishText 三个 system prompt——批量生成的每一章天然
   携带结构级去味约束，成本 ≈ 200 tokens/章
2. **Editor 新增 `AiFlavorCheck` 能力**：五维 0-2 分 + 总评 0-10 + 去味建议的
   结构化审查（含无 AI 服务的本地回退占位）；可接进质量评分工作流做「超阈值返工」

### P1 建议（下批迭代）
- **章节结构模板抽取**：把论文 Stage1 的 NarraBench 十维模板 prompt 移植为
  「章节结构分析」任务（产物存 KV/章节元数据）。比全文对比便宜，可增强
  一致性检查与 ChapterSync AI 阶段（用模板字段做跨章对齐，替代全文比对）
- **ReaderAgent 评分表对齐**：把五维做成 Reader 反馈的结构化 JSON 字段
  （1-5 scale），供质量评分聚合

### P2 观察（记录不强推）
- **多 provider 混排反指纹**：论文证明各模型叙事指纹差异显著且稳定
  （Claude 克制平淡 / GPT 社交八卦+怀旧 / Gemini 结尾整洁+环境阴郁 /
  DeepSeek 信息前置）。RWKV 本地为主的用户不可行；云端多 provider 用户
  可选「按章轮换 provider」增加篇间多样性。暂不实现，PITFALLS 记录。
- **Divergence 指标**：论文用方差类指标衡量「叙事空间占据是否分散」；
  NovelCraft 的项目健康检查可加「跨章主题显式度方差」做长篇多样性监测

### 不可取（明确排除）
- 304 特征全量 + XGBoost + SHAP 的研究管线：嵌入式 Flutter 应用不适用；
  「30 核心特征」思想已按 5 条清单形式吸收
- Books3 语料相关部分（Ethics Statement 亦承认版权争议），与创作工具无关

## 四、一句话总结

**NovelCraft 过去对抗 AI 味主要靠采样参数（kRwkvAntiRepeatSampling 防复读），
这篇论文证明真正的 AI 味长在叙事结构层——五戒注入把「防复读」升级为
「防套路」，且零模型调用成本；AiFlavorCheck 则把论文的检测能力反转为
创作自检工具。**
