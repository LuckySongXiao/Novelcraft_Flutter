# 后训练数据集格式范式 · Part II：State Tuning 专项

> 本文件是 `docs/RWKV后训练数据集格式范式-v1.0.md`（Part I：SFT/DPO）的**追加部分**。
> Part I 定义「25 个任务族 + 17 类负例 + 8 道质量闸」，**全部继续适用**；
> 本 Part II 只定义 State Tuning **额外**需要的东西，以及它与 Part I 的**冲突点**。
>
> 技术依据：RWKV 官方 PEFT 仓库 `JL-er/RWKV-PEFT`（`--peft state` / `--train_type state`）
> 与官方教程（含 VRAM 表、超参、数据重复规则、state 文件挂载方式）。
> 范式版本 `v1.0-StateTuning`，对应代码版本 `1.0.0+52`。

---

## S0. 为什么 State Tuning 对「写小说」可能更好

### S0.1 它到底是什么

RWKV 是纯 RNN，有一个**固定大小的 state**。State Tuning 微调的**不是权重，而是这个初始 state**
—— 官方原话是「相当于最彻底的 prompt tuning，甚至可以用于 alignment，因为迁移能力很强」。

产物是一个 `.pth` **state 文件**，可以：

- 用 `demo-state-merge.sh` 合并进基底模型，得到一个完整的微调模型；
- 或在 RWKV Runner / Ai00 里**单独挂载**（推荐用法）。

⚠ **挂载的 state 文件必须使用训练它的同款基底模型**，否则不生效。

### S0.2 与其它微调方式的客观对比

RTX 4090（24GB）+ 64GB RAM，BF16，`--strategy deepspeed_stage_1 --ctx_len 1024 --micro_bsz 1`：

| 模型 | 全量微调 | LoRA | **State Tuning** | 备注 |
|---|---|---|---|---|
| RWKV7-0.1B | — | 2.7 GB | **2.6 GB** | |
| RWKV7-0.4B | — | 3.4 GB | **3.1 GB** | |
| RWKV7-1.5B | — | 5.6 GB | **5.3 GB** | |
| RWKV7-3B | — | 8.8 GB | **8.2 GB** | |
| RWKV6-1.6B | OOM | 7.4 GB | **6.4 GB** | |
| RWKV6-3B | OOM | 12.1 GB | **9.4 GB** | |
| RWKV6-7B | OOM | 23.7 GB | **18.1 GB** | 7B 上 state tuning 比 LoRA 便宜 24% |

### S0.3 对写小说的四个真实好处

1. **最便宜**：7B 只要 18.1 GB 显存，是唯一能在单卡 4090 上跑 7B 的方案。
2. **可换「人格」而不换模型**：一个基底模型可以挂多个 state 文件
   （正文写手 / 分纲编剧 / 校对编辑 / 某本书的世界观），**按书切换**。
   这天然对应本项目的四级管线 —— 每一级可以各有一个 state。
3. **单轮优化，与管线同构**：本项目每一次模型调用都是**单轮、自包含**的任务
   （给里程碑 → 回 JSON；给细纲 → 回正文片），而官方明确说 state tuning 炼的
   「都是单轮问答」—— 正好对上。
4. **迁移能力强**：因为只动一个很小的偏置，基底模型的语言能力保留得更好。

### S0.4 ⚠ 三个必须先知道的风险

1. **学习率高到反常**：`lr_init = 1`（普通微调是 `1e-5`），`lr_final = 0.01`，
   `warmup_steps = 10`。这是官方建议值，但意味着**极易灾难性遗忘** ——
   必须配「基底保留回归集」（见 ST-G11）。
2. **官方建议 ctx 尽可能短（从 512 起）**：这与长文写作有直接张力。
   本项目必须改用 **infctx 无限上下文训练**
   （`--train_type infctx --chunk_ctx 512 --ctx_len 2048`），
   这是 RWKV-PEFT 官方支持的能力，也正好发挥 RWKV 恒定显存的优势。
3. **部署方式受限**：本项目线上走 RWKV **云端** `/v1/chat/completions`，
   那个端点上**无法挂载本地 state 文件**。所以 State Tuning 的产物要么
   `demo-state-merge.sh` 合进模型后**自托管**（RWKV Runner / Ai00 / rwkv.cpp），
   要么这条路暂时只用于实验。**这是选型前必须先定的决策点**（见 S9）。

