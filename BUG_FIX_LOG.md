# BUG 修复记录

更新时间：2026-10-02

## 本轮修复

| 编号 | 现象 | 根因 | 修复与验证 |
|---|---|---|---|
| NC-20261002-01 | 章节结构化导出文件没有定稿正文 | `ChapterExportInput` 没有把正文传入 Markdown/JSON 渲染器 | 增加 `content` 字段，所有续写/多智能体调用方传入落库正文；`chapter_export_service_test.dart` 验证正文与过程数据均可回读 |
| NC-20261002-02 | 用户选择的导出文件名可能穿越到导出根目录之外 | 项目 ID、标题只做非法字符替换，未处理点段和相对路径 | 统一净化控制字符、首尾点、长度；文件树拒绝绝对路径和 `..`；`chapter_export_service_test.dart`、`project_folder_export_test.dart` 覆盖恶意输入 |
| NC-20261002-03 | 取消中的任务提前释放并发槽，依赖任务过早启动 | `cancel()` 从运行表移除任务并立即完成 Future，但实际 runner 仍在执行 | 改为只标记取消，在 runner 的 `finally` 中释放槽、完成依赖和记录结果；`task_queue_test.dart` 覆盖运行中取消与槽位复用 |
| NC-20261002-04 | RWKV SSE 流响应头到达后就释放并发额度 | `chatStream` 在 `send()` 返回后调用 `leaveInFlight`，正文尚未消费 | 将释放移动到完整流消费的 `finally`；`rwkv_batch_test.dart` 验证流未结束时额度仍占用 |
| NC-20261002-05 | SSE 合法的 `data:`（无空格）分块被丢弃 | 解析器只接受 `data: ` 前缀 | 接受规范允许的两种前缀，并保留 `[DONE]` 处理；对应 Provider 回归测试通过 |
| NC-20261002-06 | 模型在说明文字后返回 JSON 时解析失败 | 清洗器只识别整段 JSON，未从前导说明中提取配平的对象/数组 | 增加引号、转义和括号配平扫描；`output_sanitizer_test.dart` 覆盖说明文字、嵌套 JSON 和原文保护 |
| NC-20261002-07 | Semaphore 配置为 0 时所有请求永久等待 | 并发上限未做下限保护 | 将上限钳制为至少 1，并增加边界测试 |
| NC-20261002-08 | JSON 导入布尔/日期字段失真；章节恢复后丢失卷归属 | 导入只比较字符串 `true`，日期只接受一种类型，章节备份遗漏 `volumeId`；部分实体跨项目反查未过滤 | `_vBool`/日期解析兼容 JSON 原生类型；章节导出/恢复保留 `volumeId`；修炼等级与政治职位按所属体系过滤；全量测试通过 |
| NC-20261002-09 | 项目只能导出 Markdown/文本，无法直接生成电子书 | 没有 EPUB 打包链路 | 新增纯 Dart EPUB 3 服务（mimetype、OPF、导航、章节 XHTML、样式表），导入导出页增加 EPUB 按钮；`epub_export_service_test.dart` 解包验证结构、转义和正文 |
| NC-20261002-10 | 备份导入到另一个项目后主键冲突或父子关系悬空 | 导入器总是重新生成主键，却没有同步改写外键 | 新增两阶段 `ImportIdRemap`：先建立全量旧→新映射，再改写章节、人物关系、体系子实体等外键；`import_id_remapper_test.dart` 验证跨项目导入关系完整 |
| NC-20261002-11 | 并发探测的两个请求同时通过单许可闸门 | `waitForPermit` 和 `enterInFlight` 分离，多个异步调用可在入场前看到同一空槽 | `RwkvConcurrencyController` 增加 reservation 计数，将等待与许可预留原子化；回归测试验证 cap=1 不会越限 |

## 验证结果

- `flutter analyze --no-pub`：No issues found。
- `flutter test --no-pub`：355 项通过。
- `dart run tool/verify_model_fit.dart`：31/31 通过。
- `dart run tool/verify_output_sanitizer.dart`：19/19 通过。
- `dart run tool/verify_segment_rewrite.dart`：59/59 通过。
- `dart run tool/verify_session_archive.dart`：18/18 通过。
