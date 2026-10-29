# Liang AI 版本管理规范

> 本文档是 Liang AI 项目的版本管理规范，所有版本提交、tag、发布均遵循本文约定。

# Liang AI 版本管理规范

> 本文档是 Liang AI 项目的版本管理规范，所有版本提交、tag、发布均遵循本文约定。

## 1. 当前版本

**当前版本：v2.13.0**（2026-10-29 发布）

v2.13.0 在 v2.12.0 基础上新增（feat/quick-wins-2 分支，roadmap T3+F4+I3 → MINOR）：

- **T3 Skill 分享码**：SkillParser 新增 toShareCode/fromShareCode（YAML front matter + 正文，与内置资产 .md 同构，往返一致）；Skill 管理页自定义 Skill 加「复制为分享码」按钮，搜索框旁加「从分享码导入」入口（粘贴弹窗解析入库，格式错误 Toast 提示）；SkillProvider.importFromShareCode
- **F4 智能路由规则版**：SmartRouter 纯函数规则引擎——max 触发词（深入/推理/证明/代码/为什么等 24 词）短路 → 短消息（≤12 字）且无工具意图走 low → 默认 high；附件消息直接 max；斜杠命令不判 low。设置页「对话参数」加开关（**默认关**，升级用户行为不变）；开启后每条消息发送时决策本轮 effort，优先级最高（覆盖 Skill 预设与会话手动档位）
- **I3 长按菜单升级**：user/assistant 气泡长按从锚点 showMenu 改为底部 action sheet（与 Skill 选择/附件面板统一形态）；assistant 菜单新增「重答」——regenerateFrom 删除该回答及其后全部消息，复用原 user 消息重新生成（前情摘要边界失效检查与编辑重发同规则）；流式中重答/引用隐藏
- 710 项测试全绿（新增 26：分享码 6 + 路由 8 + provider 集成 4 + action sheet UI 8）；flutter analyze 零 error/warning（52 条 info 持平）

### v2.12.0（2026-10-28）

v2.12.0 在 v2.11.3 基础上新增（feat/generation-status 分支，roadmap I10 → MINOR）：

- **动态思考计时**：ThinkingBlock 流式中内部 1s Timer 驱动「已思考 Ns」实时增长（思考静默期 provider 无事件，组件自计时保证不冻结）；完成态「已深度思考（用时 N 秒）」不变；流式→完成 Timer 停止
- **token/耗时角标**：assistant 气泡尾部小字「120 / 45 token · 8s」（k 缩写千级格式化）；老数据（null）不显示对应段，两段全缺整行不渲染；流式中不显示（收尾后才有准确值）
- **断流续传**：SSE 流未收到 [DONE] 即断 → 新增 SseInterrupted 事件（不再伪装 SseDone 掩盖截断）→ ChatProvider 落库部分内容 + lastRoundInterrupted；最后一条 assistant 气泡尾部「连接中断 · 点击续传」胶囊（onResume null 不显示、流式中不显示）；点击删除截断消息后复用原 user 消息重新发起（SSE 无法断点续传，语义为重跑最后一轮）
- **DB v14**：messages 加 thinking_seconds / generation_seconds 两列（onCreate + v13→v14 ALTER）
- **修复既有订阅泄漏**：finisher 在事件回调内置空 _subscription 导致 loop 的 cancel(null) no-op，广播流双消费（续传后内容翻倍）；现仅 loop 持有/取消订阅
- 684 项测试全绿（新增 21：provider 7 + UI 14）；flutter analyze 零 error/warning（51 条 info）

### v2.11.3（2026-10-28）

v2.11.3 在 v2.11.2 基础上修复（用户验收反馈 → PATCH）：

- **已 v13 库无 FTS 表时搜索静默失效**：v2.11.1 在无 FTS5 模块的真机上建出 v13 库（迁移探测失败 → FTS 表被跳过），装 v2.11.2 不再触发 onUpgrade → 探测只在迁移链里跑 → ftsAvailable 恒 null → ftsOrNull 误判可用 → MATCH 炸 "no such table: messages_fts" → 抽屉 catch 吞掉 → 搜索永远「没有找到」。修复两层：`_open` 打开已有库后 flag 仍 null 时补一次探测（覆盖已 v13 库升级路径）；`FtsService.searchMessages` FTS 路径捕获 no-such-table 降级 LIKE（纵深防御）
- 663 项测试全绿（新增 4 回归用例）；flutter analyze 零 error/warning（51 条 info）

### v2.11.2（2026-10-28）

v2.11.2 在 v2.11.1 基础上修复（用户验收反馈 → PATCH）：

- **搜索结果「会话」组置顶于「消息内容」组**：会话肯定比消息少，搜一个会话时原顺序（消息组在上）要往下滑很远才能看到会话——调整为会话标题命中组在上、FTS 消息命中组在下；新增分组顺序断言测试锁定定版
- 659 项测试全绿（新增 1 顺序断言）；flutter analyze 零 error/warning（51 条 info）

### v2.11.1（2026-10-28）

v2.11.1 在 v2.11.0 基础上修复（真机白屏事故 → PATCH）：

- **FTS5 可用性探测 + 优雅降级**：v2.11.0 真机白屏根因——Android 系统 SQLite 编译旗标只有 ENABLE_FTS3/FTS4 **没有 ENABLE_FTS5**（AOSP 源码取证），sqflite 真机用系统 SQLite，DB v13 迁移建 FTS5 虚表必抛 "no such module: fts5" → 迁移失败 → main() 挂死白屏。模拟器/桌面测试用 ffi 自带 SQLite（全模块编译）测不出该差异。修复：启动迁移先在临时探测表试建 FTS5，失败置 ftsAvailable=false 跳过建表——消息 CRUD 索引同步跳过、搜索全量走 LIKE 兜底（个人规模毫秒级，功能完整只是无索引加速），App 任何真机都能启动
- 658 项测试全绿（新增 4 降级用例）；flutter analyze 零 error/warning（51 条 info）

### v2.11.0（2026-10-28）

v2.11.0 在 v2.10.1 基础上新增（feat/fts-search 分支，roadmap F1+I7 → MINOR）：

