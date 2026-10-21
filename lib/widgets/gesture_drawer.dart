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
/// - RepaintBoundary 包在 Transform **内侧**（缓存内容层）：拖拽/动画
///   每帧只更新变换矩阵与 Scrim 透明度，主页面/抽屉内容走缓存层合成
///   不重绘。boundary 包在变换外侧时，矩阵变化会把整个 boundary 子树
///   标脏，主页内容逐帧重绘（切换会话掉帧元凶之一）
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

  /// 抽屉宽度 = 屏宽 - 右侧留边
  double _drawerWidth(BuildContext context) =>
      MediaQuery.widthOf(context) - widget.edgeMargin;

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

  double? _dragStartProgress;

  void _onDragStart(DragStartDetails details) {
    _controller.stop();
    _dragStartProgress = _progress;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_dragStartProgress == null) return;
    final width = _drawerWidth(context);
    final delta = details.primaryDelta ?? 0;
    _controller.value =
        (_dragStartProgress! + delta / width).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    if (_dragStartProgress == null) return;
    _dragStartProgress = null;
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
    final width = _drawerWidth(context);
    // 主页/抽屉内容只构建一次（child 参数），动画每帧只重建
    // Transform/Scrim 这几个轻量包装节点，内容层不进 builder
    return AnimatedBuilder(
      animation: _controller,
      child: RepaintBoundary(child: widget.drawer),
      builder: (context, drawerChild) {
        final p = _progress;
        return Stack(
          children: [
            // 主页面：随抽屉打开轻微左移 + 缩放（层次感）。
            // 拖拽回调常驻：打开态被面板/Scrim 覆盖不会误触发；
            // 条件挂载会在拖拽中途销毁 recognizer 导致卡死（见类注释）。
            // RepaintBoundary 在 Transform 内侧：内容层缓存化，每帧
            // 只重算矩阵，不把主页子树标脏重绘
            Transform.translate(
              offset: Offset(-width * 0.12 * p, 0),
              child: Transform.scale(
                scale: 1 - 0.04 * p,
                child: RepaintBoundary(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: _onDragStart,
                    onHorizontalDragUpdate: _onDragUpdate,
                    onHorizontalDragEnd: _onDragEnd,
                    child: widget.child,
                  ),
                ),
              ),
            ),
            // Scrim：随进度加深，点击关闭。
            // 常驻不条件挂载（p=0 时全透明且不接收事件），
            // 避免拖拽开始/结束时插入移除节点引发子树重建
            Positioned.fill(
              child: IgnorePointer(
                ignoring: p < 0.05,
                child: GestureDetector(
                  onTap: close,
                  child: ColoredBox(
                    color: widget.scrimColor.withValues(alpha: 0.5 * p),
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
              child: Transform.translate(
                offset: Offset(-width * (1 - p), 0),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: _onDragStart,
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  child: drawerChild,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
