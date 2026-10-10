# State Tuning 微调手册（远端 api-7b / api-3b）

把 `定向微调数据集/NovelCraft对齐微调数据集v2.3`（5462 条工艺对齐样本）通过
**RWKV state tuning** 注入远端 G1K 模型，产出可被推理服务直接加载的 state 张量。

训练在**远端 3×4090** 上执行；本目录提供数据构建、远端训练脚本与上传/验证工具。

---

## 0. 远端现状（2026-10-07 实测，不是推测）

直接用 `curl` 打远端得到的事实（无需 CF 凭据即可访问）：

| 项 | 实测结果 |
|---|---|
| `api-7b.rwkvos.com/v1/models` | `rwkv7-g1k-7.2b-20260930-ctx25600` ← 主编 |
| `api-3b.rwkvos.com/v1/models` | `rwkv7-g1k-2.9b-20260930-ctx25600` ← 写手 |
| `api_version` | `1.3` |
| `capabilities` | batch_completion / chat_messages / chunk_prefill / completion / concurrent_generation / metrics / pause_resume / session_cache / stop / stream / think_type / token_count |
| `/v1/server/status` 暴露的权重路径 | `/home/rwkv/rwkv-stack/weights/rwkv7-g1k-7.2b-20260930-ctx25600.pth` |
| **`/v1/state/list`** | **7b 与 3b 均 200 可用** —— 线上**已**开放 state 端点（此前担心的 404 不存在） |
| 7b 已有 state | **18 个**：`v13a-{s086…s688,fin}.pth` + `v13b-{同}.pth`，各 16.01 MiB / **32 个张量** |
| 3b 已有 state | 0 个 |

`32 个张量 × 16.01 MiB` 与 7.2B（n_layer=32、n_head=64、head_size=64、fp16）的
`blocks.N.att.time_state` 尺寸完全吻合，可确证那批 state 正是 7.2B 的 state tuning 产物。
**说明训练与上传链路此前已经跑通过一次。**

---

## 1. 先要建立的三个认知

1. **远端 HTTP API 没有训练端点。** 只有推理 + `/v1/state/{upload,list,delete}`。
   所以「对远端模型做微调」的正确形态是：
   **在 4090 上跑 `rwkv_state_tune` 产出 state → 上传 → 推理时带 `state_id`**。
2. **state tuning 不是全参微调。** 只训练 `blocks.N.att.time_state`，冻结其余全部权重，
   checkpoint **只含 state 张量**。它调的是「初始状态先验」，
   对**输出格式/风格/指令遵循对齐**有效，对「注入大量新知识」效果有限。
3. ⚠ **上传的 state 存在服务进程的本地临时目录，服务端重启即清理。**
   每次远端服务重启后都要重新上传，不要当成永久生效的权重。

---

## 2. ⚠ 两个实测踩到的坑（照抄会中招）

### 2.1 `Python-urllib` 的 User-Agent 会被 403

实测同一 URL：

| User-Agent | 结果 |
|---|---|
| `curl/8.9.1` | **200** |
| `Mozilla/5.0` | **200** |
| `novelcraft/1.0` | **200** |
| **`Python-urllib/3.13`** | **403 Forbidden** |

这是 Cloudflare 侧的机器人规则，**不是鉴权失败**。`upload_state.py` 已显式带上
`User-Agent: novelcraft-state-tuning/1.0`；自己写脚本时务必也覆盖 UA。

### 2.2 训练文本必须带 `User:` / `Assistant:` 角色标记

工程 state 链路（`lib/ai/rwkv/rwkv_cloud_state.dart` 的 `buildPrompt`）在推理时拼的是：

```
User: <prompt>\n\nAssistant: <生成内容>
```

而数据集原始样本是 `prompt` 直接拼 `completion`，**没有角色标记**。
若照原样训练，state 学到的上下文位置与推理时错位，实测症状是**输出崩坏**。

> 佐证：用远端已有的 `v13a-fin.pth` 做 A/B 对照 ——
> 带该 state 时输出 `</tool_call>` 复读、不成文；零初始化 state 反而结构完整。
> 这与「训练格式与推理格式不一致」的症状一致。