- **F1 本地 FTS5 检索底座**（基建型投资）：SQLite FTS5 虚表 + 中文二元分词（bigram）——应用层把文本切成 2-gram 存入 unicode61 虚表，查询同法切分 AND 连接；单字查询走 LIKE 兜底；messages_fts_rowid 映射表维护 FTS rowid ↔ 消息 id；插入/更新/删除三路径触发器 + best-effort `_guarded` 同步（索引失败不阻塞主流程）；DB v13 无损迁移（存量消息首次搜索时懒建索引）
- **I7 全文搜索定位**（收尾）：抽屉搜索框接 FTS（300ms 防抖 → top20），「消息内容」命中组（会话名 + ±24 字缩略，命中词主色 TextSpan 加粗）置于「会话」标题命中组之上；点命中项 → 关抽屉 → 切会话（如需）→ `scrollToMessage` 定位（GlobalKey + ensureVisible，未构建消息按 listIndex 估算 jumpTo 后二次 ensureVisible）→ 气泡高亮 2s 渐隐（user 描边+光晕 / assistant 主色底+描边）；定位即暂停跟随，新消息不拽回底部
- 654 项测试全绿（新增 17：FTS 分词/索引同步/查询 11 + 抽屉搜索 UI 11 中 FTS 相关 + 定位 6）；flutter analyze 零 error/warning（51 条 info）

### v2.10.1（2026-10-27）

v2.10.1 在 v2.10.0 基础上修复（用户验收反馈 → PATCH）：

- **「回到最新」胶囊去掉 +N 未读数**：上滑回看时右下角胶囊只显示「↓ 回到最新」，不再显示「（+N）」估算未读条数（按 offset 估算本就不精确，且视觉噪音）；胶囊浮出/点击回底/跟随恢复逻辑不变
- 610 项测试全绿；flutter analyze 零 error/warning（44 条 info，与 v2.10.0 持平）

### v2.10.0（2026-10-27）

v2.10.0 在 v2.9.0 基础上新增（feat/edit-quote-pin 分支，roadmap I4+I5+I7 → MINOR）：

- **I4 编辑重发**（ChatGPT 式）：长按自己的气泡 → 「编辑重发」→ 输入条进入编辑态（上方「正在编辑」条显示原文预览 + × 取消），确认后截断该消息及其后全部消息并重新生成——「说错了」从心理负担变成一次轻点
- **截断删除**：deleteMessagesFrom 按 created_at 比较，同毫秒消息用 id 兜底（>= 含自身）；前情摘要边界消息被截断删除时摘要自动作废（DB + 内存），边界未受影响则保留
- **I5 引用追问**（豆包式）：长按助手气泡 → 「引用」→ 输入条上方浮出引用条（原文缩略 + × 取消），发送时以「【引用】原文\n\n新问题」前缀拼进消息正文——纯文本方案，模型自然读到上下文，零 API 改动；长会话「你上面第三点展开讲讲」的指代歧义消除
- **I7 会话置顶**（部分完成）：抽屉长按会话 → 「置顶/取消置顶」，置顶会话归入「置顶」组恒排时间分组之上，列表项显示图钉标记；DB v12 sessions.pinned 列（NOT NULL DEFAULT 0 无损迁移），排序规则 DB 查询与内存排序同源（pinned DESC, updated_at DESC）；全文搜索定位待后续批次
- 610 项测试全绿（新增 23：DB 迁移/截断/置顶 22 + provider 编辑重发 8 + 列表菜单回调 3 + 输入条编辑/引用态 7）；flutter analyze 零 error/warning（44 条 info，较基线 48 净减 4）

### v2.9.0（2026-10-26）

v2.9.0 在 v2.8.0 基础上新增（feat/context-compression 分支，roadmap F2 → MINOR）：

- **F2 分层上下文压缩**（超长会话根治）：会话 token 超水位线（名义 32k 的 75% = 24k）时，发送前自动把早期历史压缩成四段式「前情摘要」（关键事实/用户偏好/已做结论/未决事项，low 档低温生成），请求只带摘要 + 最近 6 轮原文——超长会话不再被网关拒绝，token 消耗同步下降
- **按轮压缩**（roadmap 暗坑对策）：压缩单元按「轮」不按「条」——user 消息开新轮，其后 assistant/tool 消息归属同轮，tool_calls 与 tool 结果永远成对保留或成对压缩，拆散会被 API 拒绝
- **钉住消息永不压缩**：长按助手消息 → 钉住，轮内任一消息钉住则整轮豁免；气泡显示图钉标记；边界锚定保留窗口首条，钉住轮消息 ID 记录在摘要 pinnedIds 清单，请求组装时按原顺序捞回原文
- **滚动合并**：已有摘要再次触发时对全量消息重新规划，旧摘要文本作为上下文合并成新摘要，边界前移不重复喂素材；压缩失败（网络/解析）静默跳过不影响正常聊天，下轮再试
- **设置开关**：「上下文自动压缩」（默认开）在设置 → 对话参数；备份 settings 段同步导出/导入（老备份缺字段不动当前值）
- **DB v11**：context_summaries 表（每会话一条，派生数据不进备份、restore 清空）+ messages.pinned 列，老库无损迁移
- 587 项测试全绿（新增 39：摘要服务 27——轮切分/水位门卫/压缩计划/滚动合并/钉住豁免/端到端含静默路径 + DB CRUD 4；压缩管线 9——水位触发/摘要注入/历史截断/滚动边界前移/钉住豁免/落盘恢复；DB 钉住 2；备份开关 1）；flutter analyze 零 error/warning

### v2.8.0（2026-10-26）

v2.8.0 在 v2.7.0 基础上新增（feat/custom-http-tools 分支，roadmap T1 → MINOR）：

- **T1 自定义 HTTP 工具**（差异化之王）：设置 → HTTP 工具里配置 URL/方法/请求头/参数模板/响应截取规则，把任意 HTTP API 注册为 Agent 工具被 loop 调用——公司内部接口、家里 NAS、路由器、自建服务，App 从「聊天工具」升维成「个人自动化中枢」
- **执行器**：{param} 占位符模板替换（URL 与请求体都支持，缺失参数原样保留让模型自查）→ dio 请求（15s 超时，非 2xx 转文本不炸 loop）→ responsePath 点路径截取（data.items.0.name，数组用数字下标）→ 响应截断（默认 4000 字符防撑爆上下文）
- **Skill 白名单统一纳管**：Skill 编辑器「可用工具」分组展示内置 + 自定义 HTTP 工具，toolNames 子集语义不变；启用开关（禁用 = 不进工具目录）
- **备份同步**：http_tools section 随备份导出/导入（老备份缺 section 不动当前数据）
- 548 项测试全绿（新增 42：模型 9 + DB 3 + 执行器 14 + 目录合并 4 + UI 11 + 备份 1）；flutter analyze 零 error/warning

### v2.7.0（2026-10-26）

v2.7.0 在 v2.6.3 基础上新增（feat/auto-memory 分支，roadmap M2 → MINOR）：

