import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 手势跟手侧滑抽屉：手指拖多少走多少 + 松手速度/位置判断
///
/// 替换 Scaffold 内置 Drawer（其动画固定 246ms 不可配置）：
/// - 拖拽跟手：进度 = 拖动距离 / 抽屉宽度
/// - 松手判定：速度 > 甩动阈值 或 进度过半 → 开/关，否则回弹
/// - Scrim 遮罩随进度加深，点击关闭
/// - 内容宽度 = 屏宽 - [edgeMargin]（右侧留出主页面边缘）
///
/// 性能与稳定性要点：
/// - 拖拽回调**常驻**（不按进度条件挂载）——条件挂载会在拖拽中途把
///   GestureDetector 重建为无手势形态，进行中的 recognizer 被销毁，
///   拖拽当场中断（抽屉卡在微开状态的根因）。打开态主页面被
///   面板/Scrim 覆盖，回调天然不会触发，无需条件守卫
/// - dragStartBehavior 用 **down**（位移从按下点起算）：默认 start 会
///   吞掉竞技场裁决前的位移（约一个触摸容差），起手有死区、随后突然
///   追赶，体感"抖一下再滑、不跟手"
/// - RepaintBoundary 包在 Transform **内侧**（缓存内容层）：拖拽/动画
///   每帧只更新变换矩阵与 Scrim 透明度，主页面/抽屉内容走缓存层合成
///   不重绘。boundary 包在变换外侧时，矩阵变化会把整个 boundary 子树
///   标脏，主页内容逐帧重绘（切换会话掉帧元凶之一）
/// - **主页面只平移不缩放**（v2.31.2）：连续变化的 scale 会让字形缓存
///   按缩放系数逐帧 miss，文字密集层（Markdown 气泡）全屏逐帧重新
///   栅格化——拖拽掉帧的根因。平移量化后仍命中缓存，零重栅格化。
///   层次感由 Scrim 深度表达（DeepSeek/Material Drawer 同款取舍）
/// - 结构壳（Stack/GestureDetector/Positioned）静态化：三个
///   AnimatedBuilder 各包一个动画节点，每帧只重建 Transform/Opacity
///   轻量包装，不重建任何结构节点
/// - 主页/抽屉内容内部的高频重绘源（输入框光标闪烁、流式打字机）必须
///   再包 RepaintBoundary 隔离：否则光标每 500ms 重绘会向上传播到主页
///   大层，重录重栅格化整页画面——拖拽期间周期性掉帧（"滑出卡顿"）
/// - close() 返回动画完成 Future（被拖拽打断则永不完成，等待方需
///   超时兜底）：宿主可等抽屉关完再做重活（如切换会话的列表构建），
///   避免与关闭动画抢主线程
///
/// [drawer] 抽屉内容；[child] 主页面。
class GestureDrawer extends StatefulWidget {
  const GestureDrawer({
    super.key,
    required this.drawer,
    required this.child,
    this.edgeMargin = 40,
    this.scrimColor = Colors.black54,
  });

  final Widget drawer;
  final Widget child;
  final double edgeMargin;
  final Color scrimColor;

  @override
  State<GestureDrawer> createState() => GestureDrawerState();
}

