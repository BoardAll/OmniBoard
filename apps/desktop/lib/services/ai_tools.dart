/// 白板内置 AI 工具定义（《AI 助手与 MCP 设计》§5 / §6.3 命名映射）。
///
/// 工具名与 `services/mcp_server` 注册表保持一致（下划线形态，如
/// `element_create`）；这些定义随请求发送给模型，模型以工具调用形式
/// 返回结构化编辑指令，由 `WbAiCanvasExecutor` 落地为画布操作。
///
/// 未注册工具时模型只能以正文文本描述编辑（出现“对话框里显示坐标
/// 数据、白板无变化”的问题），因此本清单必须与执行器保持同步。
library;

import 'package:whiteboard_ai/ai_client.dart';

/// 白板工具清单（提供给模型的 function 定义）。
abstract final class WbBoardTools {
  /// 创建元素（便签 / 文本 / 形状 / 手绘笔迹 / 连线），支持批量。
  static const String elementCreate = 'element_create';

  /// 更新元素属性（文本 / 颜色 / 位置 / 尺寸等）。
  static const String elementUpdate = 'element_update';

  /// 移动元素（绝对位置或增量偏移）。
  static const String elementMove = 'element_move';

  /// 删除元素（危险操作，需确认）。
  static const String elementDelete = 'element_delete';

  /// 元素类型枚举值（对齐 `WbElementKind`；`sticky` / `rect` 等别名由
  /// 执行器归一）。
  static const List<String> elementTypes = <String>[
    'note',
    'text',
    'shape',
    'drawing',
    'connector',
  ];