- **M2 自动记忆沉淀**（AI 视角 Top1）：会话切走/退出聊天态时后台自动跑「记忆提取」——强约束 JSON 提取 prompt（只提取用户明确表达的偏好/事实/背景）→ low 档低温请求 → 流式收集 → 解析（剥 markdown 围栏 + 大括号截取容错）→ **解析失败回喂重试一次**（roadmap 暗坑对策）→ 逐条交 MemoryService.save 入库，归一化去重/包含合并/否定守卫/容量压缩全部复用既有管线，重复提取无副作用
- **触发点**：会话切走（抽屉点别的会话）/ 退出聊天态（新对话）时后台 fire-and-forget，不阻塞切换动画；流式中跳过；网络失败/解析失败/无可提取一律静默返回 0（后台任务不打扰）
- **设置开关**：「自动记忆沉淀」（默认开）在设置 → 记忆管理面板顶部；备份 settings 段同步导出/导入（老备份缺字段不动当前值）；提取的记忆 sourceSkill 记录来源 Skill，记忆管理页可删可编辑
- 506 项测试全绿（新增 27：提取服务 23——shouldExtract 门卫/会话文本组装/JSON 解析容错/端到端含重试与静默路径；开关 3；备份 1）；flutter analyze 与基线逐条一致（0 新增）

### v2.6.3（2026-10-26）

v2.6.3 在 v2.6.2 基础上修正（fix/select-toolbar-v263 分支，真机验收反馈 → PATCH）：

- **工具条内「完成」不出现修复**（用户反馈"工具条内完成还是没有出现"）：根因是 Android 原生 TextSelectionToolbar 的溢出机制——按钮总宽超屏时放不下的收进 ⋮ 溢出菜单。v2.6.2 的按钮队列 = 复制/分享/全选 + 系统文本处理动作（国产 ROM 注入翻译等）+ 完成，完成排最后 = 第一个被挤出去。修复：工具条只放「复制」「完成」两项，任何屏幕都放得下；分享/全选与横滑复制、长按菜单功能重复，砍掉无损失
- **顶部「完成」胶囊常驻修复**（用户反馈"完成按钮还是会出现在助手气泡的最上方"）：根因是 `if (_selecting)` 无条件显示，缺选中态判断。修复：仅无选中内容时兜底显示；选中后隐藏（退出走跟手工具条），清除选区后复现兜底；退出选择模式时同步清选区状态
- 479 项测试全绿（新增 2：定制工具条只含复制+完成两项防溢出回归 + 顶部胶囊按选中态显隐回归）；flutter analyze 零 error/warning

### v2.6.2（2026-10-24）

v2.6.2 在 v2.6.1 基础上修正（fix/toggle-live-select-toolbar 分支，真机验收反馈 → PATCH）：

- **快捷操作开关即时生效**（用户反馈"开启状态切换后没有立马生效，杀掉重启才生效"）：根因是 SettingsService 不是 ChangeNotifier——setSwipeActions 写完偏好后没有任何通知，MessageBubble 的 context.watch 收不到重建信号。修复：SettingsService 继承 ChangeNotifier，setSwipeActions 落盘后 notifyListeners（同值幂等不通知）；main.dart 注册改 ChangeNotifierProvider
- **选择工具条跟手「完成」+ 批量复制**（用户反馈"完成按钮跟手，截取哪段就跟着在哪显示；或 copy 后自动关闭"）：SelectionArea 定制 contextMenuBuilder——默认项（复制/分享/全选）+「完成」内联进系统工具条，工具条锚定选区 = 天然跟手；复制项覆盖默认行为，**保留选区**支持连续多段批量复制（复制后 Toast 提示可继续选取）；顶部固定胶囊降级为未选中时的兜底退出。选中文本经 onSelectionChanged 回调实时记录（SelectableRegionState 无公开 getSelectedContent，回调是官方取值路径）
- 477 项测试全绿（新增 2：开关即时生效回归——切关立即失效/切开立即恢复 + notifyListeners 幂等断言；3 个测试文件 Provider → ChangeNotifierProvider——SettingsService 现为 Listenable，Provider debug 检查拒绝裸 Provider）；flutter analyze 零 error/warning

### v2.6.1（2026-10-23）

v2.6.1 在 v2.6.0 基础上修正（main 直接提交，真机验收反馈 → PATCH）：

- **横滑复制真机失效修复**（用户反馈"快捷操作开启之后，没效果"）：根因是手势竞技场 touchSlop 不对等——SwipeActionContainer 用 RawGestureDetector 注入方向锁识别器，而 RawGestureDetector 不像 GestureDetector 那样自动读 MediaQuery.gestureSettings，识别器退回 kTouchSlop=18px 判定；抽屉的 GestureDetector 用真机设备 slop（约 8px），slop 不对等时抽屉永远先认领竞技场，横滑复制在真机上死掉（模拟器/测试两者同为 18px，测不出来）。修复：识别器显式注入 `MediaQuery.maybeGestureSettingsOf(context)`，双方同 slop 公平竞争 + 命中派发子先于父 → 气泡识别器先越 slop 认领
- **「选择文字」豆包式重做**（用户反馈"不是变成纯文本，而是像豆包一样正常自然的直接截取文字"）：删除 SelectableText 切换 + 提示行方案，改为正文包 SelectionArea——GptMarkdown 渲染原样保留（段落是 Text/RichText，自动注册到 SelectionContainer），长按选中词、拖手柄扩选、系统工具条复制，与原生文本体验一致；顶栏只留「完成」退出胶囊；选择期间 SwipeActionContainer.enabled=false 且识别器干脆不注册（enabled=false 不再注册识别器，横滑完全让位）
- 475 项测试全绿（新增 2：选择模式 SelectionArea 断言 + 选择模式横滑退场/退出恢复；新增 1 真机回归：设备 slop 8px 下容器先认领抽屉不动；改 1：选择文字原地模式断言重写）；flutter analyze 零 error/warning

### v2.6.0（2026-10-23）

v2.6.0 在 v2.5.3 基础上新增（main 直接提交，用户验收反馈 → MINOR）：

- 设置页新增「快捷操作」tag（对话参数与备份之间）：SwitchListTile 开关「消息横滑快捷操作」+ 说明卡（共存规则/流式禁用/长按菜单），SettingsService 持久化（key `swipe_actions`，默认开 = 升级用户行为不变）；**开 = 助手左滑复制 + 用户右滑复制**（复用 v2.5.0 定版方案 57612e6 的方向配置），**关 = 无横滑动作**（长按复制保留）——MessageBubble watch SettingsService.swipeActions 接线 SwipeActionContainer.enabled
- 「选择文字」原地化（用户反馈"不要弹出个界面，没意义"）：删除 _showTextSelector 底部弹层，长按菜单点「选择文字」后正文在原气泡内切换为 SelectableText（顶部提示行 + 「完成」胶囊退出）；选择态是开关式而非常驻——SelectableText 的手势识别器会吃掉横滑，常驻会永久破坏横滑复制；MessageBubble Stateless → Stateful（持有 _selecting 状态）
- 用户气泡方向 rightToLeft → leftToRight（v2.5.0 方案：右滑复制）；助手气泡保持左滑复制 + v2.5.3 方向锁（右滑让位抽屉）
- 备份 settings 段新增 swipe_actions 字段（导出/导入往返一致）
- 473 项测试全绿（新增 1：快捷操作关=横滑禁用长按可用；改 2：用户消息右滑复制 / 选择文字原地模式断言）；flutter analyze 零 error/warning