因此 `build_dataset.py` **默认 `--format chat`**，按上述模板重建训练文本。

---

## 3. 第 1 步：准备数据（本机已生成，可直接用）

```bash
cd <工程根>
python tools/state_tuning/build_dataset.py            # 默认 chat 格式
python tools/state_tuning/build_dataset.py --dry-run  # 只统计
```

产出在 `build/state_tuning/`：

| 文件 | 块数 | 估算 token | 归属 |
|---|---:|---:|---|
| `main72b.jsonl` | 2340 | ≈180 万 | **7.2B 主编**：主线/分卷/章节大纲、规划 JSON、验收 JSON、设定抽取、逐段润色、力量体系 |
| `writer29b.jsonl` | 8486 | ≈1235 万 | **2.9B 写手**：solo/分段/beam/团队正文、纠偏、续写、指令遵循 |
| `manifest.json` | — | — | 切块参数与统计，便于复现 |

**为什么要切块**：`rwkv_state_tune` 会在 `--ctx` 处**直接截断**样本。
数据集原始样本 p50 约 5044 字符（≈3150 token），若沿用官方示例的 `--ctx 512`，
**八成内容会被丢弃**。脚本按**段落边界**贪心打包成 ≤ 目标 token 的块，
使可用内容从约 280 万 token 提升到约 1400 万 token。

传到远端：

```bash
scp build/state_tuning/{main72b,writer29b}.jsonl user@host:./novelcraft_data/
```

---

## 4. 第 2 步：远端准备二进制与权重

- `rwkv_state_tune` 属 `Alic-Li/rwkv_lightning_cuda`，CUDA 构建默认开启
  （`RWKV7_STATE_TUNING=ON`）：

```bash
cd /path/to/rwkv_lightning_cuda
ls build/rwkv_state_tune        # 已存在就直接用
cmake -B build -DCMAKE_BUILD_TYPE=Release -DRWKV7_STATE_TUNING=ON
cmake --build build -j
```

- 权重直接用**线上那份**（同版本，保证 state 兼容）：
  `/home/rwkv/rwkv-stack/weights/rwkv7-g1k-{7.2b,2.9b}-20260930-ctx25600.pth`
  （训练只吃 `.pth` / `.rwkvq`；本机现存的 `*.gguf` 是推理格式，**不能训练**。）

---

## 5. 第 3 步：训练

本目录的 `train_remote.sh` 把两种规模都封好了：

```bash
./train_remote.sh check        # 环境自检（二进制/权重/数据是否就位）
SMOKE=1 ./train_remote.sh 72b  # 20 步小跑，先验显存
./train_remote.sh 72b          # 全量
./train_remote.sh 29b
./train_remote.sh all          # 两个都做
```

等价的原始命令（便于自行调参）：

```bash
# 7.2B 主编
./build/rwkv_state_tune \
  --model /home/rwkv/rwkv-stack/weights/rwkv7-g1k-7.2b-20260930-ctx25600.pth \
  --data ./novelcraft_data/main72b.jsonl --output ./state_out/state_out_72b \
  --ctx 1024 --chunk 256 --epochs 1 --max-steps 1200 \
  --lr 0.0005 --lr-final 0.0005 --warmup-steps 10 --save-every 200 --batch-size 4

# 2.9B 写手
./build/rwkv_state_tune \
  --model /home/rwkv/rwkv-stack/weights/rwkv7-g1k-2.9b-20260930-ctx25600.pth \
  --data ./novelcraft_data/writer29b.jsonl --output ./state_out/state_out_29b \
  --ctx 2048 --chunk 512 --epochs 1 --max-steps 3000 \
  --lr 0.0005 --lr-final 0.0005 --warmup-steps 10 --save-every 200 --batch-size 8
```

**参数依据与调法**

