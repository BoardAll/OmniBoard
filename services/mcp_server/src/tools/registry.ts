/**
 * MCP 工具注册表（《MCP_Server详细设计》§6/§19）。
 *
 * 与 §19 附录「MCP 工具完整列表」逐项对齐（113 个工具），每项包含：
 *  - `name`：MCP 工具名（下划线形态，如 `element_create`）
 *  - `internalToolId`：内部点号形态（§6.3 命名映射：`element.create`、
 *    `render.3d.create`、`render.function.set_style`）
 *  - `description`：中文描述（面向模型）
 *  - `inputSchema`：JSON Schema（object / properties / required）
 *  - `confirmation`：危险等级 Auto / Preview / Confirm（§6.5）
 *  - `scope`：调用所需 Scope（与 Open API / C++ ToolRegistry 同一套权限）
 *
 * 确认级别规则（与 services/api 的 MCP 桥接目录保持一致，重叠工具完全一致）：
 *  - `confirm`：删除/移除类（*_delete、*_remove_*）、board_share、
 *    page_merge、ai_execute_tool_call、未列入的破坏性操作
 *  - `preview`：结构重排/批量类（page_split、element_batch、flowchart_relayout、
 *    flowchart_to_swimlane、annotate_save_to_board、render_3d_transform）
 *  - `auto`：其余（查询、创建、更新、导出等）
 */

export type ConfirmationLevel = 'auto' | 'preview' | 'confirm';

export type ToolCategory =
  | 'board'
  | 'page'
  | 'element'
  | 'connector'
  | 'comment'
  | 'export'
  | 'history'
  | 'mindmap'
  | 'table'
  | 'flowchart'
  | 'function'
  | 'render3d'
  | 'render2d'
  | 'document'
  | 'annotate'
  | 'ai'
  | 'presence';

export interface ToolDefinition {
  name: string;
  internalToolId: string;
  category: ToolCategory;
  description: string;
  scope: string;
  confirmation: ConfirmationLevel;
  inputSchema: Record<string, unknown>;
}

/* ------------------------------------------------------------------ */
/* 参数与 Schema 构造                                                    */
/* ------------------------------------------------------------------ */

interface Param {
  type: 'string' | 'number' | 'boolean' | 'object' | 'array';
  description: string;
  required: boolean;
  items?: Record<string, unknown>;
  default?: unknown;
}

/** string 参数。 */
const S = (description: string, required = false): Param => ({ type: 'string', description, required });
/** number 参数。 */
const N = (description: string, required = false): Param => ({ type: 'number', description, required });
/** boolean 参数。 */
const B = (description: string, required = false): Param => ({ type: 'boolean', description, required });
/** object 参数。 */
const O = (description: string, required = false): Param => ({ type: 'object', description, required });
/** string 数组参数。 */
const AS = (description: string, required = false): Param => ({
  type: 'array',
  description,
  required,
  items: { type: 'string' },
});
/** object 数组参数。 */
const AO = (description: string, required = false): Param => ({
  type: 'array',
  description,
  required,
  items: { type: 'object' },
});

interface ToolSeed {
  name: string;
  confirmation: ConfirmationLevel;
  description: string;
  params: Record<string, Param>;
}

const t = (
  name: string,
  confirmation: ConfirmationLevel,
  description: string,
  params: Record<string, Param>,
): ToolSeed => ({ name, confirmation, description, params });

/* ------------------------------------------------------------------ */
/* 工具种子（顺序与 §19 附录一致）                                        */
/* ------------------------------------------------------------------ */