### v2.5.3（2026-10-23）

v2.5.3 在 v2.5.2 基础上修正（main 直接提交，用户验收反馈 → PATCH）：

- 方向锁识别器 DirectionalDragGestureRecognizer：继承 HorizontalDragGestureRecognizer，覆写 hasSufficientGlobalDistanceToAccept——累计位移与配置方向相反时返回 false（识别器保持 possible 态不认领，竞技场让位其他竞争者），同方向按原逻辑判定；SwipeActionContainer 改用 RawGestureDetector 注入方向锁识别器（GestureDetector 不支持自定义识别器）
- 共存效果：气泡上**右滑恢复"开会话列表"抽屉**（方向锁弃权让位，v2.5.2 起因气泡横滑识别器不分方向抢赢竞技场而失效）、**左滑仍是复制**（双向左滑定版不变）；气泡外区域右滑开抽屉照旧
- 472 项测试全绿（新增 3：方向锁弃权/同向认领 + 抽屉共存右滑开抽屉/左滑复制）；flutter analyze 零 error/warning

### v2.5.2（2026-10-23）

v2.5.2 在 v2.5.1 基础上修正（分支「fix/swipe-direction-final」，用户验收反馈 → PATCH）：

- 助手消息滑动改回左滑（ef88a71）：v2.5.1 的方向反转（助手右滑）与右滑出会话列表的抽屉手势冲突——助手气泡靠左，抽屉起手区落在气泡上会误触横滑复制；定版**双向左滑**（助手左滑、用户左滑）
- 469 项测试全绿；flutter analyze 零 error/warning

### v2.5.1（2026-10-23）

v2.5.1 在 v2.5.0 基础上优化（分支「feat/swipe-improvements」合并，I2 验收反馈改进 → PATCH）：

- 横滑方向反转（36e781f，用户验收反馈）：助手消息右滑 / 用户消息左滑——气泡向屏幕中间滑、动作区在屏幕边缘侧露出，热区更大更顺手
- 长按助手气泡菜单改锚点式（36e781f）：showModalBottomSheet → showMenu（复用长按会话卡片菜单形态：锚定长按点 + 圆角 12 + 44 高项 + 边界内收），onLongPress → onLongPressStart 拿 globalPosition
- 菜单新增「选择文字」（36e781f）：底部 Sheet（DraggableScrollableSheet 0.4~0.9）展示纯文本 SelectableText，长按挑选局部片段用系统工具条复制——Markdown 渲染会拆散文字流，选择操作基于纯文本才完整
- 469 项测试全绿（新增 2：锚点菜单三项 / 选择文字 Sheet）；flutter analyze 零 error/warning

### v2.5.0（2026-10-23）

v2.5.0 在 v2.4.0 基础上新增（分支「feat/memory-curation-swipe」合并，新功能批次 → MINOR）：

- M1 记忆策展台（38bfae0 + 77f3ff5）：DB v9 memories 加 pinned 列（迁移链全步骤双条件 `oldVersion < N && newVersion >= N` 加固 + v9 步 PRAGMA table_info 列存在性守卫，跨多版本直升不炸）；MemoryService 置顶保护——注入置前带「（置顶）」标记且不占滚动名额、_enforceCapacity 只压缩未置顶、update 改写（trim/空内容守卫/updatedAt 刷新）；MemoryPanel 升级——tag 筛选 chips（全部 + 动态分类 FilterChip 行）、📌 置顶分组置顶渲染、每条置顶/编辑/删除三操作、_MemoryFormDialog 统一添加/编辑表单（内容 + 分类标签）；_genId 改 Random 6 字符后缀（Windows ~15ms 时钟粒度下批量写入 id 碰撞 → ConflictAlgorithm.replace 静默丢行的真 bug）
- I2 消息横滑快捷操作（57612e6）：SwipeActionContainer（Telegram/iOS Mail 式横滑容器）——Stack 动作区（Opacity=progress 淡入 + 图标微移）+ Transform.translate 气泡层，越阈 60% 松手即触发 onAction 并 200ms easeOutCubic 回弹，DragStartBehavior.down 消除起手死区，AnimationController 懒创建（规避测试 dispose 阶段 deactivated ancestor 断言）；MessageBubble 集成——用户消息右滑复制 / 助手消息左滑复制（与长按菜单同反馈：medium 震 + Toast），流式中禁用；用户气泡 SelectableText → Text + 长按直接复制——SelectableRegion 的 TapAndHorizontalDragGestureRecognizer（eagerVictoryOnDrag=true）会抢赢手势竞技场，横滑在文字上起手永远无法触发，测试暴露的真机必现产品 bug
- 467 项测试全绿（新增 25：M1 服务层 9 + DB 迁移 2 + 面板 7 + I2 组件 5 + 集成 3）；flutter analyze 零 error/warning

### v2.4.0（2026-10-23）

v2.4.0 在 v2.3.8 基础上新增（分支「feat/home-split」合并，结构性重构 + 新功能 → MINOR）：

- E3 home_page 拆分（0053044 + cce012a + 6a074fd + 5b68714 + f5cfb14）：2496 行单文件按「自包含程度从高到低」四步机械搬移到 lib/widgets/home/——①SkillPickerSheet + NewChatPresetSheet（弹窗组）②SessionDrawerPanel（抽屉）③ChatMessageList + MessageTimeLabel（消息列表，State 公开化 + scrollController 公开 getter）④HomeInputBar + HomeAttachmentPreview（输入栏，耦合最深最后拆）；每步全量测试绿后提交；home_page 只剩状态编排 + 布局骨架（875 行），底部 Tab/气泡全宽化等 UI 重构的前置就绪
- I1 流式智能跟随（9d87fb2）：滚动跟随逻辑从宿主内聚进 ChatMessageList——手指触摸列表即暂停自动跟随（拖拽中流式新内容不再拽回底部），滚离底部右下角浮出「↓ 回到最新（+N）」胶囊（未读条数估算 + 流式中呼吸点提示），点胶囊 300ms 平滑滚回并恢复跟随，手动滚回底部（60px 阈值）同样恢复；位置驱动单一事实源（_onScroll），build 期间不 setState（未读数变化 post-frame 提交）
- 442 项测试全绿（新增 7 项：I1 跟随态/滚离/触摸暂停/胶囊交互）；flutter analyze 零 error/warning

### v2.3.8（2026-10-23）