---

## S1. State Tuning 与 Part I（SFT/DPO）的本质差异

| 维度 | Part I：SFT / DPO | Part II：State Tuning |
|---|---|---|
| 被训练的参数 | 全权重 / LoRA 增量 | **只有初始 state** |
| 产物 | 权重 | `.pth` state 文件 |
| state 与数据的关系 | 每条样本独立 | **整个数据集共享同一个 state** |
| 数据同质性要求 | 可异构（不同任务混一份） | **必须同质**：一个 state 只许一种输出形状/人格 |
| 输入多样性要求 | 中等 | **必须尽量大**（state 学的是「忽略输入的哪部分」） |
| 数据重复 | 1~3× | **10×**（`make_data.py <jsonl> 10 512`） |
| ctx_len | 可长（2k~8k） | 官方建议 **512 起，越短越好**；本项目改 infctx |
| 学习率 | 1e-5 | **1.0 → 0.01**（warmup 10） |
| 量化 | 可选 | `nf4` / `int8`（官方） |
| 推理 prompt | 与训练一致 | `User: xxx\n\nAssistant:`，**推荐单轮** |
| 解码参数 | 项目既有最严防重复 | 官方示例：temp 1.0 / top_p 0.3 / presence 0.3 / freq 0.3 / decay 0.996 |

> **最重要的一条**：state 只有一份、被所有样本共享。所以
> **「一个 state 能同时是正文写手和 JSON 规划器吗？」—— 不能，至少不能同时做得好。**
> 这决定了 S2 的 state 划分方式。

---

## S2. State Target（state 目标）划分

每个 state 必须能用一句话说清「**这个 state 让模型变成谁**」。说不出话的 state 不要建。

| ID | state 名 | 职责 | 对应 Part I 任务族 | 输出形状 | 建议优先级 |
|---|---|---|---|---|---|
| **ST-1** | `novelist_prose` | 正文写手 | D1/D2（单笔直书 / 分片续写） | `prose` | **P0** |
| **ST-2** | `outliner_struct` | 结构化规划 | A1/A2/B1/B2（里程碑与大纲） | `json_array` / `textLines` | **P0** |
| **ST-3** | `brief_contract` | 细纲 8 字段契约 | C1 | `textLines` | **P0** |
| **ST-4** | `copyeditor_patch` | 自查补丁 | C2 | `textLines` | P1 |
| **ST-5** | `book_world_<bookId>` | **单本书**的世界观与文风 | B/D（带本书设定） | `prose` | P1 |
| **ST-6** | `chapter_linker` | 跨章续写 + 伏笔义务 | D2 | `prose` | P2 |

**约束（硬性）**

- 每个 state **单独一份数据集、单独训练、单独一个 `.pth`**。禁止把两个 state 的样本混进一次训练。
- **ST-1 与 ST-5 都是 prose，但必须分开**：ST-1 是「通用正文手感」，ST-5 是「这一本书的设定与专有名词」。
  混在一起会得到一个「什么书都能写一点、但都不像」的平均人格。
- ST-6 若与 ST-1 分开训练，推理时要先挂 ST-6；若嫌切换麻烦，可以把 ST-6 **并进 ST-1**
  （此时 ST-1 的数据集要同时含「开篇片」与「续写片」两种 probe）。

---

## S3. 样本格式（State Tuning 专用外壳）

Part I 的 SFT 外壳不够用 —— State Tuning 需要额外三样东西：
**这条样本属于哪个 state**、**state 的同质性指纹**、以及**书级 state 的设定语料**。

`sft_state/*.jsonl` 每行一个对象：