const TOOL_SEEDS: readonly ToolSeed[] = [
  // —— 白板（8）——
  t('board_create', 'auto', '创建白板', { name: S('白板名称', true), description: S('描述') }),
  t('board_get', 'auto', '获取白板详情', { boardId: S('白板 ID', true) }),
  t('board_update', 'auto', '更新白板名称或描述', { boardId: S('白板 ID', true), name: S('新名称'), description: S('新描述') }),
  t('board_delete', 'confirm', '删除白板（危险操作，需确认）', { boardId: S('白板 ID', true) }),
  t('board_share', 'confirm', '分享白板并生成分享链接', { boardId: S('白板 ID', true), role: S('分享角色'), expiresAt: S('过期时间'), password: S('访问密码') }),
  t('board_list_collaborators', 'auto', '列出白板协作者', { boardId: S('白板 ID', true) }),
  t('board_add_collaborator', 'preview', '添加协作者', { boardId: S('白板 ID', true), userId: S('用户 ID', true), role: S('角色', true) }),
  t('board_remove_collaborator', 'confirm', '移除协作者（需确认）', { boardId: S('白板 ID', true), userId: S('用户 ID', true) }),

  // —— 页面（14）——
  t('page_list', 'auto', '列出白板页面', { boardId: S('白板 ID', true) }),
  t('page_create', 'auto', '创建页面', { boardId: S('白板 ID', true), name: S('页面名称', true), backgroundId: S('背景 ID') }),
  t('page_get', 'auto', '获取页面详情', { pageId: S('页面 ID', true) }),
  t('page_update', 'auto', '更新页面属性', { pageId: S('页面 ID', true), name: S('新名称'), backgroundId: S('背景 ID') }),
  t('page_delete', 'confirm', '删除页面（危险操作，需确认）', { pageId: S('页面 ID', true) }),
  t('page_duplicate', 'auto', '复制页面', { pageId: S('页面 ID', true) }),
  t('page_move', 'auto', '调整页面顺序', { pageId: S('页面 ID', true), index: N('新位置（从 0 开始）', true) }),
  t('page_rename', 'auto', '重命名页面', { pageId: S('页面 ID', true), name: S('新名称', true) }),
  t('page_lock', 'auto', '锁定/解锁页面', { pageId: S('页面 ID', true), locked: B('是否锁定', true) }),
  t('page_hide', 'auto', '隐藏/显示页面', { pageId: S('页面 ID', true), hidden: B('是否隐藏', true) }),
  t('page_set_background', 'auto', '设置页面背景', { pageId: S('页面 ID', true), backgroundId: S('背景 ID', true) }),
  t('page_thumbnail', 'auto', '获取页面缩略图', { pageId: S('页面 ID', true) }),
  t('page_split', 'preview', '按 Y 坐标切分页面（返回预览）', { pageId: S('页面 ID', true), splitY: N('切分 Y 坐标', true), name: S('新页面名称') }),
  t('page_merge', 'confirm', '合并多个页面（需确认）', { pageIds: AS('页面 ID 列表', true), name: S('合并后名称') }),

  // —— 元素（15）——
  t('element_list', 'auto', '列出页面元素', { pageId: S('页面 ID', true), filter: S('过滤表达式，如 type:sticky') }),
  t('element_create', 'auto', '创建一个或多个元素（便签/文本/形状/图片等）', { pageId: S('页面 ID', true), elements: AO('元素定义列表', true), dryRun: B('仅演练不落库') }),
  t('element_get', 'auto', '获取元素详情', { elementId: S('元素 ID', true) }),
  t('element_update', 'auto', '更新元素属性', { elementId: S('元素 ID', true), patch: O('属性补丁', true) }),
  t('element_delete', 'confirm', '删除元素（危险操作，需确认）', { elementId: S('元素 ID', true) }),
  t('element_batch', 'preview', '批量创建/更新/删除/移动元素（返回预览）', { operations: AO('操作列表', true), dryRun: B('仅演练不落库'), confirm: B('确认执行') }),
  t('element_set_style', 'auto', '设置元素样式', { elementId: S('元素 ID', true), style: O('样式对象', true), merge: B('是否合并（默认 true）') }),
  t('element_move', 'auto', '移动元素', { elementId: S('元素 ID', true), position: O('新位置 {x,y}'), dx: N('X 偏移'), dy: N('Y 偏移') }),
  t('element_resize', 'auto', '调整元素尺寸', { elementId: S('元素 ID', true), size: O('新尺寸 {width,height}'), width: N('宽度'), height: N('高度') }),
  t('element_align', 'auto', '对齐多个元素', { elementIds: AS('元素 ID 列表', true), alignment: S('对齐方式', true), relativeTo: S('相对元素 ID') }),
  t('element_distribute', 'auto', '等距分布多个元素', { elementIds: AS('元素 ID 列表', true), axis: S('分布轴：x 或 y', true) }),
  t('element_group', 'auto', '将元素组合为组', { elementIds: AS('元素 ID 列表', true) }),
  t('element_ungroup', 'auto', '解散元素组', { groupId: S('组 ID', true) }),
  t('element_bring_forward', 'auto', '上移一层（提高 z-order）', { elementId: S('元素 ID', true) }),
  t('element_send_backward', 'auto', '下移一层（降低 z-order）', { elementId: S('元素 ID', true) }),

  // —— 连线（5）——
  t('connector_list', 'auto', '列出页面连线', { pageId: S('页面 ID', true) }),
  t('connector_create', 'auto', '创建连线', { pageId: S('页面 ID', true), fromElementId: S('起点元素 ID', true), toElementId: S('终点元素 ID', true), label: S('连线标签') }),
  t('connector_get', 'auto', '获取连线详情', { connectorId: S('连线 ID', true) }),
  t('connector_update', 'auto', '更新连线', { connectorId: S('连线 ID', true), patch: O('连线补丁', true) }),
  t('connector_delete', 'confirm', '删除连线（需确认）', { connectorId: S('连线 ID', true) }),

  // —— 评论（7）——
  t('comment_list', 'auto', '列出白板评论', { boardId: S('白板 ID', true), pageId: S('页面 ID'), resolved: B('按解决状态过滤') }),
  t('comment_create', 'auto', '创建评论', { boardId: S('白板 ID', true), content: S('评论内容', true), pageId: S('页面 ID'), elementId: S('元素 ID') }),
  t('comment_get', 'auto', '获取评论详情', { commentId: S('评论 ID', true) }),
  t('comment_update', 'auto', '更新评论内容', { commentId: S('评论 ID', true), content: S('新内容', true) }),
  t('comment_delete', 'confirm', '删除评论（需确认）', { commentId: S('评论 ID', true) }),
  t('comment_reply', 'auto', '回复评论', { commentId: S('评论 ID', true), content: S('回复内容', true) }),
  t('comment_resolve', 'auto', '解决/重新打开评论', { commentId: S('评论 ID', true), resolved: B('是否解决') }),

  // —— 导出（4）——
  t('export_create', 'auto', '创建白板导出任务', { boardId: S('白板 ID', true), format: S('格式：pdf/png/svg/json/markdown', true), pages: AS('页面 ID 子集'), quality: S('清晰度：low/medium/high') }),
  t('export_get', 'auto', '查询导出任务', { exportId: S('导出 ID', true) }),
  t('export_download', 'auto', '下载导出结果', { exportId: S('导出 ID', true) }),
  t('export_page', 'auto', '导出单个页面', { pageId: S('页面 ID', true), format: S('格式', true) }),

  // —— 历史（4）——
  t('history_list', 'auto', '列出白板历史', { boardId: S('白板 ID', true), limit: N('返回条数') }),
  t('history_undo', 'auto', '撤销操作', { boardId: S('白板 ID', true), transactionId: S('事务 ID（可选，默认最近）') }),
  t('history_redo', 'auto', '重做操作', { boardId: S('白板 ID', true), transactionId: S('事务 ID（可选，默认最近）') }),
  t('history_snapshot', 'auto', '创建历史快照', { boardId: S('白板 ID', true), name: S('快照名称') }),

  // —— 思维导图（6）——
  t('mindmap_create', 'auto', '创建思维导图', { pageId: S('页面 ID', true), rootTopic: S('根主题', true) }),
  t('mindmap_add_node', 'auto', '添加导图节点', { mindmapId: S('导图 ID', true), parentId: S('父节点 ID', true), topic: S('节点主题', true) }),
  t('mindmap_remove_node', 'confirm', '删除导图节点（需确认）', { mindmapId: S('导图 ID', true), nodeId: S('节点 ID', true) }),
  t('mindmap_set_layout', 'auto', '设置导图布局', { mindmapId: S('导图 ID', true), layout: S('布局：radial/tree/logic 等', true) }),
  t('mindmap_set_style', 'auto', '设置导图样式', { mindmapId: S('导图 ID', true), style: O('样式对象', true) }),
  t('mindmap_export', 'auto', '导出思维导图', { mindmapId: S('导图 ID', true), format: S('格式') }),

  // —— 表格（6）——
  t('table_create', 'auto', '创建表格', { pageId: S('页面 ID', true), rows: N('行数'), columns: N('列数') }),
  t('table_set_cell', 'auto', '设置单元格内容', { tableId: S('表格 ID', true), row: N('行号', true), column: N('列号', true), value: S('单元格内容', true) }),
  t('table_set_formula', 'auto', '设置单元格公式', { tableId: S('表格 ID', true), row: N('行号', true), column: N('列号', true), formula: S('公式表达式', true) }),
  t('table_sort', 'auto', '按列排序表格', { tableId: S('表格 ID', true), column: N('列号', true), direction: S('方向：asc/desc') }),
  t('table_filter', 'auto', '按列过滤表格', { tableId: S('表格 ID', true), column: N('列号', true), operator: S('操作符', true), value: S('过滤值', true) }),
  t('table_set_style', 'auto', '设置表格样式', { tableId: S('表格 ID', true), style: O('样式对象', true) }),

  // —— 流程图（12）——
  t('flowchart_create', 'auto', '创建流程图', { pageId: S('页面 ID', true), name: S('名称') }),
  t('flowchart_add_node', 'auto', '添加流程节点', { flowchartId: S('流程图 ID', true), nodeType: S('节点类型', true), label: S('节点文本', true), position: O('位置 {x,y}') }),
  t('flowchart_remove_node', 'confirm', '删除流程节点（需确认）', { flowchartId: S('流程图 ID', true), nodeId: S('节点 ID', true) }),
  t('flowchart_connect', 'auto', '连接两个流程节点', { flowchartId: S('流程图 ID', true), fromNodeId: S('起点节点', true), toNodeId: S('终点节点', true), label: S('连线标签') }),
  t('flowchart_add_swimlane', 'auto', '添加泳道', { flowchartId: S('流程图 ID', true), name: S('泳道名称', true) }),
  t('flowchart_remove_swimlane', 'confirm', '删除泳道（需确认）', { flowchartId: S('流程图 ID', true), swimlaneId: S('泳道 ID', true) }),
  t('flowchart_auto_layout', 'auto', '自动布局流程图', { flowchartId: S('流程图 ID', true) }),
  t('flowchart_partial_layout', 'auto', '局部重新布局', { flowchartId: S('流程图 ID', true), nodeIds: AS('节点 ID 列表', true) }),
  t('flowchart_relayout', 'preview', '整体重排（返回预览）', { flowchartId: S('流程图 ID', true) }),
  t('flowchart_to_swimlane', 'preview', '转换为泳道图（返回预览）', { flowchartId: S('流程图 ID', true), lanes: AS('泳道划分', true) }),
  t('flowchart_label_branches', 'auto', '标注分支条件', { flowchartId: S('流程图 ID', true), labels: O('分支标签映射', true) }),
  t('flowchart_template_apply', 'auto', '应用流程图模板', { flowchartId: S('流程图 ID', true), template: S('模板名', true) }),

  // —— 函数（render.function.*，5）——
  t('render_function_create', 'auto', '创建函数图像', { pageId: S('页面 ID', true), expression: S('函数表达式', true), domain: O('定义域 {min,max}') }),
  t('render_function_set_style', 'auto', '设置函数图像样式', { functionId: S('函数 ID', true), style: O('样式对象', true) }),
  t('render_function_add', 'auto', '叠加函数曲线', { functionId: S('函数 ID', true), expression: S('函数表达式', true) }),
  t('render_function_analyze', 'auto', '分析函数（极值/零点/单调性）', { functionId: S('函数 ID', true) }),
  t('render_function_export', 'auto', '导出函数图像', { functionId: S('函数 ID', true), format: S('格式') }),

  // —— 3D（render.3d.*，8）——
  t('render_3d_create', 'auto', '创建 3D 对象', { pageId: S('页面 ID', true), kind: S('对象类型', true), params: O('对象参数') }),
  t('render_3d_render', 'auto', '渲染 3D 场景', { objectId: S('对象 ID', true) }),
  t('render_3d_pick_surface', 'auto', '拾取 3D 表面', { objectId: S('对象 ID', true), point: O('拾取点', true) }),
  t('render_3d_set_face_color', 'auto', '设置面的颜色', { objectId: S('对象 ID', true), faceId: S('面 ID', true), color: S('颜色', true) }),
  t('render_3d_set_material', 'auto', '设置材质', { objectId: S('对象 ID', true), material: O('材质参数', true) }),
  t('render_3d_transform', 'preview', '变换 3D 对象（旋转/缩放/平移，返回预览）', { objectId: S('对象 ID', true), transform: O('变换参数', true) }),
  t('render_3d_set_light', 'auto', '设置光照', { objectId: S('对象 ID', true), light: O('光照参数', true) }),
  t('render_3d_export', 'auto', '导出 3D 对象', { objectId: S('对象 ID', true), format: S('格式') }),

  // —— 2D（render.2d.*，3）——
  t('render_2d_create', 'auto', '创建 2D 图形', { pageId: S('页面 ID', true), kind: S('图形类型', true), params: O('图形参数') }),
  t('render_2d_set_style', 'auto', '设置 2D 图形样式', { objectId: S('对象 ID', true), style: O('样式对象', true) }),
  t('render_2d_annotate', 'auto', '为 2D 图形添加批注', { objectId: S('对象 ID', true), annotation: O('批注内容', true) }),

  // —— 文档（3）——
  t('document_embed', 'auto', '嵌入文档（PDF 等）', { pageId: S('页面 ID', true), fileId: S('文件 ID', true), pageNumber: N('起始页码') }),
  t('document_goto_page', 'auto', '跳转文档页码', { documentId: S('文档 ID', true), pageNumber: N('目标页码', true) }),
  t('document_extract_text', 'auto', '提取文档文本', { documentId: S('文档 ID', true), pageNumber: N('页码（缺省全部）') }),

  // —— 批注（6）——
  t('annotate_enter_transparent', 'auto', '进入透明批注模式', { pageId: S('页面 ID', true) }),
  t('annotate_exit_transparent', 'auto', '退出透明批注模式', { pageId: S('页面 ID', true) }),
  t('annotate_set_penetrate', 'auto', '设置批注穿透', { pageId: S('页面 ID', true), enabled: B('是否穿透', true) }),
  t('annotate_toggle_mode', 'auto', '切换批注模式', { pageId: S('页面 ID', true), mode: S('模式：pen/laser/highlight', true) }),
  t('annotate_add_stroke', 'auto', '添加批注笔迹', { pageId: S('页面 ID', true), stroke: O('笔迹数据', true) }),
  t('annotate_save_to_board', 'preview', '将批注保存到白板（返回预览）', { pageId: S('页面 ID', true), strokes: AO('笔迹列表', true) }),

  // —— AI（4）——
  t('ai_session_create', 'auto', '创建 AI 会话', { boardId: S('白板 ID', true), model: S('模型名') }),
  t('ai_send_message', 'auto', '发送消息给 AI 助手', { sessionId: S('会话 ID', true), content: S('消息内容', true) }),
  t('ai_send_audio', 'auto', '发送语音给 AI 助手', { sessionId: S('会话 ID', true), audioBase64: S('音频 Base64') }),
  t('ai_execute_tool_call', 'confirm', '执行 AI 提出的工具调用（需确认）', { toolCallId: S('工具调用 ID', true) }),

  // —— 协作（3）——
  t('presence_get', 'auto', '获取在线协作者', { boardId: S('白板 ID', true) }),
  t('follow_user', 'auto', '跟随用户视角', { boardId: S('白板 ID', true), userId: S('用户 ID', true) }),
  t('present_start', 'preview', '开始演示（返回预览）', { boardId: S('白板 ID', true), pageId: S('起始页面 ID') }),
];