v2.3.8 在 v2.3.7 基础上新增（分支「feat/token-lens-backup」合并，新功能批次 → PATCH）：

- F3 Token 水位仪表盘（87411e7）：SseParser 新增 SseUsage 事件（usage 末帧解析，choices 空不再丢弃）+ 请求加 stream_options.include_usage（vLLM 标准参数）+ ChatMessage 加 prompt/completion token 列（DB v8 迁移，老数据 NULL 兼容）+ ChatProvider 捕获真实 usage、无 usage 时本地估算兜底（CJK ≈1 token/字，其他 ≈1/4 字符，图片定额 800）；工具轮 scheduleMicrotask 修复——vLLM 在 finish_reason=tool_calls 后同批发 usage 末帧，同步 complete 会让 loop 在 usage 投递前取消订阅（真实用量丢失）；输入栏 tags 行新增 token 标签（聊天态，格式化 1.2k）+ 用量详情 Sheet（统计卡累计/输入/输出 + 上下文水位条 vs 名义 32k + 按消息明细，流式中数字实时跳动）
- F5 上下文透视镜（87411e7）：ChatProvider.buildPayloadPreview() 复用 _buildApiMessages（Skill system prompt + 记忆注入 + 全部历史同源）；PayloadLensPage 整页（slideUpRoute）——头部元信息胶囊（模型/档位/温度/工具数/消息数/估算输入）+ 消息卡片列表（system/user/assistant/tool 角色徽章 + 内容预览，点开全文 Sheet，多模态显示 [图片] 占位）；入口在 Token 用量 Sheet 底部「查看完整请求 payload」
- E6 API Key 加固（87411e7）：flutter_secure_storage 11.x（9.x 与 share_plus 13 的 win32 依赖冲突，升 11 解决）；SecureKeyBridge 抽象 + SecureKeyStore 生产实现（单键 JSON map + 内存 cache）；DB providers.api_key 只存空串，Key 进系统安全存储（Android Keystore 加密）；migrateKeysToBridge 幂等迁移（先写安全存储成功再清 DB 明文，崩溃重跑收敛）；bridge 未注入时行为与 v2.3.7 完全一致（测试兼容）
- E1 备份/导出（87411e7）：BackupService——buildBackup（sessions+messages+skills+memories+providers+settings，schema:1）/ shareBackup（temp JSON + 系统分享面板）/ restore（schema 校验 + 事务内清空重灌 + 统计返回）；**API Key 永不进备份**（导出强制置空 + 导入双保险置空）；设置页新增「备份」tab：导出分享 + 导入确认覆盖 + 主题应用 + 四 Provider 全量刷新
- 435 项测试全绿（新增 48：SSE usage 6 + DB v8 3 + ChatProvider F3 6 + Token Sheet/PayloadLens 12 + E6 12 + E1 10）；flutter analyze 零 error/warning

### v2.3.7（2026-10-22）

v2.3.7 在 v2.3.6 基础上优化（分支「UI批次1」合并，UI 体验改进 → PATCH）：

- 代码块复制按钮内状态切换（bd15d2e）：点「复制」原地变绿色对勾「✓已复制」（#34C759），1500ms 自动还原；重复点击重新计时；不再弹底部条
- 全局 Toast 兜底（a4ba923）：新增 lib/widgets/app_toast.dart（Overlay 实现，非 SnackBar）——深色胶囊底部居中、不遮输入栏、不阻断点击、单例新替旧；淡入 200ms / 停留 2000ms / 淡出 150ms；17 处 SnackBar 全量迁移（消息气泡/输入栏/模型面板/记忆页/设置页/Skill 编辑页/主页）
- Skill 选择面板改标准 Bottom Sheet（bd15d2e）：新 lib/widgets/app_bottom_sheet.dart 统一骨架（showAppBottomSheet + SheetScaffold + SheetKeyboardInset）——顶部圆角 16、内容最大 60% 屏高、下拉关闭、遮罩 rgba(0,0,0,0.4)、250ms ease-out 滑入；搜索框固定顶部、键盘弹出自动滚回顶部、空状态「暂无可用 Skill」
- Skill 面板键盘适配修复（1f31fd7）：高度上限从 showModalBottomSheet.constraints（键盘 padding 外层）移到 SheetKeyboardInset 的 padding 内层 ConstrainedBox——键盘弹出时内容 = min(60%屏高, 屏高−键盘高) 不被挤占，面板整体平滑上移至键盘上沿、搜索框不贴键盘、列表保持完整可视；收起回落原位；极端高键盘内容自动收缩不溢出
- 387 项测试全绿（新增 7 项：SheetKeyboardInset 键盘适配布局回归）

### v2.3.6（2026-10-22）

v2.3.6 在 v2.3.5 基础上优化（分支「快赢批次」合并，测试根治 + 体验小改进 → PATCH）：

- E2 schema 测试根治（0f7c6ae）：DatabaseService 建表/迁移入口公开为 static，新增共享测试 fixture（test/helpers/test_db.dart）——测试库直接跑生产 onCreate/onUpgrade，11 个测试文件 41 处手写 CREATE TABLE 全部替换，根治测试 schema 与生产漂移（此前停在 v6 缺 memories 表）；新增 v1 老库逐版本迁移回归测试
- I11 触觉反馈三档词汇表（0f7c6ae）：Haptics 新增 heavy 档；删除会话/批量删除/清空记忆/删除 Skill 确认按钮改重震动（5 处），代码块与消息复制完成改中震动（2 处）
- I6 会话独立草稿（0f7c6ae + 112c866）：每个会话记住自己未发送的输入框内容，切走再切回静默恢复（无弹提示）；空闲态草稿防抖落盘；发送/删除会话同步清草稿；草稿 LRU 上限 20 条
- 380 项测试全绿（新增 10 项：迁移回归 2 + 草稿 8）

### v2.3.5（2026-10-21）

v2.3.5 在 v2.3.4 基础上优化（分支「流畅性2.0」合并，交互修复 → PATCH）：

- 抽屉滑出卡顿溯源修复（05337e3）：拖拽逐帧路径已轻量（v2.3.4 已修跟手），卡顿来自**主页大层被高频重绘源反复标脏**——①输入框光标每 500ms 闪烁重绘向上传播穿透缓存层，重录主页大层（含聊天列表 Markdown），拖拽期间周期性掉帧（主元凶）→ 输入栏包 RepaintBoundary 隔离；②流式打字机逐帧重绘聊天区同理 → _ChatArea 包 RepaintBoundary；③主页分支两层 Transform（translate+scale）产生两层 TransformLayer 逐帧多一次层矩阵更新与合成 → 合并进单个 Matrix4；④拖拽回调逐帧查 MediaQuery → 宽度缓存到 didChangeDependencies
- 370 项测试全绿

