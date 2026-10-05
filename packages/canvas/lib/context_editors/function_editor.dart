/// 函数图像上下文编辑器（Wave 3.6；多曲线管理增强）。
///
/// 依据《渲染引擎设计》§7.5 / §8.6 与《白板软件设计文档》§6「函数工具栏」实现：
/// - **表达式输入**：内置纯 Dart 递归下降编译器 [WbExpressionCompiler]，
///   支持 `+ - * / ^`、括号、一元正负、常量 `pi / e` 与常用单参函数
///   （sin / cos / tan / sqrt / abs / ln / log / exp 等），非法输入即时提示；
/// - **定义域**：可编辑 x 区间，采样点数固定（默认 240），采样由
///   [WbFunctionSampler] 完成，非有限值与断点（如 tan 渐近线）自动分段；
/// - **多曲线管理列表**：每项展示曲线颜色、表达式与可见性开关，支持添加
///   （默认表达式 `0.5 * x`，自动分配调色板颜色）、删除、点选后编辑表达式
///   与颜色并即时预览；
/// - **颜色样式**：每条曲线独立取色（[WbContextPalette.curveSwatches]），
///   可切换显隐；预览坐标轴按采样值域自适应。
///
/// 组件自包含（无 Provider / FFI 依赖），通过 [WbFunctionEditor.onChanged]
/// 上报最新场景；无第三方依赖，不依赖网络。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import 'context_editor_shell.dart';

// ---------------------------------------------------------------------------
// 表达式编译器
// ---------------------------------------------------------------------------

/// 已编译表达式求值函数（输入 x，返回 y）。
typedef WbEvalFn = double Function(double x);

/// 表达式编译器（递归下降；文法：expr → term (('+'|'-') term)*，
/// term → factor (('*'|'/') factor)*，factor → 一元正负 power，
/// power → primary ('^' factor)?，primary → 数字 / 常量 / 函数调用 / 括号）。
///
/// 编译失败返回 null（不抛异常给调用方），适合输入框实时校验场景。
abstract final class WbExpressionCompiler {
  /// 编译 [source]；语法错误或未知标识符时返回 null。
  static WbEvalFn? compile(String source) {
    if (source.trim().isEmpty) {
      return null;
    }
    try {
      return _Parser(source).parseAll();
    } on FormatException {
      return null;
    }
  }

  /// 表达式是否可编译。
  static bool isValid(String source) => compile(source) != null;
}

/// 单参数学函数表。
const Map<String, double Function(double)> _builtinFunctions =
    <String, double Function(double)>{
  'sin': math.sin,
  'cos': math.cos,
  'tan': math.tan,
  'asin': math.asin,
  'acos': math.acos,
  'atan': math.atan,
  'sinh': _sinh,
  'cosh': _cosh,
  'tanh': _tanh,
  'sqrt': math.sqrt,
  'abs': _abs,
  'ln': math.log,
  'log': _log10,
  'exp': math.exp,
  'floor': _floor,
  'ceil': _ceil,
  'round': _round,
  'sign': _sign,
};

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

double _cosh(double x) => (math.exp(x) + math.exp(-x)) / 2;

double _tanh(double x) {
  final double a = math.exp(x);
  final double b = math.exp(-x);
  return (a - b) / (a + b);
}

double _abs(double x) => x.abs();

double _log10(double x) => math.log(x) / math.ln10;

double _floor(double x) => x.floorToDouble();

double _ceil(double x) => x.ceilToDouble();

double _round(double x) => x.roundToDouble();

double _sign(double x) => x.sign;

/// 递归下降解析器（一次解析生成闭包组合的求值函数）。
class _Parser {
  _Parser(this._source);

  final String _source;
  int _pos = 0;

  WbEvalFn parseAll() {
    final WbEvalFn fn = _expression();
    _skipSpaces();
    if (_pos < _source.length) {
      throw const FormatException('存在未解析的输入');
    }
    return fn;
  }

