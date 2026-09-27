import type { ZodTypeAny } from 'zod';
import { z } from 'zod';
import { ApiError } from './errors.js';

/**
 * Request body validation.
 *
 * Converts zod issues into `INVALID_ARGUMENT` (400) with a compact, stable
 * `detail.issues` list — field paths + messages, never raw stack traces
 * (《OpenAPI规范.md》§4.10 / §11).
 *
 * 返回类型为 zod 的 **输出** 类型（`z.output<S>`）：带 `.default()` 的字段
 * 在解析后必填，路由层因此拿到与 service 层入参完全一致的形状。
 */
export function parseBody<S extends ZodTypeAny>(schema: S, body: unknown): z.output<S> {
  const result = schema.safeParse(body);
  if (!result.success) {
    throw ApiError.invalidArgument('Request validation failed', {
      issues: result.error.issues.map((issue) => ({
        path: issue.path.join('.'),
        code: issue.code,
        message: issue.message,
      })),
    });
  }
  return result.data;
}