### v2.3.4（2026-10-21）

v2.3.4 在 v2.3.3 基础上优化（分支「操作流畅度」合并，交互修复 → PATCH）：

- 抽屉右滑跟手修复（c9922db）：**主根因**——`_onDragUpdate` 把 `primaryDelta`（逐帧增量）当绝对位移用，"起始进度 + delta"直接赋值导致进度每帧被重置回起手位置，抽屉完全不跟手、松手才靠甩动动画打开（体感"抖一下再滑"）；修复=累加语义 `_controller.value + delta/width`（Flutter 内置 Drawer 同款）。**次因**——默认 `DragStartBehavior.start` 吞掉竞技场裁决前约一个触摸容差（~18px）的位移形成起手死区；两处拖拽 GestureDetector 改 `DragStartBehavior.down`（位移从按下点起算）
- 新增 `GestureDrawerState.progress` 公开只读口（宿主/测试感知实时进度）
- 新增 gesture_drawer_test.dart 5 例：down 配置锁、跟手位移、逐帧累加回归锁、未过半回弹、打开态左滑关闭
- 370 项测试全绿（新增 5 项）

### v2.3.3（2026-10-21）

v2.3.3 在 v2.3.2 基础上优化（main 直接提交的体验修复批次，交互修复 → PATCH）：

- 抽屉右滑卡死修复（2683d9d）：拖拽回调按进度条件挂载会在拖拽中途销毁活跃 recognizer 中断手势（"有时候卡"根因）——回调改常驻挂载（打开态被面板/Scrim 遮挡不会误触发）；Scrim 常驻不条件挂载
- 切换会话卡顿感消除（157f097）：RepaintBoundary 移到 Transform 内侧（原包在外侧缓存失效，主页内容逐帧重绘）；主页/抽屉内容提升到 AnimatedBuilder child；点会话先等抽屉关闭动画走完再切；旧列表退场/新列表构建拆帧；历史消息不播入场动画
- 消息入场动画移除（3544bbf）：MessageAppear 组件删除，气泡直接出现（用户反馈观感不佳）
- 切换会话滑入过渡（14ebe5e）：旧内容保持显示 + 数据后台加载 + 就绪原子替换 + AnimatedSwitcher 右滑入淡入 240ms——无闪页无空档；ScrollController 每会话自持；ChatProvider.dispose 级联关闭 ApiService（修复每次切换泄漏 HttpClient）
- 365 项测试全绿（移除 MessageAppear 3 项）

### v2.3.2（2026-10-21）

v2.3.2 在 v2.3.1 基础上优化（分支「动效打磨」合并，交互动效优化 → PATCH）：

- 全局动效体系 10 项落地（克制风格：小幅位移 + 淡入淡出，easeOutCubic 主曲线）：
  - 消息入场：新消息淡入 + 8px 上滑（MessageAppear 组件，ValueKey 绑定防流式重建重播）**——v2.3.2 发布后补丁移除（用户反馈观感不佳，气泡直接出现）**
  - 按压反馈：卡片/按钮按下 0.98 缩放（PressableScale 组件，Listener 实现）
  - 页面转场：二级页统一轻推滑入 + 淡入（slideUpRoute，280ms/240ms）
  - 思考块/工具卡片展开：AnimatedCrossFade 统一 250ms easeOutCubic 三曲线
  - tags 胶囊切换：AnimatedContainer + AnimatedSwitcher 文字淡出下移过渡
  - 打字点呼吸：三点指示器透明度与缩放同相位（跳动高点最实、低点最虚）
  - 列表删除补位：会话卡片收缩淡出 200ms 后真删，其余卡片平滑上移补位（批量删除整体播离场）
  - 抽屉跟手：自研 GestureDrawer 替换内置 Drawer——拖多少走多少、快甩翻转（500px/s 阈值）、过半判定、Scrim 随进度加深、主页面左移+缩放层次感、剩余距离缩放时长
  - 打字机提速：40→70 字/秒，长回答不拖沓、短回答仍有打字感
- 368 项测试全绿（新增 3 项：MessageAppear 首播/不重播/key 变化重播）

### v2.3.1（2026-10-21）

v2.3.1 在 v2.3.0 基础上优化（分支「记忆滚动压缩」合并，记忆质量优化 → PATCH）：

- 近似去重：归一化（去空白/中英文标点/大小写）后精确匹配；包含合并（短边 ≥6 字保留信息更全的长边）；否定句守卫（「喜欢」≠「不喜欢」不合并）
- 满员滚动压缩：池超 200 条时最旧 40 条活跃记忆合并为一条「归档摘要」行（tag 标记，免 DB 迁移），替代原静默删最旧——信息不再丢失
- 归档行保护：永不二次压缩（摘要失真不累积）、不参与去重、不随关键词删除（防「忘掉X」连带删整段摘要）
- 注入渲染分层：活跃记忆在前占 20 名额，归档块置尾单独成段（低优先级参考）
- 来源溯源：memory_save 落库自动带当前 Skill 名（激活 sourceSkill 字段），记忆管理页显示「来自 X」
- 365 项测试全绿（新增 16 项：近似去重 8 + 归档保护 1 + 注入渲染 2 + 滚动压缩 3 + 归一化 2 + 来源溯源 2，既有回归）

### v2.3.0（2026-10-20）

v2.3.0 在 v2.2.0 基础上新增（分支「记忆系统」合并，跨会话长期记忆 → MINOR）：

- 长期记忆系统：AI 可跨会话跨 Skill 记住用户偏好/事实——DB v6→v7 memories 表（content/tag/source_skill/时间戳），全局共享记忆池
- 混合式注入：system prompt 自动注入最近 20 条记忆（每轮工具循环后刷新）+ memory_save/memory_search/memory_forget 三工具（内置工具 26→29）
- 记忆服务：内容去重（同内容更新时间戳）、容量上限 200 条淘汰最旧、注入文本生成
- 记忆管理页：设置页独立 tag「记忆管理」——搜索/单删/手动添加/清空确认/空态引导，全局共享说明
- 记忆即时刷新：服务层写库后广播变更信号（changeSignal），AI 存/删记忆后管理页列表即时同步，无需重启
- Skill 资产：default.md 加「长期记忆」行为准则（何时存/忘/检索），architect/tutor 工具白名单追加记忆工具
- 349 项测试全绿（新增 73 项：service 20 + 工具 13 + 注入 4 + 管理页 8 + 信号刷新 10 + 既有回归）

### v2.2.0（2026-10-20）

v2.2.0 在 v2.0.0 基础上新增（分支「工具扩容」合并，内置工具 3→26 → MINOR）：