  /// 发送给模型的工具定义（顺序即模型工具清单顺序）。
  static const List<AiToolDefinition> definitions = <AiToolDefinition>[
    AiToolDefinition(
      name: elementCreate,
      description:
          '在白板上创建一个或多个元素。生成图形、示意图、手绘涂鸦时，'
          '优先使用 drawing 类型并用 points 给出坐标序列（不要直接在回复'
          '正文中输出坐标数据）；生成文字内容用 note / text，几何图形用'
          'shape，箭头流程用 connector。省略 position 时自动放置在视口'
          '中心。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'elements': <String, dynamic>{
            'type': 'array',
            'description': '元素定义列表（按数组顺序错位摆放，避免完全重叠）',
            'items': <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'type': <String, dynamic>{
                  'type': 'string',
                  'enum': elementTypes,
                  'description': '元素类型（默认 note）：'
                      'note 便签 / text 文本 / shape 形状 / '
                      'drawing 手绘笔迹 / connector 连线',
                },
                'text': <String, dynamic>{
                  'type': 'string',
                  'description': '文本内容（note / text 使用）',
                },
                'position': _createPositionSchema,
                'size': _createSizeSchema,
                'color': <String, dynamic>{
                  'type': 'string',
                  'description': '颜色（#RRGGBB 或 #AARRGGBB）；省略使用默认色',
                },
                'shapeKind': <String, dynamic>{
                  'type': 'string',
                  'enum': <String>['rect', 'ellipse', 'diamond', 'parallelogram'],
                  'description': '形状子类型（type=shape 时生效，默认 rect）',
                },
                'points': <String, dynamic>{
                  'type': 'array',
                  'description': '手绘笔迹 / 连线的坐标序列（x/y 数字对）；'
                      'drawing 至少 2 个点，connector 恰为起止 2 个点',
                  'items': <String, dynamic>{
                    'type': 'object',
                    'properties': <String, dynamic>{
                      'x': <String, dynamic>{'type': 'number'},
                      'y': <String, dynamic>{'type': 'number'},
                    },
                    'required': <String>['x', 'y'],
                  },
                },
                'fontSize': <String, dynamic>{
                  'type': 'number',
                  'description': '字号（可选）',
                },
                'textAlign': <String, dynamic>{
                  'type': 'string',
                  'enum': <String>['left', 'center', 'right'],
                  'description': '文本水平对齐（可选，默认 left）',
                },
              },
              'required': <String>['type'],
            },
          },
        },
        'required': <String>['elements'],
      },
    ),
    AiToolDefinition(
      name: elementUpdate,
      description: '更新单个元素的属性（文本内容、颜色、位置、尺寸、字号、对齐等）。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'elementId': <String, dynamic>{
            'type': 'string',
            'description': '元素 ID',
          },
          'patch': <String, dynamic>{
            'type': 'object',
            'description': '属性补丁（仅需包含要修改的字段）',
            'properties': <String, dynamic>{
              'text': <String, dynamic>{
                'type': 'string',
                'description': '新文本内容',
              },
              'color': <String, dynamic>{
                'type': 'string',
                'description': '新颜色（#RRGGBB 或 #AARRGGBB）',
              },
              'position': _updatePositionSchema,
              'size': _updateSizeSchema,
              'fontSize': <String, dynamic>{
                'type': 'number',
                'description': '新字号',
              },
              'textAlign': <String, dynamic>{
                'type': 'string',
                'enum': <String>['left', 'center', 'right'],
              },
              'shapeKind': <String, dynamic>{
                'type': 'string',
                'enum': <String>['rect', 'ellipse', 'diamond', 'parallelogram'],
              },
            },
          },
        },
        'required': <String>['elementId', 'patch'],
      },
    ),
    AiToolDefinition(
      name: elementMove,
      description: '移动单个元素到指定位置（position 绝对坐标，或 dx/dy 增量偏移）。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'elementId': <String, dynamic>{
            'type': 'string',
            'description': '元素 ID',
          },
          'position': _updatePositionSchema,
          'dx': <String, dynamic>{
            'type': 'number',
            'description': 'X 增量偏移（与 position 二选一）',
          },
          'dy': <String, dynamic>{
            'type': 'number',
            'description': 'Y 增量偏移（与 position 二选一）',
          },
        },
        'required': <String>['elementId'],
      },
    ),
    AiToolDefinition(
      name: elementDelete,
      description: '删除一个或多个元素（危险操作，需用户确认后执行）。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'ids': <String, dynamic>{
            'type': 'array',
            'description': '要删除的元素 ID 列表',
            'items': <String, dynamic>{'type': 'string'},
          },
        },
        'required': <String>['ids'],
      },
    ),
  ];

  /// 创建用位置 schema（省略时自动落点）。
  static const Map<String, dynamic> _createPositionSchema =
      <String, dynamic>{
    'type': 'object',
    'description': '元素左上角世界坐标；省略时自动放置在视口中心',
    'properties': <String, dynamic>{
      'x': <String, dynamic>{'type': 'number'},
      'y': <String, dynamic>{'type': 'number'},
    },
    'required': <String>['x', 'y'],
  };

  /// 更新 / 移动用位置 schema。
  static const Map<String, dynamic> _updatePositionSchema =
      <String, dynamic>{
    'type': 'object',
    'description': '左上角世界坐标',
    'properties': <String, dynamic>{
      'x': <String, dynamic>{'type': 'number'},
      'y': <String, dynamic>{'type': 'number'},
    },
    'required': <String>['x', 'y'],
  };

  /// 创建用尺寸 schema。
  static const Map<String, dynamic> _createSizeSchema = <String, dynamic>{
    'type': 'object',
    'description': '元素尺寸；省略时按类型默认（便签 180x120，文本 220x44）',
    'properties': <String, dynamic>{
      'width': <String, dynamic>{'type': 'number'},
      'height': <String, dynamic>{'type': 'number'},
    },
    'required': <String>['width', 'height'],
  };

  /// 更新用尺寸 schema。
  static const Map<String, dynamic> _updateSizeSchema = <String, dynamic>{
    'type': 'object',
    'description': '新尺寸',
    'properties': <String, dynamic>{
      'width': <String, dynamic>{'type': 'number'},
      'height': <String, dynamic>{'type': 'number'},
    },
    'required': <String>['width', 'height'],
  };
}
