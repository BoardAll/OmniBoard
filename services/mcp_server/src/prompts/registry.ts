/**
 * MCP 提示模板注册表（《MCP_Server详细设计》§8）。
 *
 * 内置 10 个模板（§8.3）：brainstorm / flowchart / mindmap / summarize /
 * cluster / vote / userJourney / swot / retrospective / kanban。
 *
 * - `prompts/list` → name / description / arguments；
 * - `prompts/get` → 渲染为 messages（`role: user` + text content）。
 */

import { RpcError } from '../protocol/jsonrpc.js';

export interface PromptArgument {
  name: string;
  description: string;
  required: boolean;
}

export interface PromptDefinition {
  name: string;
  description: string;
  arguments: PromptArgument[];
  /** 渲染提示文本（入参已通过必填校验）。 */
  build(args: Record<string, string>): string;
}

export interface PromptMessage {
  role: 'user' | 'assistant';
  content: { type: 'text'; text: string };
}

export interface PromptGetResult {
  description: string;
  messages: PromptMessage[];
}

export interface PromptSummary {
  name: string;
  description: string;
  arguments: PromptArgument[];
}

const arg = (name: string, description: string, required = false): PromptArgument => ({
  name,
  description,
  required,
});

export const PROMPT_DEFINITIONS: readonly PromptDefinition[] = [
  {
    name: 'brainstorm',
    description: '头脑风暴：生成便签并分组',
    arguments: [arg('topic', '讨论主题', true), arg('count', '便签数量（默认 10）')],
    build: (args) => `请围绕“${args['topic'] ?? ''}”生成 ${args['count'] ?? '10'} 个便签，并按主题分组。`,
  },
  {
    name: 'flowchart',
    description: '生成流程图',
    arguments: [arg('process', '流程描述', true)],
    build: (args) =>
      `请把以下流程整理成流程图：${args['process'] ?? ''}。使用 flowchart_create、flowchart_add_node 与 flowchart_connect 工具实现，并保持节点命名简洁。`,
  },
  {
    name: 'mindmap',
    description: '生成思维导图',
    arguments: [arg('topic', '中心主题', true)],
    build: (args) =>
      `请以“${args['topic'] ?? ''}”为中心主题生成思维导图，使用 mindmap_create 与 mindmap_add_node 工具逐层展开二级、三级节点。`,
  },
  {
    name: 'summarize',
    description: '总结当前白板',
    arguments: [],
    build: () => '请总结当前白板：逐页概括核心内容，列出关键结论、待办事项与风险点。',
  },
  {
    name: 'cluster',
    description: '聚类整理',
    arguments: [arg('topic', '聚类范围说明（默认全部内容）')],
    build: (args) =>
      `请对白板上${args['topic'] ? `与“${args['topic']}”相关的` : ''}元素进行聚类整理：按主题分组、调整位置与配色，并给出分组名称。`,
  },
  {
    name: 'vote',
    description: '投票',
    arguments: [arg('options', '候选方案（逗号分隔）')],
    build: (args) =>
      `请为${args['options'] ? `候选方案（${args['options']}）` : '白板上的候选方案'}组织投票：生成投票区、统计票数并标注胜出项。`,
  },
  {
    name: 'userJourney',
    description: '用户旅程',
    arguments: [arg('persona', '用户角色（可选）')],
    build: (args) =>
      `请以${args['persona'] ? `“${args['persona']}”` : '目标用户'}的视角梳理用户旅程：按阶段列出行为、触点、痛点与机会点，并在白板上生成时间轴。`,
  },
  {
    name: 'swot',
    description: 'SWOT 分析',
    arguments: [arg('subject', '分析对象（可选）')],
    build: (args) =>
      `请对${args['subject'] ? `“${args['subject']}”` : '当前主题'}进行 SWOT 分析：在白板上生成优势 / 劣势 / 机会 / 威胁四象限便签。`,
  },
  {
    name: 'retrospective',
    description: '回顾',
    arguments: [],
    build: () =>
      '请引导团队回顾：分别整理「进展顺利（Keep）」「遇到问题（Problem）」「改进措施（Try）」三类便签，并投票选出最优先的改进项。',
  },
  {
    name: 'kanban',
    description: '看板',
    arguments: [],
    build: () => '请把白板内容整理为看板：创建「待办 / 进行中 / 已完成」三列，并把任务便签移动到对应列。',
  },
];

const PROMPT_INDEX = new Map(PROMPT_DEFINITIONS.map((prompt) => [prompt.name, prompt]));

export class PromptRegistry {
  /** `prompts/list`（模板为静态目录，不分页）。 */
  list(): { prompts: PromptSummary[]; nextCursor: null } {
    return {
      prompts: PROMPT_DEFINITIONS.map((prompt) => ({
        name: prompt.name,
        description: prompt.description,
        arguments: prompt.arguments.map((a) => ({ ...a })),
      })),
      nextCursor: null,
    };
  }

  /**
   * `prompts/get`：
   * - 未知模板 → -32602；缺失必填参数 → -32602；参数值必须为字符串。
   */
  get(name: string, args: Record<string, string>): PromptGetResult {
    const prompt = PROMPT_INDEX.get(name);
    if (!prompt) {
      throw RpcError.invalidParams(`Unknown prompt: ${name}`, { name });
    }
    for (const argument of prompt.arguments) {
      if (!argument.required) continue;
      const value = args[argument.name];
      if (typeof value !== 'string' || value.length === 0) {
        throw RpcError.invalidParams(`Prompt ${name} requires argument "${argument.name}"`, {
          name,
          argument: argument.name,
        });
      }
    }
    return {
      description: prompt.description,
      messages: [{ role: 'user', content: { type: 'text', text: prompt.build(args) } }],
    };
  }
}
