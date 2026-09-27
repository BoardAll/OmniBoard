/**
 * stdio 传输（《MCP_Server详细设计》§4.2）。
 *
 * 协议：换行分隔 JSON（JSON-RPC 消息逐行，stdout 仅允许协议消息）。
 * - 日志 / 审计一律走 stderr（见 log.ts / audit.ts）；
 * - 行处理按到达顺序串行执行（单写者队列，避免响应乱序）；
 * - 通知不产生输出；stdin 结束 → 触发 onClose。
 */

import { createInterface, type Interface } from 'node:readline';
import type { McpDispatcher, DispatchContext } from '../dispatcher.js';
import { notification, type JsonRpcResponse } from '../protocol/jsonrpc.js';
import { NULL_LOGGER, type Logger } from '../log.js';

export interface StdioTransportOptions {
  dispatcher: McpDispatcher;
  /** 固定上下文（stdio 为进程级单会话）。 */
  context: DispatchContext;
  /** 默认 process.stdin（测试注入 PassThrough）。 */
  input?: NodeJS.ReadableStream;
  /** 默认 process.stdout（测试注入收集器）。 */
  output?: NodeJS.WritableStream;
  logger?: Logger;
  /** stdin 关闭且队列排空后触发。 */
  onClose?: () => void;
}

export class StdioTransport {
  private readonly dispatcher: McpDispatcher;
  private readonly context: DispatchContext;
  private readonly input: NodeJS.ReadableStream;
  private readonly output: NodeJS.WritableStream;
  private readonly logger: Logger;
  private readonly onClose: (() => void) | undefined;

  private reader: Interface | null = null;
  private queue: Promise<void> = Promise.resolve();
  private closed = false;

  constructor(options: StdioTransportOptions) {
    this.dispatcher = options.dispatcher;
    this.context = options.context;
    this.input = options.input ?? process.stdin;
    this.output = options.output ?? process.stdout;
    this.logger = options.logger ?? NULL_LOGGER;
    this.onClose = options.onClose;
  }

  /** 开始读取 stdin（幂等）。 */
  start(): void {
    if (this.reader) return;
    this.reader = createInterface({ input: this.input, crlfDelay: Infinity });
    this.reader.on('line', (line: string) => this.enqueue(line));
    this.reader.on('close', () => this.shutdown());
    this.logger.info('stdio transport ready', { sessionId: this.context.sessionId });
  }

  /** 队列排空后关闭（等待 stdin 关闭时调用）。 */
  private shutdown(): void {
    this.queue
      .catch(() => undefined)
      .then(() => {
        this.closed = true;
        this.logger.info('stdio transport closed', { sessionId: this.context.sessionId });
        this.onClose?.();
      });
  }

  /** 主动停止（测试 / 嵌入）：关闭读端，仍在处理中的消息会跑完。 */
  stop(): void {
    this.reader?.close();
  }

  /** 服务端 → 客户端通知（§7.4 resources/updated 等）。 */
  notify(method: string, params?: unknown): void {
    this.writeLine(JSON.stringify(notification(method, params)));
  }

  private enqueue(line: string): void {
    const raw = line.trim();
    if (raw.length === 0) return;
    this.queue = this.queue
      .then(() => this.process(raw))
      .catch((error: unknown) => {
        this.logger.error('stdio message processing failed', {
          message: error instanceof Error ? error.message : 'unknown error',
        });
      });
  }

  private async process(raw: string): Promise<void> {
    if (this.closed) return;
    let response: JsonRpcResponse | JsonRpcResponse[] | null;
    try {
      response = await this.dispatcher.handleRaw(raw, this.context);
    } catch (error) {
      // handleRaw 内部已兜底；此分支仅为防御性保护（绝不向 stdout 泄漏堆栈）。
      this.logger.error('stdio dispatch failed', {
        message: error instanceof Error ? error.message : 'unknown error',
      });
      return;
    }
    if (response === null) return;
    this.writeLine(JSON.stringify(response));
  }

  private writeLine(line: string): void {
    this.output.write(`${line}\n`);
  }
}
