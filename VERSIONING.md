# Liang AI 版本管理规范

> 本文档是 Liang AI 项目的版本管理规范，所有版本提交、tag、发布均遵循本文约定。

## 1. 当前版本

**当前版本：v1.0.0**（2026-10-16 发布）

v1.0.0 为项目首个正式版本，包含：

- 对接公司私有化大模型 API（OpenAI 兼容，glm5.1）
- 流式聊天 + Markdown 渲染 + 代码块高亮/复制
- 仿 DeepSeek 可折叠"深度思考"区域（reasoning 实时展示）
- 多会话管理（新建/重命名/删除/历史持久化）
- 推理深度三档切换（max/high/low）
- 设置页（API Key / Base URL / 模型名 / 温度）
- 可扩展主题系统（默认 Material 3 + Minecraft 像素风格）

## 2. 版本号规则（SemVer）

采用语义化版本：`主版本.次版本.修订号`（MAJOR.MINOR.PATCH）

| 位 | 何时递增 | 示例 |
|----|---------|------|
| 主版本 MAJOR | 不兼容的功能变更、数据结构破坏性迁移、UI 全面重做 | 1.0.0 → 2.0.0 |
| 次版本 MINOR | 向后兼容的新功能（新增主题、新增页面、新增设置项） | 1.0.0 → 1.1.0 |
| 修订号 PATCH | Bug 修复、样式微调、依赖升级、文档更新 | 1.0.0 → 1.0.1 |

规则：

- 版本号与 `pubspec.yaml` 中的 `version` 字段保持同步（如 `version: 1.0.0+1`，`+` 后为构建号，每次发版递增）
- 0.x 阶段（如 0.1.0）允许随时破坏性变更，不遵循上述约束

## 3. 提交信息规范（Conventional Commits）

格式：`<type>(<scope>): <subject>`

| type | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | Bug 修复 |
| `docs` | 仅文档变更 |
| `style` | 不影响代码含义的格式调整（空格、格式化） |
| `refactor` | 既非新增也非修复的代码变更 |
| `perf` | 性能优化 |
| `test` | 测试相关 |
| `chore` | 构建、依赖、配置等杂项 |
| `release` | 版本发布提交 |

示例：

```
feat(theme): 新增 Minecraft 像素风格主题
fix(chat): 进入聊天页自动定位到最新消息
release: 发布 v1.0.0
```

- subject 用中文或英文均可，一行以内，不加句号
- scope 可选，常用：`chat` / `sessions` / `settings` / `theme` / `api` / `db`

## 4. 分支策略（单人项目简化版）

- `main`：主分支，始终处于可构建、可发布状态，所有 tag 打在 main 上
- `feat/<名称>`：较大的新功能开发分支，完成后合回 main 并删除
- 小改动直接提交到 main，不强制开分支

## 5. Tag 与发布流程

Tag 命名：`v<版本号>`（如 `v1.0.0`、`v1.1.0`），打在 release 提交上。

发布一个新版本的步骤：

1. 确认 `flutter analyze` 零问题、`flutter test` 全部通过
2. 更新 `pubspec.yaml` 的 `version` 字段
3. 提交：`release: 发布 v<版本号>`
4. 打 tag：`git tag -a v<版本号> -m "发布 v<版本号>"`
5. 构建 APK：`flutter build apk --debug`（或 `--release`）
6. 将 APK 与 tag 对应归档

## 6. 历史版本记录

| 版本 | 日期 | 说明 |
|------|------|------|
| v1.0.0 | 2026-10-16 | 首个正式版本：完整聊天功能 + 会话管理 + 主题系统（默认/Minecraft） |