  WbEvalFn _expression() {
    WbEvalFn fn = _term();
    while (true) {
      _skipSpaces();
      if (_match('+')) {
        final WbEvalFn lhs = fn;
        final WbEvalFn rhs = _term();
        fn = (double x) => lhs(x) + rhs(x);
      } else if (_match('-')) {
        final WbEvalFn lhs = fn;
        final WbEvalFn rhs = _term();
        fn = (double x) => lhs(x) - rhs(x);
      } else {
        return fn;
      }
    }
  }

  WbEvalFn _term() {
    WbEvalFn fn = _factor();
    while (true) {
      _skipSpaces();
      if (_match('*')) {
        final WbEvalFn lhs = fn;
        final WbEvalFn rhs = _factor();
        fn = (double x) => lhs(x) * rhs(x);
      } else if (_match('/')) {
        final WbEvalFn lhs = fn;
        final WbEvalFn rhs = _factor();
        fn = (double x) => lhs(x) / rhs(x);
      } else {
        return fn;
      }
    }
  }

  WbEvalFn _factor() {
    _skipSpaces();
    if (_match('-')) {
      final WbEvalFn inner = _factor();
      return (double x) => -inner(x);
    }
    if (_match('+')) {
      return _factor();
    }
    return _power();
  }

  WbEvalFn _power() {
    final WbEvalFn base = _primary();
    _skipSpaces();
    if (_match('^')) {
      final WbEvalFn exponent = _factor();
      return (double x) => math.pow(base(x), exponent(x)).toDouble();
    }
    return base;
  }

  WbEvalFn _primary() {
    _skipSpaces();
    if (_pos >= _source.length) {
      throw const FormatException('表达式意外结束');
    }
    final String ch = _source[_pos];
    if (_match('(')) {
      final WbEvalFn inner = _expression();
      _skipSpaces();
      if (!_match(')')) {
        throw const FormatException('缺少右括号');
      }
      return inner;
    }
    if (_isDigit(ch.codeUnitAt(0)) || ch == '.') {
      return _number();
    }
    if (_isLetter(ch.codeUnitAt(0))) {
      return _identifier();
    }
    throw FormatException('无法识别的字符 "$ch"');
  }

  WbEvalFn _number() {
    final int start = _pos;
    bool seenDot = false;
    while (_pos < _source.length) {
      final String ch = _source[_pos];
      if (_isDigit(ch.codeUnitAt(0))) {
        _pos++;
      } else if (ch == '.' && !seenDot) {
        seenDot = true;
        _pos++;
      } else {
        break;
      }
    }
    final String text = _source.substring(start, _pos);
    final double? value = double.tryParse(text);
    if (value == null) {
      throw FormatException('非法数字 "$text"');
    }
    return (double x) => value;
  }

  WbEvalFn _identifier() {
    final int start = _pos;
    while (_pos < _source.length &&
        _isLetter(_source.codeUnitAt(_pos))) {
      _pos++;
    }
    final String name = _source.substring(start, _pos);
    if (name == 'x') {
      return (double x) => x;
    }
    if (name == 'pi') {
      return (double x) => math.pi;
    }
    if (name == 'e') {
      return (double x) => math.e;
    }
    final double Function(double)? fn = _builtinFunctions[name];
    if (fn == null) {
      throw FormatException('未知标识符 "$name"');
    }
    _skipSpaces();
    if (!_match('(')) {
      throw FormatException('函数 "$name" 缺少参数括号');
    }
    final WbEvalFn argument = _expression();
    _skipSpaces();
    if (!_match(')')) {
      throw FormatException('函数 "$name" 缺少右括号');
    }
    return (double x) => fn(argument(x));
  }

  void _skipSpaces() {
    while (_pos < _source.length && _source[_pos] == ' ') {
      _pos++;
    }
  }

