# 依赖体检报告（E10 · 2026-10-30 · v2.24.0 批次）

> E10 三规则：①安全补丁立即升 ②核心链路依赖（dio/gpt_markdown）升级单独分支跑全量测试 ③Flutter SDK 滞后稳定版一个版本。
> 本报告 = `flutter pub outdated` 快照 + 逐项评估。**本批次只评估不动依赖**——任何升级单独开批次（含模拟器冒烟）。

## 一、直接依赖（24 项）

| 包 | 当前 | 可升 | 最新 | 评估 | 动作 |
|---|---|---|---|---|---|
| crypto | 3.0.7 | 3.0.8 | 3.0.8 | 补丁级（哈希工具，非安全敏感路径——仅 hash_text 工具用） | 低风险，随下批顺手升 |
| cupertino_icons | 1.0.9 | — | 2.0.0 | 大版本（图标字体），Material 主题下仅 iOS 风格图标占位 | **不升**（2.0 需验证图标渲染，收益≈0） |
| file_picker | 13.1.0 | 13.3.0 | 13.3.0 | 小版本（附件文件选取核心链路） | 单独批次升 + 附件全链路回归 |
| syncfusion_flutter_pdf | 35.1.41 | 35.1.42 | 35.1.42 | 补丁级（PDF 文本提取） | 低风险，随下批顺手升 |
| wakelock_plus | 1.8.0 | — | 1.8.2 | 可升被约束（resolvable=1.8.0，上游依赖锁） | **不升**（等约束方放开） |
| dio | 5.11.1 | — | 5.11.1 | **核心链路（SSE 流式）**，已是最新 | 持续关注 5.x→6.x 动向，升级单独批次 |
| gpt_markdown | 1.3.4 | — | 1.3.4 | **核心链路（消息渲染）**，已是最新 | 持续关注 |
| shared_preferences_android | 2.4.28（override） | — | 2.5.4 | **v2.3.6 白屏事故元凶，dependency_overrides 锁定** | **永不升**，除非：模拟器验证 2.5.x release 构建无 JNI 崩溃后解除锁（单独批次 + 冷启动冒烟） |
| 其余 17 项 | 最新 | — | — | dio/provider/sqflite/share_plus/image_picker 等全部最新 | 无动作 |

## 二、开发依赖（4 项）

| 包 | 当前 | 可升 | 评估 | 动作 |
|---|---|---|---|---|
| sqflite_common_ffi | 2.4.4 | 2.4.5 | 补丁级（测试 FFI） | 随下批顺手升 |
| flutter_lints | 6.0.0 | 最新 | 已最新 | 无动作 |
| flutter_test / flutter_launcher_icons | 随 SDK | — | 随 SDK | 无动作 |

## 三、传递依赖要点

- **sqlite3 3.5.2 → 3.8.0**（sqflite_common_ffi 底层）：✅ **已解锁并升级（2026-10-31 批次 U，v2.30.6）**——Flutter SDK 3.44.9 → 3.47.9（Dart 3.13.7）带来 meta 1.19.0，死锁链（sqlite3 3.8.0 → hooks ^2.2.0 → record_use ^1.0.0 → meta ^1.19.0）自然解开；FTS5 回归 47 例绿（I7 全文搜索/F7 截图记忆照旧）。
- **shared_preferences_foundation 2.5.7 → 2.6.1**：iOS 侧，Android 端无影响，随主包升级自然跟进。
- **test_api 0.7.11 → 0.7.15**：随 Flutter SDK 版本走，不手动动。

## 四、Flutter SDK

- ✅ **已升级 3.44.9 → 3.47.9（2026-10-31 批次 U，v2.30.6）**：升级前滞后稳定版 3 个 minor（超规则③容忍），升级后 Dart 3.13.7；全量 1188 测试绿 + 模拟器冷启动冒烟通过（顺带发现并修复承诺跟进占位 baseUrl 潜伏 bug）。SDK 仓库手动 checkout tag + 恢复 gradle 阿里云镜像改动（`flutter upgrade` 会覆盖本地镜像补丁，故走 git checkout）。

## 五、结论与排期

1. **本批次（v2.24.0）**：零依赖变更（F7 功能零新插件，符合白屏防控策略）。
2. **下批顺手项**（低风险补丁级）：crypto 3.0.8 / syncfusion_flutter_pdf 35.1.42 / sqflite_common_ffi 2.4.5——一条 `pub upgrade` + 全量测试即可。
3. **单独批次候选**（按优先级）：
   - ~~file_picker 13.3.0（附件核心链路 + 回归）~~ ✅ 已完成（2026-10-31 批次 T，v2.30.5，全量 1187 绿）
   - ~~sqlite3 3.8.0（FTS 回归）~~ ✅ 已完成（2026-10-31 批次 U，v2.30.6，SDK 升级解锁，FTS 47 绿）
   - ~~Flutter SDK 升级（若落后 3+ 版）~~ ✅ 已完成（2026-10-31 批次 U，v2.30.6，3.44.9 → 3.47.9）
   - shared_preferences_android 解锁评估（模拟器冒烟 2.5.x）
4. **永不升**：shared_preferences_android 2.5.x（白屏事故，锁死直至专项验证）。

## 六、体检机制落地

- 节奏：**季度一次**（下次 2027-01 底），发版前 `git diff pubspec.lock` 漂移检查照旧（发版脚本外人工步骤）。
- 触发式加检：任何依赖出现安全公告（pub.dev advisory / GitHub Dependabot）→ 不等季度立即评估。