/* ------------------------------------------------------------------ */
/* 派生逻辑                                                              */
/* ------------------------------------------------------------------ */

/** §6.3 命名映射：`element_create` → `element.create`；`render_3d_create` → `render.3d.create`。 */
export function toInternalToolId(name: string): string {
  if (name.startsWith('render_3d_')) return `render.3d.${name.slice('render_3d_'.length)}`;
  if (name.startsWith('render_2d_')) return `render.2d.${name.slice('render_2d_'.length)}`;
  if (name.startsWith('render_function_')) return `render.function.${name.slice('render_function_'.length)}`;
  const index = name.indexOf('_');
  return index === -1 ? name : `${name.slice(0, index)}.${name.slice(index + 1)}`;
}

function categoryOf(name: string): ToolCategory {
  if (name.startsWith('render_3d_')) return 'render3d';
  if (name.startsWith('render_2d_')) return 'render2d';
  if (name.startsWith('render_function_')) return 'function';
  const prefix = name.slice(0, name.indexOf('_'));
  const known: readonly ToolCategory[] = [
    'board', 'page', 'element', 'connector', 'comment', 'export', 'history',
    'mindmap', 'table', 'flowchart', 'document', 'annotate', 'ai', 'presence',
  ];
  return known.includes(prefix as ToolCategory) ? (prefix as ToolCategory) : 'element';
}