```json
{
  "id": "ST-3-zh-000042",
  "state_target": "brief_contract",
  "sample_kind": "probe_target",
  "prompt": {
    "system": "（逐字复制运行时 system）",
    "user": "（逐字复制运行时 user）"
  },
  "completion": "标题：《潮声与灯塔》\n本章目标：…\n…",
  "priming": {
    "kind": "none",
    "world_corpus": "",
    "style_corpus": ""
  },
  "state_fingerprint": {
    "output_shape": "text_lines",
    "field_count": 8,
    "cjk_ratio": 0.98,
    "avg_length": 268,
    "persona": "分卷编剧",
    "pov": "第三人称限知",
    "tense": "过去时"
  },
  "meta": {
    "teacher": "qwen3.8-27b",
    "teacher_params": { "temperature": 0.6, "top_p": 0.9 },
    "template_version": "layered_pipeline_plan.dart@1.0.0+52",
    "generated_at": "2026-10-14T22:00:00+08:00",
    "difficulty": "medium",
    "attempt": 1
  },
  "quality": {
    "gates": ["G1","G2","G3","G4","G5","G6","G7","ST-G9","ST-G12"],
    "ngram_repeat": 0.0,
    "field_duplication": [],
    "foreshadow_in_range": true
  }
}
```

### S3.1 新增字段约束

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `state_target` | enum | ✔ | **必须**是 S2 表中的 ID。训练按此分组，一个 state 一次训练 |
| `sample_kind` | enum | ✔ | `probe_target`（参与训练）/ `baseline_guard`（只进回归集，不进 state 训练）/ `prime_only`（只做 priming 语料，不参与） |
| `priming.kind` | enum | ✔ | `none` / `world` / `style` / `world_style` |
| `priming.world_corpus` | string | ○ | 本书设定语料（ST-5 用），≤ 4000 字 |
| `priming.style_corpus` | string | ○ | 本书文风样本（ST-5 用），≤ 4000 字 |
| `state_fingerprint.*` | — | ✔ | **同质性指纹**，ST-G9 的判据来源 |

### S3.2 `state_fingerprint` 为什么是必需字段

state 是一份全局偏置，会被所有样本平均。**如果样本之间形状漂移，state 就学成一个四不像。**
指纹的作用是把「漂移」变成可度量的东西：

- `output_shape`：必须与 `state_target` 声明的形状**完全一致**（不一致直接 ST-G9 失败）。
- `field_count`：`textLines` 类必须恒等于 8；`json_array` 类记元素个数。
- `cjk_ratio` / `avg_length`：**方差必须小**（见 ST-G9 阈值）。
- `persona` / `pov` / `tense`：同一 state 内必须一致，是防「人称/时态漂移」的唯一手段。

---

## S4. 数据构造的特殊规则（与 Part I 冲突或新增的部分）

### S4.1 同质性（State Tuning 的第一约束）

一个 state 内：

- `output_shape` **全部相同**；
- `field_count` **全部相同**；
- `cjk_ratio` 的**极差 ≤ 0.10**；
- `avg_length` 的**中位数 ±30%** 为合格区间，区间外样本占比 ≤ 5%；
- `persona` / `pov` / `tense` **零分歧**。

> **反例（真实风险）**：把 600 字的片和 2200 字的片混进同一个 prose state，
> 训练后模型无论给什么 prompt 都只写 ~1400 字 —— 因为 state 只能偏一个数。

### S4.2 输入多样性（第二约束，与 S4.1 同等重要）

state 学到的是「**输入里哪部分该忽略**」。所以同一个 state 下：

- 覆盖 ≥ 12 种题材、≥ 200 个不同书种子；
- `prompt` 的结构（变量组合）必须多样：有/无 `worldContext`、有/无 `foreshadowBlock`、
  末章禁埋/可埋、`askChars` 取满区间；
- **严禁**让某个固定句子在所有 prompt 里出现（那会让 state 把该句子当成任务标志）。

### S4.3 10 倍重复的等价物

`make_data.py <jsonl> 10 512` 会把数据**重复 10 遍**再转 binidx。
⇒ **去重必须在「按 state 分组之后、按 state 内部」做**。若在全库层面去重，
罕见样本在 10× 重复后会被常见样本淹没；若不去重，同一条样本在同一 state 内
出现两次会形成「隐性加倍权重」。

### S4.4 ctx_len 对齐

`ctx_len` 官方建议从 **512** 起。样本超出 ctx 的部分会被截断/丢弃，
所以：**单条样本长度不得超过 ctx_len**（超长的 prose 片必须改用 infctx）。

本项目修正：prose 类 state 用
`--train_type infctx --chunk_ctx 512 --ctx_len 2048`
（分片训练、恒定显存），struct 类保持 `--ctx_len 512`。

### S4.5 单轮优先

