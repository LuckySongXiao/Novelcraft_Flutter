# rwkv_lightning_cuda 官方文档（离线快照）

来源：https://github.com/Alic-Li/rwkv_lightning_cuda

| 文件 | 原始路径 | 用途 |
|---|---|---|
| `http-api.zh-CN.md` | `docs/http-api.zh-CN.md` | 每个端点的 curl 示例（中文） |
| `rwkv_lightning_api_doc.md` | `rwkv_lightning_api_doc.md` | **完整接口参考**（英/中两半，含接口总览表、生成参数、并发模型、错误码） |
| `run.zh-CN.md` | `docs/run.zh-CN.md` | 服务端启动参数（`--model-path` / `--vocab-path` / `--chunk-load` / `--state-db-path` / `--enable-dynamic-loading`） |

⚠ 快照对应的是仓库 `main` 分支，**与线上部署 `api-7b.rwkvos.com`（1.3.0）存在版本差**：
`/v2/chat/completions`、`/big_batch/completions`、`/FIM/v1/batch-FIM`、`/openai/v1/chat/completions`
在线上均为 **404**。落地前请以 **PITFALLS §31** 的实测校准表为准。

相关实测结论见 `PITFALLS.md` §27（集成陷阱）、§30（云端 API 实测）、**§31（逐条校准）**。