/** Scope 映射（与 Open API / C++ ToolRegistry 同一套权限体系）。 */
function scopeFor(name: string, category: ToolCategory): string {
  switch (category) {
    case 'board':
      if (name === 'board_get' || name === 'board_list_collaborators') return 'board:read';
      if (name === 'board_share' || name === 'board_add_collaborator' || name === 'board_remove_collaborator')
        return 'board:share';
      return 'board:write';
    case 'page':
      return name === 'page_list' || name === 'page_get' || name === 'page_thumbnail' ? 'page:read' : 'page:write';
    case 'element':
      return name === 'element_list' || name === 'element_get' ? 'element:read' : 'element:write';
    case 'connector':
      return name === 'connector_list' || name === 'connector_get' ? 'connector:read' : 'connector:write';
    case 'comment':
      return name === 'comment_list' || name === 'comment_get' ? 'comment:read' : 'comment:write';
    case 'export':
      return 'export:read';
    case 'history':
      return name === 'history_list' ? 'history:read' : 'history:write';
    case 'ai':
      return 'ai:invoke';
    case 'presence':
      return name === 'present_start' ? 'board:write' : 'board:read';
    default:
      return name.endsWith('_analyze') ? 'element:read' : 'element:write';
  }
}

function buildInputSchema(params: Record<string, Param>): Record<string, unknown> {
  const properties: Record<string, unknown> = {};
  const required: string[] = [];
  for (const [key, param] of Object.entries(params)) {
    const property: Record<string, unknown> = { type: param.type, description: param.description };
    if (param.items) property['items'] = param.items;
    if (param.default !== undefined) property['default'] = param.default;
    properties[key] = property;
    if (param.required) required.push(key);
  }
  return { type: 'object', properties, required, additionalProperties: false };
}