不放多轮对话样本。官方明确说明「目前炼的都是单轮问答，所以它不会在多轮之间联系」。
多轮/跨章累积场景**改用本项目已有的云端 `/state/` 会话**（注意 +50 实测该路由
当前不可用于正文，见 Part I §11.7 与 HANDOFF）。

---

## S5. 训练配置模板

官方 `demo-state-tuning.sh` 的关键参数，**加粗**为本项目的偏离及理由。

| 参数 | 官方值 | 本项目 | 理由 |
|---|---|---|---|
| `--train_type` | `state` | `state`（prose 类改 `infctx`） | infctx 才能吃长正文片 |
| `--peft` | `state` | `state --op fla` | `fla` 在 bsz < 8 时省显存 |
| `--ctx_len` | 512 | 512（struct）/ **2048**（prose） | 官方教程原文 |
| `--chunk_ctx` | — | **512**（仅 infctx） | 必须 < ctx_len |
| `--micro_bsz` | 1 | 1 → 按显存增 | 官方建议从 1 开始 |
| `--lr_init` | **1** | 1 | 官方原文「非常高的学习率」 |
| `--lr_final` | **0.01** | 0.01 | 同上 |
| `--warmup_steps` | **10** | 10 | 同上 |
| `--epoch_steps` | 1000 | 1000 | 官方 |
| `--epoch_save` | 5 | 5 | 官方 |
| `--epoch_count` | 999999 | 999999 | 官方 |
| `--QUANT` | nf4 / int8 | **先不量化，验证后再开** | 量化掉精度会让「文风」这种细节先丢 |
| `--data_type` | binidx | binidx | `make_data.py` 产物 |
| `--vocab_size` | 65536 | 65536 | 官方 |
| `--dataload` | pad | pad | `pad` 才支持 bsz > 1 |
| `--strategy` | deepspeed_stage_1 | 同 | 官方推荐 |
| `--precision` | bf16 | bf16 | 官方 |
| `--my_testing` | x060（v6） | **按实际基底版本** | v5→x052 / v6→x060；RWKV-7 需先确认 |
| `n_layer` / `n_embd` | 0.1B=12/768、0.4B=24/1024、1.5B=24/2048、3B=32/2560、7B=32/4096 | 同上 | **7B = 32 / 4096** |

**数据准备命令（照抄官方）**

```bash
# <jsonl> = 按 state 分组后的单份文件；10 = 重复 10 遍；512 = ctx
python make_data.py novel.jsonl 10 512
```

**产出与使用**

```text
proj_dir/
  ├── <run>-state.pth      ← 训练出的 state 文件
  └── <run>.txt            ← 训练日志
```

- **挂载（推荐）**：RWKV Runner / Ai00 里单独挂 `<run>-state.pth`；
  ⚠ 必须配**训练时用的同款基底模型**。
- **合并**：`demo-state-merge.sh` 合进基底模型 → 得到完整模型 → 可自托管部署。

**推理 prompt 与解码（官方示例，本项目需实测修正）**

```text
User: <任务>\n\nAssistant:
```

官方示例解码参数：`temp 1.0 / top_p 0.3 / presence 0.3 / freq 0.3 / penalty_decay 0.996`。
⚠ 本项目正文链路用的是 +48 实测的最严防重复参数（decay 0.999 / freq 0.2 / dry 0.8 /
last_n 2048 / top_p 0.6 + temp 1.0）—— **两套要实测取其一，不要直接混**。

---

## S6. 质量闸（Part I 的 G1~G8 之外，State Tuning 新增 4 道）

Part I 的 G1~G8 **全部继续适用**，并且必须继续复用 `DatasetSpecValidator`
（`tools/dataset_spec_validator_selftest.dart`）执行。新增：

| 闸 | 名称 | 判据（确定性） |
|---|---|---|
| **ST-G9** | **同质性闸** | state 内 `output_shape` / `field_count` 零分歧；`cjk_ratio` 极差 ≤ 0.10；长度落在中位数 ±30% 外的占比 ≤ 5%；`persona`/`pov`/`tense` 零分歧 |
| **ST-G10** | **反塌缩闸** | 训练后抽样 50 条，长度标准差不得低于样本集的 50% —— 防 state 把所有输出压成同一长度 |
| **ST-G11** | **基底保留闸** | 挂载 state 后，模型仍须能完成 **state 职责之外**的普通指令（常识问答/普通改写）≥ 80% —— 防 `lr_init=1` 的灾难性遗忘 |
| **ST-G12** | **单轮闸** | 所有样本必须是单轮；不得出现 `User:` / `Assistant:` 成对结构 |

