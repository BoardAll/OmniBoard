import { randomBytes } from 'node:crypto';

/**
 * Opaque globally-unique ids with a readable prefix (e.g. `board_9f2...`),
 * matching the id style used across 《OpenAPI规范.md》 examples.
 */
export function newId(prefix: string): string {
  return `${prefix}_${randomBytes(12).toString('base64url')}`;
}

export function newRequestId(): string {
  return newId('req');
}