/* ------------------------------------------------------------------ */
/* 导出目录                                                              */
/* ------------------------------------------------------------------ */

/** 完整工具目录（113 项，§19）。 */
export const TOOL_CATALOG: readonly ToolDefinition[] = TOOL_SEEDS.map((seed) => {
  const category = categoryOf(seed.name);
  return {
    name: seed.name,
    internalToolId: toInternalToolId(seed.name),
    category,
    description: seed.description,
    scope: scopeFor(seed.name, category),
    confirmation: seed.confirmation,
    inputSchema: buildInputSchema(seed.params),
  };
});

const TOOL_INDEX = new Map(TOOL_CATALOG.map((tool) => [tool.name, tool]));

/** 按 MCP 名称或内部点号 id 查找工具。 */
export function findTool(nameOrId: string): ToolDefinition | undefined {
  const direct = TOOL_INDEX.get(nameOrId);
  if (direct) return direct;
  return TOOL_CATALOG.find((tool) => tool.internalToolId === nameOrId);
}

export function listTools(): ToolDefinition[];
export function listTools(cursor: string | null | undefined): { tools: ToolDefinition[]; nextCursor: null };
export function listTools(cursor?: string | null): ToolDefinition[] | { tools: ToolDefinition[]; nextCursor: null } {
  if (cursor === undefined) return [...TOOL_CATALOG];
  // 工具目录为静态目录（不分页）；cursor 一律返回空 nextCursor（保持协议形状）。
  return { tools: [...TOOL_CATALOG], nextCursor: null };
}

export function toolCategories(): Array<{ category: ToolCategory; count: number }> {
  const counts = new Map<ToolCategory, number>();
  for (const tool of TOOL_CATALOG) {
    counts.set(tool.category, (counts.get(tool.category) ?? 0) + 1);
  }
  return [...counts.entries()].map(([category, count]) => ({ category, count }));
}
