/**
 * API error model.
 *
 * Aligned with 《OpenAPI规范.md》 §4.10 / §11 (错误码完整列表) and the error
 * shape of `core/tools/schema/command.schema.json` (`{ code, message, details }`).
 * The REST envelope wraps it as `{ ok: false, data: null, error, meta }`.
 */

/** Machine readable error codes (OpenAPI spec §11). */
export type ApiErrorCode =
  | 'INVALID_ARGUMENT'
  | 'UNAUTHENTICATED'
  | 'PERMISSION_DENIED'
  | 'NOT_FOUND'
  | 'CONFLICT'
  | 'UNPROCESSABLE'
  | 'RATE_LIMITED'
  | 'INTERNAL_ERROR'
  | 'UNAVAILABLE'
  | 'TIMEOUT'
  | 'CANCELLED'
  | 'RESOURCE_EXHAUSTED'
  | 'NOT_SUPPORTED';

/** HTTP status for every error code (single source of truth). */
export const ERROR_HTTP_STATUS: Record<ApiErrorCode, number> = {
  INVALID_ARGUMENT: 400,
  UNAUTHENTICATED: 401,
  PERMISSION_DENIED: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  UNPROCESSABLE: 422,
  RATE_LIMITED: 429,
  INTERNAL_ERROR: 500,
  UNAVAILABLE: 503,
  TIMEOUT: 504,
  CANCELLED: 499,
  RESOURCE_EXHAUSTED: 429,
  NOT_SUPPORTED: 501,
};

export interface ApiErrorShape {
  code: ApiErrorCode;
  message: string;
  detail?: unknown;
}

/** Error thrown by services/routes and converted by the unified error handler. */
export class ApiError extends Error implements ApiErrorShape {
  readonly code: ApiErrorCode;
  readonly detail?: unknown;

  constructor(code: ApiErrorCode, message: string, detail?: unknown) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.detail = detail;
  }

  get status(): number {
    return ERROR_HTTP_STATUS[this.code];
  }

  static invalidArgument(message: string, detail?: unknown): ApiError {
    return new ApiError('INVALID_ARGUMENT', message, detail);
  }

  static unauthenticated(message = 'Authentication required', detail?: unknown): ApiError {
    return new ApiError('UNAUTHENTICATED', message, detail);
  }

  static permissionDenied(message = 'Permission denied', detail?: unknown): ApiError {
    return new ApiError('PERMISSION_DENIED', message, detail);
  }

  static notFound(message = 'Resource not found', detail?: unknown): ApiError {
    return new ApiError('NOT_FOUND', message, detail);
  }

  static conflict(message = 'Resource conflict', detail?: unknown): ApiError {
    return new ApiError('CONFLICT', message, detail);
  }

  static unprocessable(message = 'Request cannot be processed', detail?: unknown): ApiError {
    return new ApiError('UNPROCESSABLE', message, detail);
  }

  static rateLimited(message = 'Rate limit exceeded', detail?: unknown): ApiError {
    return new ApiError('RATE_LIMITED', message, detail);
  }

  static internal(message = 'Internal error', detail?: unknown): ApiError {
    return new ApiError('INTERNAL_ERROR', message, detail);
  }

  static notSupported(message = 'Not supported', detail?: unknown): ApiError {
    return new ApiError('NOT_SUPPORTED', message, detail);
  }

  /** 破坏性操作缺少显式确认 —— 422 UNPROCESSABLE（OpenAPI §4.10 无专用码）。 */
  static confirmationRequired(message: string, detail?: unknown): ApiError {
    return new ApiError('UNPROCESSABLE', message, {
      confirmationRequired: true,
      hint: 'retry with ?confirm=true',
      ...(typeof detail === 'object' && detail !== null ? (detail as object) : {}),
    });
  }
}

export function isApiError(value: unknown): value is ApiError {
  return value instanceof ApiError;
}

/** Normalise any thrown value into an `ApiErrorShape` (never leaks internals). */
export function toApiErrorShape(value: unknown): ApiErrorShape {
  if (isApiError(value)) {
    return { code: value.code, message: value.message, ...(value.detail === undefined ? {} : { detail: value.detail }) };
  }
  if (value instanceof Error) {
    // Do NOT leak stack traces / driver messages to clients.
    return { code: 'INTERNAL_ERROR', message: 'Internal error' };
  }
  return { code: 'INTERNAL_ERROR', message: 'Internal error' };
}
