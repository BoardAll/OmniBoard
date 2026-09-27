/**
 * 极简日志工具（《MCP_Server详细设计》§4.1）。
 *
 * - stdio 传输下 stdout 只能输出协议消息，因此所有日志一律写入 stderr；
 * - 不打印凭据 / token / 完整参数（脱敏由调用方保证，仅输出定位信息）。
 */

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface Logger {
  debug(message: string, meta?: Record<string, unknown>): void;
  info(message: string, meta?: Record<string, unknown>): void;
  warn(message: string, meta?: Record<string, unknown>): void;
  error(message: string, meta?: Record<string, unknown>): void;
}

const LEVEL_ORDER: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export interface StderrLoggerOptions {
  /** 日志前缀，默认 `[mcp]`。 */
  prefix?: string;
  /** 最低输出级别，默认 `info`。 */
  level?: LogLevel;
  /** 输出目标（默认 process.stderr；测试可注入收集器）。 */
  write?: (line: string) => void;
}

/** 创建 stderr 日志器；stdout 永远留给协议消息。 */
export function createStderrLogger(options: StderrLoggerOptions = {}): Logger {
  const prefix = options.prefix ?? '[mcp]';
  const minLevel = LEVEL_ORDER[options.level ?? 'info'];
  const write = options.write ?? ((line: string): void => void process.stderr.write(line));

  const emit = (level: LogLevel, message: string, meta?: Record<string, unknown>): void => {
    if (LEVEL_ORDER[level] < minLevel) return;
    const suffix = meta && Object.keys(meta).length > 0 ? ` ${JSON.stringify(meta)}` : '';
    write(`${new Date().toISOString()} ${prefix} ${level.toUpperCase()} ${message}${suffix}\n`);
  };

  return {
    debug: (message, meta) => emit('debug', message, meta),
    info: (message, meta) => emit('info', message, meta),
    warn: (message, meta) => emit('warn', message, meta),
    error: (message, meta) => emit('error', message, meta),
  };
}

/** 空日志器（测试 / 嵌入场景）。 */
export const NULL_LOGGER: Logger = {
  debug(): void {},
  info(): void {},
  warn(): void {},
  error(): void {},
};