ST-G9 / ST-G12 可在**数据阶段**离线执行（已实现，见 S8）；
ST-G10 / ST-G11 必须**训练后**执行。

---

## S7. 规模与配比建议

state 可训练参数极小（一个初始 state 张量），所以**不需要 SFT 那种规模**，
但对**同质性**的要求高得多。

| state | 最少条数 | 建议条数 | 长度区间（中位数 ±30%） |
|---|---:|---:|---|
| ST-1 `novelist_prose` | 800 | 4,000 ~ 8,000 | 单片 1200~2000 字 |
| ST-2 `outliner_struct` | 400 | 1,500 ~ 3,000 | 每条 1~40 个元素 |
| ST-3 `brief_contract` | 600 | 2,000 ~ 4,000 | 每份 240~320 字 |
| ST-4 `copyeditor_patch` | 300 | 800 ~ 1,500 | 每份 2~4 个字段行 |
| ST-5 `book_world_<id>` | 400 | 1,000 ~ 2,000/书 | 同 ST-1，但专有名词必须一致 |
| ST-6 `chapter_linker` | 500 | 1,500 ~ 3,000 | 同 ST-1 |

> 与 Part I 的 SFT 规模（建议 40,000~60,000 条）相比小一个量级 —— 这不是省钱，
> 是 state tuning 的**信息瓶颈**本来就在那里：再多异构样本也进不去同一个 state。

---

## S8. 可执行部分

同 Part I 的纪律：**范式必须能跑**。

- 校验入口：`tools/dataset_spec_validator_selftest.dart`
- 新增自检：`ST 组`（同质性闸 ST-G9 / 单轮闸 ST-G12 的合成正负例）
- 用法不变：
  ```bash
  dart --disable-dart-dev tools/dataset_spec_validator_selftest.dart
  dart --disable-dart-dev tools/dataset_spec_validator_selftest.dart audit <案例目录>
  ```

---

## S9. 选型决策树（State Tuning vs Part I 的 SFT/DPO）

```text
要教的到底是什么？
├─ 知识与契约（"输出必须是 8 字段" / "JSON schema" / "伏笔章号不得越界"）
│    → 用 Part I 的 SFT（或 LoRA）。state 参数太少，装不下大量规则。
│
├─ 人格与文风（"像谁在写" / "这一本书的语感" / "不要写收尾语"）
│    → 用 State Tuning。这正是它的主场（官方称可用于 alignment）。
│
├─ 两者都要
│    → 先 SFT/LoRA 教契约，再 State Tuning 教人格（state 挂在 SFT 后的模型上）。
│
└─ 显存只有一张 4090 且要动 7B
     → 只能 State Tuning（18.1 GB；LoRA 23.7 GB；全量 OOM）。

部署约束（先定这个再动手）：
├─ 继续用 RWKV 云端 API        → 当前无法挂载 state 文件，此路暂不通
│                                 （除非对方支持挂载/合并后的模型）。
├─ 自托管（Runner / Ai00 / rwkv.cpp）→ 可挂载 .pth，State Tuning 完全可用
└─ 只想做实验对比               → 本地 merge 后离线评估即可
```

---

## S10. 诚实的未验证清单

1. **我没在本机训练过 State Tuning**（需要 Linux + CUDA，本机是 Windows 沙箱）。
   S5 的配置全部来自官方教程推导，**必须先小规模试跑验证**，不要直接上全量。
2. **RWKV-7 的 state tuning 参数可能与 RWKV-6 不同**（`n_layer/n_embd` 表是 v5/v6 的）。
   本项目线上是 `rwkv7-g1k-7.2b`，训练前必须先确认 RWKV-7 的 `n_layer` / `n_embd`。
3. **ST-G10 / ST-G11 没法在数据阶段验证**，必须等训练完。
4. **解码参数没实测**：官方示例（top_p 0.3）与本项目 +48 结论（top_p 0.6 + dry 0.8）
   对「抗复读」的处理方式不同，需要一轮真机对照。
5. **云端部署路径未通**：见 S9 的部署约束，这是选型的硬前提。