- 实用工具 3→14：日期计算、单位换算（含市斤两中文别名）、进制转换（BigInt 大数）、数学函数（14 种带域检查）、随机数、随机抽取、掷骰/硬币、文本统计、UUID 生成、Base64 编解码、文本哈希（crypto）
- 玄学工具 14→26：公农历互转（1900-2100 数据表+闰月）、八字四柱（立春分界/五虎遁/五鼠遁/五行统计/纳音）、五行、生肖、黄历（建除十二神）、观音灵签（100 签）、塔罗（78 牌正逆位）、周公解梦（40+ 词条）、数字能量（81 数理）、姓名五格（康熙笔画）、铜钱摇卦（本卦变卦）、桃花（咸池三合局）
- 玄学设计原则：排盘只出事实数据，解读交给模型
- 工具文件按分类拆分（time/device/math/date/unit/random/text/mystic），builtin_tools.dart 改聚合入口
- 农历地基 lunar_data.dart 用真实锚点校准（2026-02-17 春节、2025 闰六月、2000-01-01 日柱戊午）

### v2.0.0（2026-10-20）

v2.0.0 在 v1.7.0 基础上新增（分支「模仿 DeepSeek UI 样式的大改」合并，UI 全面重做 → MAJOR）：

- 单页架构：主页即聊天页——发送首条消息时才创建会话并原地进入聊天态（无页面跳转），旧聊天页删除
- 主页极简化：时段问候语 + tags 行 + 输入框，历史对话与设置全部收进侧滑抽屉
- 抽屉升级：会话按时间分组（今天/7 天内/更早）+ 标题搜索 + 长按锚点菜单（重命名/删除/批量管理）+ 批量多选删除
- tags 行常驻：助手（显示具体 Skill emoji 图标）/ 模型 / 推理档位三胶囊，空闲态与聊天态共用，点击即切换
- 新对话预设弹窗：点新建先预选本次对话的助手与模型（含确认退出当前对话弹窗）
- 微信式消息时间戳：首条必显，之后与上一条间隔超 5 分钟才显示（今天时分/昨天/日期）
- 聚焦根治：键盘收起即自动退出聚焦，点弹层/切 tag 后不再回弹键盘，输入中保持聚焦可连续输入
- 输入框：默认单行（删占位提示词），内容多时自动扩展最多 5 行；恢复"+"附件按钮（拍照/相册/文件，空闲态附件随首条消息带入新会话）
- 新增 DeepSeek 蓝主题（#4D6BFE 品牌色，明暗两套）
- 修复：Minecraft 主题输入框双层边框（外层胶囊与内层边框叠加），直角主题只保留内层方块边框
- 修复：选图后附件预览条不即时渲染（需输入文字才出现）

### v1.7.0（2026-10-20）

v1.7.0 在 v1.6.0 基础上新增（分支「Skill 打包体系替代 Agent」合并）：

- Skill 打包体系：Skill = 系统提示词 + 工具子集 + 参数预设的组合包（类 GPTs），完全替代旧 Agent 体系（一套系统，无兼容层）
- 工具子集控制：每个 Skill 可声明允许模型调用的工具——不声明=全部可用、显式勾选=指定子集、全不勾=纯提示词无工具
- 数据库 v5→v6 迁移：新增 skills 表与会话绑定列，旧 Agent 数据（含绑定关系）无损平移为 Skill
- Skill 管理页：新建/编辑/删除自定义 Skill，内置 Skill 可复制后修改，编辑器带工具勾选区
- 整页编辑器改版：编辑器从小弹窗升级为整页布局（顶部 Tags 切换 基本信息/提示词/可用工具 三分区），提示词输入区扩大到整页，校验失败自动跳到出错分区
- 内置 Skill 幂等升级：每次启动以资产内容重写内置行，未来内置提示词/工具分配更新后老用户自动生效
- 修复：默认主题下聊天页 AppBar 文字白底白字看不清，改为跟随主题前景色

### v1.6.0（2026-10-19）

v1.6.0 在 v1.5.0 基础上新增（分支「Agent Harness 工具调用 + agentic loop」合并）：

- Agent 工具调用：模型可自主调用手机端工具——首批内置 3 个（当前时间/设备信息与电量/四则计算器），全部零权限零凭据
- Agentic 执行循环：模型发起工具调用后自动执行、把结果交回模型继续推理，最多 8 轮，超限强制总结收尾
- 工具调用折叠卡片：助手气泡内展示每次调用（执行中旋转展开、完成自动折叠、失败红色调），点击可看参数与结果详情
- 工具消息持久化：数据库 v4→v5，工具调用与结果随会话存档，杀 App 重进后卡片与上下文完整保留
- 流式协议升级：SSE 解析支持 tool_calls 分片累积（多工具并行交错），finish_reason=tool_calls 不再误判流结束
- 中途停止语义：工具执行或回答中途停止，已落库消息保留，不中断会话
- 修复：内置公司供应商档案漏声明工具调用能力，导致工具从未随请求发送（老用户升级后自动补写）

### v1.5.0（2026-10-19）

v1.5.0 在 v1.4.0 基础上新增（分支「Provider Profile 多供应商方言适配」合并）：

- 多供应商接入：设置页可添加/编辑/删除任意 OpenAI 兼容供应商（DeepSeek、GLM 等），API Key/模型/能力按供应商独立配置，凭据不再写死在代码里
- 会话级模型切换：聊天页 AppBar 可随时切换当前会话的供应商与模型（仿豆包），切换后该会话记住选择
- 方言自动适配：不同供应商的思考流字段（reasoning/reasoning_content）与推理档位参数（reasoning_effort）按供应商配置自动适配，无需改代码
- 能力驱动 UI：供应商声明支持视觉才显示附件按钮，声明支持思考才显示推理档位按钮
- 数据库 v3→v4 迁移：新增 providers 表与会话绑定列，老数据（含已存 API Key）自动迁移到内置供应商档案
- 修复：Minecraft 主题下聊天页 AppBar 的 Agent/模型文字绿色在深色背景上不清晰，改为白色

### v1.4.0（2026-10-18）

v1.4.0 在 v1.3.0 基础上改进（聊天体验修复 + 文件点开）：

- 修复：聊天页键盘乱弹出——发送消息后不再自动聚焦，打开任何弹层/图片查看器前自动收起键盘，键盘只在主动点输入框时出现
- 修复：模型思考时消息缩略图不停闪烁跳动（图片解码缓存化，流式刷新不再重复解码）
- 文件消息改为豆包式卡片：显示文件图标 + 文件名 + 类型，点击直接调系统应用打开原文件（PDF→阅读器等）
- 发送文件时原文件保存到应用沙箱，历史消息中的文件可随时点开（v1.3.0 的旧消息未存原文件，点击会提示）
- 输入栏重排（仿豆包）：思考模式按钮移到左侧并垂直居中，"+" 移到最右侧，聚焦或输入文字后 "+" 消失、出现发送键