| 参数 | 依据 |
|---|---|
| `--ctx` | 必须与数据切块预算一致（7.2B=1024、2.9B=2048）。7.2B FP16 权重本身约 14.4GB，ctx 越大激活越吃显存，**OOM 先降 batch-size，再降 ctx**（降 ctx 后要同步用 `--ctx-main/--ctx-writer` 重新切数据） |
| `--chunk` | 取 `ctx/4`：checkpoint/recompute 长度与反向 state 梯度传播长度 |
| `--batch-size` | 每次优化器更新累积的样本数；7.2B 从 4 起、2.9B 从 8 起，OOM 减半 |
| `--lr / --lr-final` | 官方示例是常数 5e-4；state tuning 步数少，常数学习率更稳。loss 抖动可降到 2e-4 |
| `--max-steps` | 7.2B：2340÷4≈585 步/轮 → 1200 ≈ 2 轮；2.9B：8486÷8≈1061 步/轮 → 3000 ≈ 3 轮。**都只是起点，按 loss 曲线调** |
| `--save-every` | 200 步一个 checkpoint，方便挑中间结果做 A/B（已有那批就是每 86 步存一次） |

> 该实现「以正确性为先」，用 BF16 PTH 加载器 + FP16 运行时权重，**不支持 INT8 训练**。

---

## 6. 第 4 步：上传 + 验证

文件名即 `state_id`，两个模型不能重名：

```bash
mv ./state_out/state_out_72b/<最后一个>.pth ./novelcraft-g1k-72b-main-v1.pth
mv ./state_out/state_out_29b/<最后一个>.pth ./novelcraft-g1k-29b-writer-v1.pth

python tools/state_tuning/upload_state.py --endpoint 7b upload --file ./novelcraft-g1k-72b-main-v1.pth
python tools/state_tuning/upload_state.py --endpoint 3b upload --file ./novelcraft-g1k-29b-writer-v1.pth
```

A/B 验证（同一 prompt，一次带 state 一次不带 —— **这一步是验收关键，别跳**）：

```bash
python tools/state_tuning/upload_state.py --endpoint 7b list
python tools/state_tuning/upload_state.py --endpoint 7b chat --state-id novelcraft-g1k-72b-main-v1.pth
python tools/state_tuning/upload_state.py --endpoint 7b chat      # 对照组
```

判据：带 state 后更贴近 NovelCraft 的条目化大纲文风（分卷脉络、人物名单、结局方向齐全），
且**没有复读环、没有 `</tool_call>` 之类的畸形 token 串**（那正是现有 v13a/v13b 的症状）。

回滚：

```bash
python tools/state_tuning/upload_state.py --endpoint 7b delete --state-id novelcraft-g1k-72b-main-v1.pth
```

---

## 7. 第 5 步：让 NovelCraft 用上这个 state（尚未做）

`lib/ai/providers/rwkv_cloud_provider.dart` 目前不带 `state_id`。接入需要：

1. RWKV Cloud 配置里增加「微调 state」字段（持久化 `state_id`）；
2. 请求体或 `X-RWKV-State-Id` 请求头带上它；
3. ⚠ **带 `state_id` 的请求服务端默认改用不带思考前缀的经典 `User`/`Assistant` prompt**，
   而 NovelCraft 现在走的是带 `think_type` 的 chat 模板。接入时必须显式指定 `think_type`
   覆盖该行为，否则 prompt 模板突变、影响既有工艺效果。

这一步会改变写作链路行为，**建议训练与 A/B 验证都通过后再动客户端**。

---

## 8. 风险与未验证项（如实列出）

- **显存峰值未实测**：`--ctx 1024/2048` 来自「权重静态占用 + 官方示例更保守（512）」的推算，
  7.2B 仍可能 OOM，务必先 `SMOKE=1` 小跑。
- **效果上限未验证**：state tuning 调初始先验，对格式/风格对齐有效，对知识注入有限。
  若目标是让模型记住大量新设定，应改用 LoRA / 全参微调（另一套流程）。
- **state 不持久**：服务端重启即清理。
- **训练与推理的 prompt 模板必须继续对齐**：本次已按工程 `buildPrompt` 重建数据；
  若日后客户端改了 prompt 模板（例如启用 `think_type`），训练数据要同步重建。
- `evalD_contamination.jsonl`（24 条污染负样本）**不参与训练**，保留用于训练后的污染回归。
