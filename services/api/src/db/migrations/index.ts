/**
 * Database migrations — placeholder (Wave 2.8).
 *
 * Wave 2.8 使用内存仓库（`src/db/memory.ts` 的 `createMemoryStore`），因此这里
 * 只保留迁移框架的占位定义。
 *
 * Wave 4 接真实 DB：
 *  - 目标：PostgreSQL（主存储）+ Redis（限流/幂等缓存）+ 对象存储（导出文件）
 *  - 本目录将承载 `0001_init.sql` 等迁移脚本与 `migrate.ts` 执行器；
 *  - `DataStore`（`src/db/memory.ts`）接口保持不变，仅替换实现。
 */
export interface Migration {
  id: string;
  description: string;
  sql: string;
}

/** 当前无真实迁移（Wave 4 填充）。 */
export const MIGRATIONS: readonly Migration[] = [];

export const MIGRATIONS_PLACEHOLDER = 'Wave 4 接真实 DB — 见 docs/安全与合规设计.md §5 与 infra 设计。';
