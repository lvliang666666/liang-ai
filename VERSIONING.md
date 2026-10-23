# Liang AI 版本管理规范

> 本文档是 Liang AI 项目的版本管理规范，所有版本提交、tag、发布均遵循本文约定。

# Liang AI 版本管理规范

> 本文档是 Liang AI 项目的版本管理规范，所有版本提交、tag、发布均遵循本文约定。

## 1. 当前版本

**当前版本：v2.6.0**（2026-10-23 发布）

v2.6.0 在 v2.5.0 基础上优化（分支「feat/swipe-improvements」合并，I2 验收反馈改进 → PATCH）：

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
