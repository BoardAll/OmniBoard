import type { Scope } from '../db/schema.js';

/**
 * Request-scoped augmentation: `req.principal` is attached by the auth
 * middleware (`src/middleware/auth.ts`).
 */
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      principal?: {
        userId: string;
        scopes: Scope[];
        boards: string[] | null;
        kind: 'jwt' | 'api-key';
        tenantId: string | null;
        rateLimit: number | null;
      };
      requestId?: string;
    }
  }
}

export {};