/// 抽屉控制状态（open/close 由宿主持 GlobalKey 调用）
class GestureDrawerState extends State<GestureDrawer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 0, // 0 = 关闭，1 = 打开
  );

  /// 打开/关闭动画时长（按钮触发时用；拖拽松手时长按剩余距离算）
  static const _animateDuration = Duration(milliseconds: 260);

  /// 甩动速度阈值（px/s）：超过直接翻转到目标态
  static const _flingVelocity = 500.0;

  double get _progress => _controller.value;

  /// 当前开合进度（0 = 关闭，1 = 打开）。
  /// 公开只读口：宿主/测试可感知拖拽与动画的实时进度
  double get progress => _controller.value;

  /// 抽屉宽度 = 屏宽 - 右侧留边
  double _drawerWidth(BuildContext context) =>
      MediaQuery.widthOf(context) - widget.edgeMargin;

  /// 抽屉宽度缓存：didChangeDependencies 随 MediaQuery 刷新（旋转/分屏
  /// 自动跟进）。拖拽回调逐帧高频执行，缓存后不再在指针事件里反复
  /// 查 InheritedWidget（依赖注册也不该发生在 build 之外）
  double _width = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _width = _drawerWidth(context);
  }


  // ===== 外部触发（按钮） =====

  void open() {
    _controller.animateTo(1,
        duration: _animateDuration, curve: Curves.easeOutCubic);
  }

  /// 关闭抽屉并返回动画完成 Future。
  /// 拖拽中调用（stop 后）动画不会推进，Future 永不完成——
  /// 等待方必须加超时兜底，不能裸 await。
  Future<void> close() {
    return _controller.animateBack(0,
        duration: _animateDuration, curve: Curves.easeInCubic);
  }

  // ===== 拖拽手势 =====

  void _onDragStart(DragStartDetails details) {
    // 冻结进行中的开/关动画，从当前进度接管跟手
    _controller.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    // primaryDelta 是"距上次更新"的逐帧增量，必须**累加**到进度上
    // （Flutter 内置 Drawer 同款做法）。若写成"起始进度 + delta"直接
    // 赋值，进度每帧都被重置回起手附近——抽屉完全不跟手，松手才靠
    // 甩动动画打开（"抖一下再滑"的主根因）
    final delta = details.primaryDelta ?? 0;
    _controller.value = (_controller.value + delta / _width).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final p = _progress;

    // 速度优先：快甩直接翻转
    if (velocity > _flingVelocity) {
      _open();
      return;
    }
    if (velocity < -_flingVelocity) {
      _close();
      return;
    }
    // 无明显速度：过半判定
    p >= 0.5 ? _open() : _close();
  }

  void _open() => _controller.animateTo(
        1,
        duration: _scaledDuration(1 - _progress),
        curve: Curves.easeOutCubic,
      );

  void _close() => _controller.animateBack(
        0,
        duration: _scaledDuration(_progress),
        curve: Curves.easeInCubic,
      );

  /// 按剩余距离缩放时长（拖一半松手 → 动画只走一半时间）
  Duration _scaledDuration(double remaining) {
    final ms = (260 * remaining).round().clamp(80, 260);
    return Duration(milliseconds: ms);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = _width;
    // ===== 性能架构（v2.31.2 抽屉流畅度批次）=====
    // DeepSeek/Material Drawer 式「动画只动两个轻量层」：
    // - Stack/GestureDetector/Positioned 全部静态化（build 一次），
    //   AnimatedBuilder 只包三个动画节点，每帧不重建任何结构壳
    // - 主页面**只平移不缩放**：文字密集层连续 scale 会让字形缓存
    //   （glyph atlas）按缩放系数逐帧 miss，全屏文字逐帧重新栅格化
    //   ——拖拽掉帧的根因。层次感由 Scrim 深度表达
    // - RepaintBoundary 在 Transform 内侧：内容层缓存化，每帧只重算
    //   矩阵，不把主页/抽屉子树标脏重绘
    // - 拖拽回调常驻：条件挂载会在拖拽中途销毁 recognizer 导致卡死
    //   （打开态被面板/Scrim 覆盖，回调天然不触发，无需条件守卫）
    final homeLayer = RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // down：拖拽位移从按下点起算。默认 start 会把手势竞技场
        // 裁决前（约一个触摸容差 ~18px）的位移吞掉——起手先有
        // 一段抽屉不动的死区、随后突然追赶，体感即"抖一下再
        // 滑、不跟手"（右滑开抽屉的元凶）
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: widget.child,
      ),
    );
    final scrimLayer = IgnorePointer(
      child: GestureDetector(
        onTap: close,
        child: ColoredBox(color: widget.scrimColor),
      ),
    );
    final panelLayer = GestureDetector(
      behavior: HitTestBehavior.translucent,
      dragStartBehavior: DragStartBehavior.down, // 同上：消除起手死区
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: RepaintBoundary(child: widget.drawer),
    );
    return Stack(
      children: [
        // 主页面：随抽屉打开轻微左移（平移命中字形缓存，无重栅格化）
        AnimatedBuilder(
          animation: _controller,
          child: homeLayer,
          builder: (context, child) => Transform.translate(
            offset: Offset(-width * 0.12 * _progress, 0),
            child: child,
          ),
        ),
        // Scrim：随进度加深，点击关闭。常驻不条件挂载（p=0 全透明且
        // IgnorePointer 拦事件），避免拖拽开始/结束时插入移除节点。
        // Positioned 必须是 Stack 直接子级（ParentData 约束），
        // 动画包装放 Positioned 内侧
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _controller,
            child: scrimLayer,
            builder: (context, child) => IgnorePointer(
              ignoring: _progress < 0.05,
              child: Opacity(
                opacity: 0.5 * _progress,
                child: child,
              ),
            ),
          ),
        ),
        // 抽屉面板：跟手平移（-100% ~ 0），面板内水平拖拽也可关闭
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: width,
          child: AnimatedBuilder(
            animation: _controller,
            child: panelLayer,
            builder: (context, child) => Transform.translate(
              offset: Offset(-width * (1 - _progress), 0),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}
