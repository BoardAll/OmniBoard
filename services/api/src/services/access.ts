import { ApiError } from '../lib/errors.js';
import type { Scope } from '../db/schema.js';

/**
 * Access control helpers shared by services.
 *
 * 《OpenAPI规范.md》§3.4：白板级 ACL + Token 可限制 Scope / 白板范围。
 * Token 白板范围（`boards`）非空时，任何跨出范围的白板访问返回 403。
 */

export interface PrincipalContext {
  userId: string;
  scopes: readonly string[];
  /** null = 不限白板范围 */
  boards: readonly string[] | null;
}

export function hasScope(principal: PrincipalContext, scope: Scope | string): boolean {
  return principal.scopes.includes(scope);
}

export function assertBoardInRange(principal: PrincipalContext, boardId: string): void {
  if (principal.boards && !principal.boards.includes(boardId)) {
    throw ApiError.permissionDenied('Token is not scoped to this board', { boardId });
  }
}

export function boardInRange(principal: PrincipalContext, boardId: string): boolean {
  return principal.boards === null || principal.boards.includes(boardId);
}
