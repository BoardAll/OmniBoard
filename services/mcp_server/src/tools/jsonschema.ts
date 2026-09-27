/**
 * JSON Schema 子集校验器（用于 tools/call 的 inputSchema 校验）。
 *
 * 不引入 ajv 等新依赖（依赖已锁定）；仅实现工具注册表实际用到的关键字：
 * - `type`：object / array / string / number / integer / boolean / null
 * - object：`properties` / `required` / `additionalProperties`（false / schema）
 * - array：`items` / `minItems` / `maxItems`
 * - string：`minLength` / `maxLength` / `pattern`
 * - number：`minimum` / `maximum`
 * - 通用：`enum`
 *
 * 未识别的关键字被忽略（前向兼容）；校验失败返回问题列表（不抛异常）。
 */

export interface SchemaIssue {
  path: string;
  message: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function joinPath(base: string, key: string): string {
  return `${base}.${key}`;
}

function matchesType(type: string, value: unknown): boolean {
  switch (type) {
    case 'object':
      return isRecord(value);
    case 'array':
      return Array.isArray(value);
    case 'string':
      return typeof value === 'string';
    case 'number':
      return typeof value === 'number' && Number.isFinite(value);
    case 'integer':
      return typeof value === 'number' && Number.isInteger(value);
    case 'boolean':
      return typeof value === 'boolean';
    case 'null':
      return value === null;
    default:
      return true;
  }
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((item, index) => deepEqual(item, b[index]));
  }
  if (isRecord(a) && isRecord(b)) {
    const aKeys = Object.keys(a);
    const bKeys = Object.keys(b);
    return aKeys.length === bKeys.length && aKeys.every((key) => deepEqual(a[key], b[key]));
  }
  return false;
}

function validateNode(schema: unknown, value: unknown, path: string, issues: SchemaIssue[]): void {
  if (!isRecord(schema)) return;

  const type = schema['type'];
  if (typeof type === 'string' && !matchesType(type, value)) {
    issues.push({ path, message: `must be of type ${type}` });
    return;
  }

  const enumValues = schema['enum'];
  if (Array.isArray(enumValues) && !enumValues.some((candidate) => deepEqual(candidate, value))) {
    issues.push({ path, message: 'must be one of the allowed enum values' });
  }

  if (typeof value === 'string') {
    const minLength = schema['minLength'];
    const maxLength = schema['maxLength'];
    const pattern = schema['pattern'];
    if (typeof minLength === 'number' && value.length < minLength) {
      issues.push({ path, message: `must be at least ${minLength} characters long` });
    }
    if (typeof maxLength === 'number' && value.length > maxLength) {
      issues.push({ path, message: `must be at most ${maxLength} characters long` });
    }
    if (typeof pattern === 'string') {
      try {
        if (!new RegExp(pattern).test(value)) {
          issues.push({ path, message: `must match pattern ${pattern}` });
        }
      } catch {
        // 忽略非法 pattern（由 schema 生产方负责）
      }
    }
  }

  if (typeof value === 'number') {
    const minimum = schema['minimum'];
    const maximum = schema['maximum'];
    if (typeof minimum === 'number' && value < minimum) {
      issues.push({ path, message: `must be >= ${minimum}` });
    }
    if (typeof maximum === 'number' && value > maximum) {
      issues.push({ path, message: `must be <= ${maximum}` });
    }
  }

  if (Array.isArray(value)) {
    const minItems = schema['minItems'];
    const maxItems = schema['maxItems'];
    if (typeof minItems === 'number' && value.length < minItems) {
      issues.push({ path, message: `must contain at least ${minItems} items` });
    }
    if (typeof maxItems === 'number' && value.length > maxItems) {
      issues.push({ path, message: `must contain at most ${maxItems} items` });
    }
    const items = schema['items'];
    if (isRecord(items)) {
      value.forEach((item, index) => validateNode(items, item, `${path}[${index}]`, issues));
    }
  }

  if (isRecord(value)) {
    const properties = isRecord(schema['properties']) ? schema['properties'] : {};
    const required = Array.isArray(schema['required'])
      ? schema['required'].filter((key): key is string => typeof key === 'string')
      : [];
    for (const key of required) {
      if (!(key in value)) issues.push({ path: joinPath(path, key), message: 'is required' });
    }
    const additional = schema['additionalProperties'];
    for (const [key, item] of Object.entries(value)) {
      const propertySchema = properties[key];
      if (propertySchema !== undefined) {
        validateNode(propertySchema, item, joinPath(path, key), issues);
      } else if (additional === false) {
        issues.push({ path: joinPath(path, key), message: 'is not allowed' });
      } else if (isRecord(additional)) {
        validateNode(additional, item, joinPath(path, key), issues);
      }
    }
  }
}

/** 校验 `value` 是否符合 `schema` 子集；返回问题列表（空 = 通过）。 */
export function validateAgainstSchema(schema: unknown, value: unknown): SchemaIssue[] {
  const issues: SchemaIssue[] = [];
  validateNode(schema, value, '$', issues);
  return issues;
}