  bool _match(String ch) {
    _skipSpaces();
    if (_pos < _source.length && _source[_pos] == ch) {
      _pos++;
      return true;
    }
    return false;
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static bool _isLetter(int c) =>
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F;
}

// ---------------------------------------------------------------------------
// 不可变数据模型
// ---------------------------------------------------------------------------

/// 单条函数曲线（不可变）。
@immutable
class WbCurve {
  /// 创建曲线。
  const WbCurve({
    required this.id,
    required this.expression,
    required this.color,
    this.visible = true,
  });

  /// 曲线 id。
  final String id;

  /// 表达式源码（如 `sin(x) + 0.5 * x`）。
  final String expression;

  /// 曲线颜色。
  final Color color;

  /// 是否显示。
  final bool visible;

  /// 表达式是否可编译。
  bool get isValid => WbExpressionCompiler.isValid(expression);

  /// 复制并覆盖字段。
  WbCurve copyWith({String? id, String? expression, Color? color, bool? visible}) {
    return WbCurve(
      id: id ?? this.id,
      expression: expression ?? this.expression,
      color: color ?? this.color,
      visible: visible ?? this.visible,
    );
  }
}

/// 函数场景（不可变）：多条曲线 + 定义域 + 采样数。
@immutable
class WbFunctionScene {
  /// 创建场景。
  const WbFunctionScene({
    this.curves = const <WbCurve>[],
    this.domainMin = -6,
    this.domainMax = 6,
    this.samples = 240,
  });

  /// 演示用示例场景（两条曲线）。
  factory WbFunctionScene.sample() {
    return WbFunctionScene(
      curves: <WbCurve>[
        WbCurve(
          id: 'f1',
          expression: 'sin(x)',
          color: WbContextPalette.curveSwatches[0],
        ),
        WbCurve(
          id: 'f2',
          expression: '0.5 * x',
          color: WbContextPalette.curveSwatches[2],
        ),
      ],
    );
  }

  /// 曲线列表。
  final List<WbCurve> curves;

  /// 定义域左端。
  final double domainMin;

  /// 定义域右端。
  final double domainMax;

  /// 每条曲线采样点数（含端点）。
  final int samples;

  /// 定义域宽度（恒为正，防御反向输入）。
  double get domainSpan => (domainMax - domainMin).abs();

  /// 按 id 查找曲线（不存在返回 null）。
  WbCurve? curveById(String id) {
    for (final WbCurve curve in curves) {
      if (curve.id == id) {
        return curve;
      }
    }
    return null;
  }

  /// 无效表达式的曲线数量。
  int get invalidCount {
    int count = 0;
    for (final WbCurve curve in curves) {
      if (!curve.isValid) {
        count++;
      }
    }
    return count;
  }

  /// 下一条曲线的默认颜色。
  Color nextColor() =>
      WbContextPalette.curveSwatches[curves.length % WbContextPalette.curveSwatches.length];

  /// 插入或替换曲线（按 id 匹配；返回新场景）。
  WbFunctionScene upsertCurve(WbCurve curve) {
    final List<WbCurve> next = <WbCurve>[
      for (final WbCurve item in curves)
        if (item.id == curve.id) curve else item,
    ];
    if (!next.any((WbCurve item) => item.id == curve.id)) {
      next.add(curve);
    }
    return copyWith(curves: next);
  }

  /// 删除曲线（保留至少一条；不存在时返回自身）。
  WbFunctionScene removeCurve(String id) {
    if (curves.length <= 1) {
      return this;
    }
    final List<WbCurve> next = <WbCurve>[
      for (final WbCurve item in curves)
        if (item.id != id) item,
    ];
    if (next.length == curves.length) {
      return this;
    }
    return copyWith(curves: next);
  }

