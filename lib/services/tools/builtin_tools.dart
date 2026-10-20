import '../tool_registry.dart';
import 'date_tools.dart';
import 'device_tools.dart';
import 'math_tools.dart';
import 'random_tools.dart';
import 'text_tools.dart';
import 'time_tools.dart';
import 'unit_tools.dart';

export 'date_tools.dart';
export 'device_tools.dart';
export 'math_tools.dart';
export 'random_tools.dart';
export 'text_tools.dart';
export 'time_tools.dart';
export 'unit_tools.dart';

/// 内置工具聚合入口（零权限零凭据）
///
/// 各工具按分类拆分在同目录文件中，此处仅聚合导出，
/// import 路径保持 `services/tools/builtin_tools.dart` 不变。
const builtinTools = <ToolHandler>[
  // 时间
  GetCurrentTimeTool(),
  DateCalcTool(),
  // 设备
  GetDeviceInfoTool(),
  // 计算
  CalculateTool(),
  UnitConvertTool(),
  BaseConvertTool(),
  MathFunctionTool(),
  // 随机
  RandomNumberTool(),
  RandomPickTool(),
  DiceFlipTool(),
  // 文本
  TextStatsTool(),
  UuidGenerateTool(),
  Base64CodecTool(),
  HashTextTool(),
];