### v1.3.0（2026-10-18）

v1.3.0 在 v1.2.0 基础上新增（分支「多模态」合并）：

- 新增多模态能力：发消息可附带图片（拍照/相册，最多 3 张）和文件（txt/md/pdf，最多 3 个）
- 图片自动压缩（长边 1024px、JPEG 质量 85），消息气泡显示缩略图，点击全屏查看（多图可左右滑动）
- 文件内容自动提取为文本发给模型：txt/md 直读，PDF 提取文本层（扫描版 PDF 会提示无法提取）
- 附件随消息持久化保存，历史消息中的图片/文件可随时回看
- 输入栏新增"+"按钮与附件预览条（可逐个移除），仅附件无文字也可发送

### v1.2.0（2026-10-18）

v1.2.0 在 v1.1.0 基础上新增（分支「Agent人格系统与文件导出」合并）：

- 新增 Agent 人格系统：新建对话可选不同人格的助手（架构师/文案/翻译等 6 个内置），对话风格随 Agent 切换
- Agent 管理页：可新建/编辑/删除自定义 Agent，内置 Agent 可复制一份修改
- 新建对话的 Agent 选择页：显示最近使用的 3 个 Agent，其余折叠可展开，支持搜索
- 消息可导出并分享：长按消息选格式（Markdown/HTML/纯文本），直接调起系统分享面板发送到 QQ、微信等
- 修复：冷启动时会话卡片的 Agent 图标不显示
- 修复：设置页 Agent 搜索框焦点残留导致键盘反复弹出

### v1.1.0（2026-10-17）

v1.1.0 在 v1.0.0 基础上新增（分支「第一批小bug修复」合并）：

- 聊天列表改为 reverse 底部锚定：进会话直达最新消息，发送/流式自动跟随
- 新对话增加确认弹窗，避免误触创建空会话
- 首页新增会话搜索框（点击才聚焦，返回不弹键盘）
- 会话卡片移除右侧菜单按钮，长按为唯一菜单入口
- 全局触感反馈规范（Haptics 工具类，所有按键轻微震动）
- 新对话按钮改圆形加大版（64px）
- 设置页改顶部可滑动 Tags 栏 + 分页切换（外观/API 配置/对话参数/说明）

### v1.0.0（2026-10-16）

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
| v2.6.2 | 2026-10-24 | 快捷操作开关即时生效（SettingsService 继承 ChangeNotifier + notifyListeners）+ 选择工具条跟手「完成」+ 批量复制（contextMenuBuilder 定制，复制保留选区） |
| v2.6.1 | 2026-10-23 | 真机反馈修复：横滑复制真机失效（RawGestureDetector 注入设备 gestureSettings，slop 对等后气泡先认领）+ 选择文字豆包式重做（SelectionArea 包 GptMarkdown，渲染保留 + 系统工具条） |
| v2.6.0 | 2026-10-23 | 快捷操作开关（设置页 tag，开=双向横滑复制/关=无横滑）+ 选择文字原地化（SelectableText，v2.6.1 已重做）+ 用户右滑复制定版 |
| v2.5.3 | 2026-10-23 | 方向锁识别器：反方向弃权让位抽屉，气泡上右滑开抽屉 + 左滑复制共存 |
| v2.5.2 | 2026-10-23 | 横滑复制双向定版（助手左滑 + 用户右滑）+ 长按菜单锚点式 |
| v2.5.0 | 2026-10-23 | 横滑快捷操作：SwipeActionContainer 动作区 + 越阈触发 + 回弹 |
| v2.3.6 | 2026-10-22 | 快赢批次：E2 schema 测试根治（共享 fixture 跑生产迁移链）+ I11 触觉三档（heavy 档 + 调用点校准）+ I6 会话独立草稿（切回静默恢复） |
| v2.3.5 | 2026-10-21 | 抽屉滑出卡顿溯源修复：隔离高频重绘源（光标闪烁/流式打字机包 RepaintBoundary）+ 主页两层 Transform 合并单 Matrix4 + 拖拽宽度缓存 |
| v2.3.4 | 2026-10-21 | 抽屉右滑跟手修复：拖拽增量累加（primaryDelta 逐帧增量语义修正）+ DragStartBehavior.down 消除起手死区 + 5 项手势回归测试 |
| v2.3.3 | 2026-10-21 | 抽屉/切换体验修复批次：右滑卡死修复 + 切换卡顿消除（RepaintBoundary 位置/builder 提升/时序拆帧）+ 消息入场动画移除 + 切换滑入过渡（旧内容保持+原子替换）+ HttpClient 泄漏修复 |
| v2.3.2 | 2026-10-21 | 动效打磨 10 项：消息入场/按压反馈/页面转场/思考块展开/标签切换/打字点呼吸/删除补位/抽屉跟手（自研 GestureDrawer）/打字机提速 |
| v2.3.1 | 2026-10-21 | 记忆滚动压缩：近似去重 + 满员归档（40 条→1 摘要行）+ 来源溯源 |
| v2.3.0 | 2026-10-20 | 长期记忆系统：memories 表 + 混合式注入 + 记忆三工具 + 管理页（DB v7） |
| v2.2.0 | 2026-10-20 | 内置工具扩容 3→26：实用 11 个（日期/单位/进制/函数/随机/文本/UUID/Base64/哈希）+ 玄学 12 个（农历/八字/黄历/灵签/塔罗/解梦等） |
| v2.0.0 | 2026-10-20 | 模仿 DeepSeek UI 大改：单页架构（主页即聊天页）+ 抽屉升级 + tags 常驻 + 聚焦根治 + DeepSeek 蓝主题 |
| v1.7.0 | 2026-10-20 | Skill 打包体系替代 Agent（DB v6）+ 整页编辑器改版 + 工具子集控制 |
| v1.6.0 | 2026-10-19 | Agent Harness：工具调用 + agentic loop + 折叠卡片 + DB v5 持久化 |
| v1.4.0 | 2026-10-18 | 聊天体验修复（键盘/缩略图闪烁）+ 豆包式文件卡片可点开 + 输入栏重排 |
| v1.3.0 | 2026-10-18 | 新增多模态：图片（拍照/相册≤3张）与文件（txt/md/pdf≤3个）上传，气泡缩略图与全屏查看 |
| v1.2.0 | 2026-10-18 | 新增 Agent 人格系统与消息导出分享，修复图标显示与焦点残留 |
| v1.1.0 | 2026-10-17 | 体验优化：底部锚定定位、新对话确认、会话搜索、全局触感反馈、设置页 Tags 分栏 |
| v1.0.0 | 2026-10-16 | 首个正式版本：完整聊天功能 + 会话管理 + 主题系统（默认/Minecraft） |
