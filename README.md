# NovelCraft

AI 小说创作管理系统 —— 从 C# WPF 桌面版整体移植到 Flutter，一套业务模型支撑 Windows / Android / Web 多端运行。

## 项目简介

NovelCraft 面向网文作者，提供从世界观设定、人物、势力、情节到章节正文的全流程管理，并内置多 Provider AI 创作引擎（本地 RWKV / RWKV 云端 / OpenAI 兼容接口等），支持双 Agent 协作改稿、分段长文改写、对话生成与项目健康检查。

## 核心特性

- **数据层**：Drift 27 张表 + 23 个 Repository，首启动自动写入「玄穹剑主」修仙模板示例数据（幂等 seeding）
- **AI 层**（纯 Dart，无平台依赖）：6 个 Provider、智能体（Agent）编排、记忆、工作流；RWKV 本地推理引擎（llama.cpp GGUF + State 复用 + 官方资源一键安装）与 RWKV 云端（rwkv_lightning_cuda 并发批量 API）
- **创作闭环**：边聊「关联章节」→ Agent 按意见改写/续写 → 原子回写正文（版本号递增、状态不变）；长文分段滚动改写（段数闸门防超限）；提问与改稿意图自动分流，防误覆盖
- **页面**：项目管理、20 个数据库实体页、10 个 JSON 体系页、AI 协作 / AI 配置 / 对话生成 / 项目健康检查等 14 个功能页
- **本地化**：中英双语全量词条（约 4000 key），3 套主题皮肤

## 环境要求

- Flutter 3.38.5 stable（Dart SDK 由 Flutter 自带）
- Windows 构建：Visual Studio 桌面开发工作负载
- Android 构建：Android SDK（`flutter config --android-sdk <路径>`），minSdk 24 / targetSdk 36
- 本地 RWKV 推理（可选）：llama.cpp 兼容 server + GGUF 模型（应用内支持一键下载安装）

## 构建与运行

```bash
flutter pub get
flutter run -d windows          # 桌面端调试
flutter build windows --release # Windows 便携版：build/windows/x64/runner/Release/
flutter build apk --release     # Android：build/app/outputs/flutter-apk/
flutter build web --release     # Web：build/web/
```

> **中文路径注意事项**：工程若位于含中文的目录下，Android/Web 构建会因 `impellerc.exe` 无法写入中文路径而失败。解决办法：`subst X: <工程绝对路径>` 映射一个纯英文盘符后在盘符根目录执行构建。

## 测试

```bash
flutter test                                  # 单元 + 组件测试（内存 KVStore，不碰真实数据）
flutter test integration_test/<file>.dart -d windows   # 集成测试
```

涉及 RWKV 云端真机的集成测试需注入凭据（不落仓库）：

```bash
flutter test integration_test/rwkv_cloud_live_test.dart -d windows \
  --dart-define=RWKV_CF_ID=<你的 Client Id> \
  --dart-define=RWKV_CF_SECRET=<你的 Client Secret>
```

## 文档

- [HANDOFF.md](HANDOFF.md) — 完整交接文档：架构、进度、验收方式与已知坑
- [PITFALLS.md](PITFALLS.md) — 踩坑记录与规避方案

## License

[MIT](LICENSE)