  /// 复制并覆盖字段。
  WbFunctionScene copyWith({
    List<WbCurve>? curves,
    double? domainMin,
    double? domainMax,
    int? samples,
  }) {
    return WbFunctionScene(
      curves: curves ?? this.curves,
      domainMin: domainMin ?? this.domainMin,
      domainMax: domainMax ?? this.domainMax,
      samples: samples ?? this.samples,
    );
  }
}

// ---------------------------------------------------------------------------
// 采样与几何
// ---------------------------------------------------------------------------

/// 数学坐标范围（预览区映射依据）。
@immutable
class WbFunctionRange {
  /// 创建范围。
  const WbFunctionRange({
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  /// x 最小值。
  final double minX;

  /// x 最大值。
  final double maxX;

  /// y 最小值。
  final double minY;

  /// y 最大值。
  final double maxY;

  /// x 跨度（恒为正）。
  double get width => maxX - minX;

  /// y 跨度（恒为正）。
  double get height => maxY - minY;
}

/// 单条曲线的分段折线（数学坐标；段在非有限值 / 大跳变处断开）。
@immutable
class WbFunctionPath {
  /// 创建路径。
  const WbFunctionPath({
    required this.curveId,
    required this.color,
    required this.segments,
  });

  /// 曲线 id。
  final String curveId;

  /// 曲线颜色。
  final Color color;

  /// 分段折线（每段至少两个点，且点按 x 递增）。
  final List<List<Offset>> segments;
}

/// 场景几何（采样结果：可视曲线路径 + 自适应范围）。
@immutable
class WbFunctionGeometry {
  /// 创建几何。
  const WbFunctionGeometry({required this.paths, required this.range});

  /// 曲线路径（仅包含可编译且可见的曲线）。
  final List<WbFunctionPath> paths;

  /// 坐标范围（x 取定义域，y 自适应并包含 0）。
  final WbFunctionRange range;
}

/// 采样器：把场景换算为绘制用几何（纯 Dart，无图形依赖）。
abstract final class WbFunctionSampler {
  /// 相邻采样点 y 跳变超过范围高度该比例时断开分段（避免渐近线连线）。
  static const double _jumpRatio = 0.8;

  /// 采样 [scene]，返回路径与自适应范围。
  static WbFunctionGeometry sample(WbFunctionScene scene) {
    final int steps = math.max(scene.samples, 2);
    final double minX = math.min(scene.domainMin, scene.domainMax);
    final double maxX = math.max(scene.domainMin, scene.domainMax);
    final double span = math.max(maxX - minX, 1e-6);

    final List<_SampledCurve> sampled = <_SampledCurve>[];
    double? yMin;
    double? yMax;
    for (final WbCurve curve in scene.curves) {
      if (!curve.visible) {
        continue;
      }
      final WbEvalFn? fn = WbExpressionCompiler.compile(curve.expression);
      if (fn == null) {
        continue;
      }
      final List<double?> values = <double?>[];
      for (int i = 0; i <= steps; i++) {
        final double x = minX + span * i / steps;
        final double y = fn(x);
        if (y.isFinite) {
          values.add(y);
          yMin = yMin == null ? y : math.min(yMin, y);
          yMax = yMax == null ? y : math.max(yMax, y);
        } else {
          values.add(null);
        }
      }
      sampled.add(_SampledCurve(curve: curve, values: values));
    }

    final WbFunctionRange range = _resolveRange(minX, maxX, yMin, yMax);
    final double jumpLimit = range.height * _jumpRatio;
    final List<WbFunctionPath> paths = <WbFunctionPath>[];
    for (final _SampledCurve item in sampled) {
      final List<List<Offset>> segments = <List<Offset>>[];
      List<Offset> current = <Offset>[];
      for (int i = 0; i < item.values.length; i++) {
        final double? y = item.values[i];
        if (y == null) {
          _flush(segments, current);
          current = <Offset>[];
          continue;
        }
        final double x = minX + span * i / steps;
        if (current.isNotEmpty &&
            (y - current.last.dy).abs() > jumpLimit) {
          _flush(segments, current);
          current = <Offset>[];
        }
        current.add(Offset(x, y));
      }
      _flush(segments, current);
      if (segments.isNotEmpty) {
        paths.add(
          WbFunctionPath(
            curveId: item.curve.id,
            color: item.curve.color,
            segments: segments,
          ),
        );
      }
    }
    return WbFunctionGeometry(paths: paths, range: range);
  }

  static void _flush(List<List<Offset>> segments, List<Offset> current) {
    if (current.length >= 2) {
      segments.add(List<Offset>.of(current));
    }
  }

  static WbFunctionRange _resolveRange(
    double minX,
    double maxX,
    double? yMin,
    double? yMax,
  ) {
    if (yMin == null || yMax == null) {
      return WbFunctionRange(minX: minX, maxX: maxX, minY: -1, maxY: 1);
    }
    double lo = math.min(yMin, 0);
    double hi = math.max(yMax, 0);
    double span = hi - lo;
    if (span < 1e-6) {
      lo -= 1;
      hi += 1;
      span = hi - lo;
    }
    final double pad = span * 0.08;
    return WbFunctionRange(
      minX: minX,
      maxX: maxX,
      minY: lo - pad,
      maxY: hi + pad,
    );
  }
}

/// 单条曲线的采样中间态。
class _SampledCurve {
  _SampledCurve({required this.curve, required this.values});

  final WbCurve curve;
  final List<double?> values;
}

// ---------------------------------------------------------------------------
// 编辑器组件
// ---------------------------------------------------------------------------

/// 新增曲线的默认表达式。
const String _newCurveExpression = '0.5 * x';

/// 函数图像上下文编辑器。
class WbFunctionEditor extends StatefulWidget {
  /// 创建编辑器。
  const WbFunctionEditor({
    super.key,
    this.initialScene,
    this.onChanged,
    this.onClose,
    this.width = WbContextMetrics.defaultWidth,
  });

  /// 初始场景（null 使用 [WbFunctionScene.sample]）。
  final WbFunctionScene? initialScene;

  /// 场景变更回调。
  final ValueChanged<WbFunctionScene>? onChanged;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 面板宽度。
  final double width;

  @override
  State<WbFunctionEditor> createState() => _WbFunctionEditorState();
}

class _WbFunctionEditorState extends State<WbFunctionEditor> {
  late WbFunctionScene _scene;
  late String _selectedId;
  final TextEditingController _exprController = TextEditingController();
  final TextEditingController _minController = TextEditingController();
  final TextEditingController _maxController = TextEditingController();
  int _idSeq = 0;

  @override
  void initState() {
    super.initState();
    _scene = widget.initialScene ?? WbFunctionScene.sample();
    _selectedId = _scene.curves.isEmpty ? '' : _scene.curves.first.id;
    _syncControllers();
    _idSeq = _scene.curves.length + 4;
  }

  @override
  void dispose() {
    _exprController.dispose();
    _minController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  WbCurve? get _activeCurve => _scene.curveById(_selectedId);

  void _syncControllers() {
    _exprController.text = _activeCurve?.expression ?? '';
    _minController.text = _formatNumber(_scene.domainMin);
    _maxController.text = _formatNumber(_scene.domainMax);
  }

  static String _formatNumber(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e9) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(2);
  }

  void _emit() => widget.onChanged?.call(_scene);

  void _apply(WbFunctionScene next) {
    setState(() => _scene = next);
    _emit();
  }

  void _select(String id) {
    setState(() {
      _selectedId = id;
      _exprController.text = _scene.curveById(id)?.expression ?? '';
    });
  }

  /// 新增曲线：默认表达式 `0.5 * x`，颜色自动取自调色板轮转。
  void _addCurve() {
    final String id = 'f${++_idSeq}';
    _apply(
      _scene.upsertCurve(
        WbCurve(
          id: id,
          expression: _newCurveExpression,
          color: _scene.nextColor(),
        ),
      ),
    );
    _select(id);
  }

  /// 删除指定曲线（列表内入口；仅剩一条时由场景守卫）。
  void _removeCurveById(String id) {
    final WbFunctionScene next = _scene.removeCurve(id);
    if (identical(next, _scene)) {
      return;
    }
    _apply(next);
    if (_selectedId == id) {
      _select(next.curves.first.id);
    }
  }

  /// 删除选中曲线（工具栏入口）。
  void _removeCurve() => _removeCurveById(_selectedId);

  /// 切换指定曲线显隐（列表内开关）。
  void _toggleVisibleById(String id) {
    final WbCurve? curve = _scene.curveById(id);
    if (curve == null) {
      return;
    }
    _apply(_scene.upsertCurve(curve.copyWith(visible: !curve.visible)));
  }

  /// 切换选中曲线显隐（工具栏入口）。
  void _toggleVisible() => _toggleVisibleById(_selectedId);

  void _setExpression(String value) {
    final WbCurve? active = _activeCurve;
    if (active == null) {
      return;
    }
    setState(() {
      _scene = _scene.upsertCurve(active.copyWith(expression: value));
    });
    _emit();
  }

  void _setColor(Color color) {
    final WbCurve? active = _activeCurve;
    if (active == null) {
      return;
    }
    _apply(_scene.upsertCurve(active.copyWith(color: color)));
  }

  void _applyDomain({double? min, double? max}) {
    double lo = _scene.domainMin;
    double hi = _scene.domainMax;
    if (min != null) {
      lo = min;
    }
    if (max != null) {
      hi = max;
    }
    if (!lo.isFinite || !hi.isFinite || lo >= hi) {
      return;
    }
    if (lo.abs() > 1000 || hi.abs() > 1000) {
      return;
    }
    if (lo == _scene.domainMin && hi == _scene.domainMax) {
      return;
    }
    _apply(_scene.copyWith(domainMin: lo, domainMax: hi));
  }

  @override
  Widget build(BuildContext context) {
    final WbCurve? active = _activeCurve;
    final int invalid = _scene.invalidCount;
    final String subtitle = '${_scene.curves.length} 条曲线 · '
        '定义域 [${_formatNumber(_scene.domainMin)}, ${_formatNumber(_scene.domainMax)}] · '
        '${invalid > 0 ? '$invalid 条表达式无效' : '采样 ${_scene.samples} 点'}';
    final WbFunctionGeometry geometry = WbFunctionSampler.sample(_scene);
    return WbContextEditorShell(
      title: '函数图像编辑器',
      subtitle: subtitle,
      icon: LinearIcons.formula,
      onClose: widget.onClose,
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: _buildToolbar(context),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: _buildCurveList(context),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: _buildExpressionRow(context, active),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: _buildDomainRow(context),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _buildColorRow(context, active),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _buildPreview(context, geometry),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: WbEditorHint(
              '支持 + - * / ^、括号、pi / e 与 sin cos tan sqrt abs ln log exp 等函数；'
              '断点（如 tan 渐近线）自动分段不连线。',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-func-add-curve'),
          icon: LinearIcons.add,
          tooltip: '新增曲线',
          onTap: _addCurve,
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-func-remove-curve'),
          icon: LinearIcons.delete,
          tooltip: '删除选中曲线（至少保留一条）',
          enabled: _scene.curves.length > 1,
          onTap: _removeCurve,
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-func-visible'),
          icon: LinearIcons.visible,
          tooltip: '显示 / 隐藏选中曲线',
          active: _activeCurve?.visible ?? false,
          onTap: _toggleVisible,
        ),
      ],
    );
  }

  /// 多曲线管理列表：每项展示颜色、表达式与可见性开关。
  Widget _buildCurveList(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      key: const ValueKey<String>('wb-ctx-func-list'),
      constraints: const BoxConstraints(maxHeight: 132),
      decoration: BoxDecoration(
        color: colors.canvas.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
        border: Border.all(color: colors.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_scene.curves.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: WbEditorHint('暂无曲线，点击上方「+」添加'),
              ),
            for (final WbCurve curve in _scene.curves)
              _buildCurveItem(context, curve),
          ],
        ),
      ),
    );
  }

  /// 单条曲线管理项：颜色圆点 + 表达式 + 可见性开关 + 删除。
  ///
  /// 点击整行选中该曲线（表达式与颜色随后在上方编辑行 / 色板行调整）；
  /// 开关与删除按钮独立作用于当前行，不改变选中曲线。
  Widget _buildCurveItem(BuildContext context, WbCurve curve) {
    final WbThemeColors colors = context.wbColors;
    final bool selected = curve.id == _selectedId;
    final bool valid = curve.isValid;
    final Color foreground = selected ? colors.primary : colors.icon;
    return Material(
      color: selected
          ? colors.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('wb-ctx-func-curve-${curve.id}'),
        onTap: () => _select(curve.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: <Widget>[
              // 颜色圆点（颜色编辑在下方色板行进行）。
              Container(
                key: ValueKey<String>('wb-ctx-func-list-color-${curve.id}'),
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: curve.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.cardBorder),
                ),
              ),
              const SizedBox(width: 8),
              if (!valid) ...<Widget>[
                const Icon(
                  LinearIcons.warning,
                  size: 12,
                  color: WbContextPalette.flowEnd,
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  'y = ${curve.expression}',
                  key: ValueKey<String>('wb-ctx-func-list-expr-${curve.id}'),
                  style: WbTypography.caption.copyWith(
                    color: valid ? foreground : WbContextPalette.flowEnd,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              // 可见性开关（紧凑 Switch）。
              SizedBox(
                key: ValueKey<String>('wb-ctx-func-list-visible-${curve.id}'),
                width: 38,
                height: 22,
                child: FittedBox(
                  child: Switch(
                    value: curve.visible,
                    onChanged: (_) => _toggleVisibleById(curve.id),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              WbEditorIconButton(
                key: ValueKey<String>('wb-ctx-func-list-delete-${curve.id}'),
                icon: LinearIcons.delete,
                tooltip: '删除该曲线',
                enabled: _scene.curves.length > 1,
                size: 22,
                iconSize: 13,
                onTap: () => _removeCurveById(curve.id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpressionRow(BuildContext context, WbCurve? active) {
    final WbThemeColors colors = context.wbColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'y =',
              style: WbTypography.label.copyWith(color: colors.icon),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey<String>('wb-ctx-func-expr'),
                controller: _exprController,
                style: WbTypography.body.copyWith(color: colors.icon),
                decoration: wbEditorInputDecoration(
                  context,
                  hint: '例如 sin(x) + 0.5 * x',
                ),
                onChanged: _setExpression,
              ),
            ),
          ],
        ),
        if (active != null && !active.isValid)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '表达式无效，请检查语法（当前不绘制该曲线）',
              key: const ValueKey<String>('wb-ctx-func-error'),
              style: WbTypography.caption
                  .copyWith(color: WbContextPalette.flowEnd, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _buildDomainRow(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Row(
      children: <Widget>[
        Text(
          '定义域 x ∈',
          style: WbTypography.caption.copyWith(color: colors.icon),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 76,
          child: TextField(
            key: const ValueKey<String>('wb-ctx-func-domain-min'),
            controller: _minController,
            style: WbTypography.caption.copyWith(color: colors.icon),
            decoration: wbEditorInputDecoration(context, hint: '-6'),
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            onChanged: (String value) =>
                _applyDomain(min: double.tryParse(value.trim())),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '，',
            style: WbTypography.caption.copyWith(color: colors.icon),
          ),
        ),
        SizedBox(
          width: 76,
          child: TextField(
            key: const ValueKey<String>('wb-ctx-func-domain-max'),
            controller: _maxController,
            style: WbTypography.caption.copyWith(color: colors.icon),
            decoration: wbEditorInputDecoration(context, hint: '6'),
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            onChanged: (String value) =>
                _applyDomain(max: double.tryParse(value.trim())),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '（${_scene.samples} 个采样点）',
            style: WbTypography.caption.copyWith(
              color: colors.icon.withValues(alpha: 0.6),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildColorRow(BuildContext context, WbCurve? active) {
    return Row(
      children: <Widget>[
        const WbEditorHint('曲线颜色：'),
        const SizedBox(width: 4),
        Expanded(
          child: WbEditorColorRow(
            colors: WbContextPalette.curveSwatches,
            selected: active?.color,
            keyPrefix: 'wb-ctx-func-color',
            swatchSize: 16,
            onSelect: _setColor,
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context, WbFunctionGeometry geometry) {
    final WbThemeColors colors = context.wbColors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      child: Container(
        key: const ValueKey<String>('wb-ctx-func-preview'),
        decoration: BoxDecoration(
          color: colors.canvas,
          border: Border.all(color: colors.cardBorder),
          borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
        ),
        child: CustomPaint(
          painter: WbFunctionPlotPainter(geometry: geometry, colors: colors),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// 函数预览绘制器（网格 + 坐标轴 + 多曲线折线）。
class WbFunctionPlotPainter extends CustomPainter {
  /// 创建绘制器。
  WbFunctionPlotPainter({required this.geometry, required this.colors});

  /// 采样几何。
  final WbFunctionGeometry geometry;

  /// 主题颜色。
  final WbThemeColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    const double pad = 10;
    final Rect plot = Rect.fromLTWH(
      pad,
      pad,
      math.max(size.width - pad * 2, 1),
      math.max(size.height - pad * 2, 1),
    );
    final WbFunctionRange range = geometry.range;
    Offset map(double x, double y) {
      return Offset(
        plot.left + (x - range.minX) / range.width * plot.width,
        plot.bottom - (y - range.minY) / range.height * plot.height,
      );
    }

    final double stepX = _niceStep(range.width / 8);
    final double stepY = _niceStep(range.height / 6);
    final Paint grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.icon.withValues(alpha: 0.08);
    final Paint axis = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = colors.icon.withValues(alpha: 0.28);
    for (double x = (range.minX / stepX).ceilToDouble() * stepX;
        x <= range.maxX + 1e-9;
        x += stepX) {
      final double px = map(x, range.minY).dx;
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), grid);
    }
    for (double y = (range.minY / stepY).ceilToDouble() * stepY;
        y <= range.maxY + 1e-9;
        y += stepY) {
      final double py = map(range.minX, y).dy;
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), grid);
    }
    if (range.minY <= 0 && 0 <= range.maxY) {
      final double py = map(range.minX, 0).dy;
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), axis);
    }
    if (range.minX <= 0 && 0 <= range.maxX) {
      final double px = map(0, range.minY).dx;
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), axis);
    }

    for (final WbFunctionPath path in geometry.paths) {
      final Paint pen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..color = path.color;
      for (final List<Offset> segment in path.segments) {
        final Path line = Path();
        for (int i = 0; i < segment.length; i++) {
          final Offset p = map(segment[i].dx, segment[i].dy);
          if (i == 0) {
            line.moveTo(p.dx, p.dy);
          } else {
            line.lineTo(p.dx, p.dy);
          }
        }
        canvas.drawPath(line, pen);
      }
    }
  }

  /// 取 1 / 2 / 5 倍数量级的「整齐」步长。
  static double _niceStep(double raw) {
    if (!raw.isFinite || raw <= 0) {
      return 1;
    }
    final double magnitude =
        math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final double residual = raw / magnitude;
    if (residual <= 1) {
      return magnitude;
    }
    if (residual <= 2) {
      return 2 * magnitude;
    }
    if (residual <= 5) {
      return 5 * magnitude;
    }
    return 10 * magnitude;
  }

  @override
  bool shouldRepaint(WbFunctionPlotPainter oldDelegate) =>
      oldDelegate.geometry != geometry || oldDelegate.colors != colors;
}
