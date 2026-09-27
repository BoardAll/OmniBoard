import { ApiError } from '../lib/errors.js';
import { newId } from '../lib/ids.js';
import type { DataStore } from '../db/memory.js';
import type { CreateExportInput, ExportJob } from '../db/schema.js';
import type { PrincipalContext } from './access.js';
import type { BoardService } from './boardService.js';
import type { PageService } from './pageService.js';

/**
 * Exports 业务逻辑（《OpenAPI规范.md》§5.6）。
 *
 * Wave 2.8：导出任务在内存中同步“完成”，`download` 返回内联的占位内容
 * （base64）。Wave 4 由渲染器/转换服务（services/convert）生成真实文件并经
 * 对象存储下发，接口形状保持不变。
 */

export interface ExportDownload {
  id: string;
  format: string;
  fileName: string;
  sizeBytes: number;
  contentBase64: string;
}

export class ExportService {
  constructor(
    private readonly store: DataStore,
    private readonly boards: BoardService,
    private readonly pages: PageService,
  ) {}

  createBoardExport(principal: PrincipalContext, boardId: string, input: CreateExportInput): ExportJob {
    const board = this.boards.assertAccess(principal, boardId);
    const pages = input.pages ?? [...this.store.pages.values()].filter((p) => p.boardId === boardId).map((p) => p.id);
    return this.createJob(principal, {
      boardId: board.id,
      pageId: null,
      input,
      pages,
      label: board.name,
    });
  }

  createPageExport(principal: PrincipalContext, pageId: string, input: CreateExportInput): ExportJob {
    const { page } = this.pages.requirePage(principal, pageId);
    return this.createJob(principal, {
      boardId: page.boardId,
      pageId: page.id,
      input,
      pages: [page.id],
      label: page.name,
    });
  }

  get(principal: PrincipalContext, exportId: string): ExportJob {
    const job = this.requireJob(exportId);
    this.boards.assertAccess(principal, job.boardId ?? '', undefined);
    return job;
  }

  download(principal: PrincipalContext, exportId: string): ExportDownload {
    const job = this.get(principal, exportId);
    if (job.status !== 'completed') {
      throw ApiError.unprocessable('Export is not completed yet', { status: job.status });
    }
    const payload = this.renderPlaceholder(job);
    return {
      id: job.id,
      format: job.format,
      fileName: `${job.id}.${job.format === 'markdown' ? 'md' : job.format}`,
      sizeBytes: Buffer.byteLength(payload, 'utf8'),
      contentBase64: Buffer.from(payload, 'utf8').toString('base64'),
    };
  }

  private createJob(
    principal: PrincipalContext,
    args: {
      boardId: string;
      pageId: string | null;
      input: CreateExportInput;
      pages: string[];
      label: string;
    },
  ): ExportJob {
    const now = new Date().toISOString();
    const job: ExportJob = {
      id: newId('exp'),
      boardId: args.boardId,
      pageId: args.pageId,
      format: args.input.format,
      quality: args.input.quality,
      includeAnnotations: args.input.includeAnnotations,
      pages: args.pages,
      status: 'completed',
      sizeBytes: 0,
      downloadUrl: null,
      createdAt: now,
      completedAt: now,
      requestedBy: principal.userId,
    };
    job.sizeBytes = Buffer.byteLength(this.renderPlaceholder(job), 'utf8');
    job.downloadUrl = `/v1/exports/${job.id}/download`;
    this.store.exportJobs.set(job.id, job);
    return job;
  }

  private renderPlaceholder(job: ExportJob): string {
    if (job.format === 'json') {
      const board = this.store.boards.get(job.boardId ?? '');
      const pages = [...this.store.pages.values()].filter((p) => p.boardId === job.boardId);
      const elements = [...this.store.elements.values()].filter((e) => e.boardId === job.boardId);
      return JSON.stringify(
        { board: board ?? null, pages, elements, exportedAt: new Date().toISOString() },
        null,
        2,
      );
    }
    // 其他格式：Wave 4 由 services/convert（PyMuPDF）生成真实文件。
    return `Whiteboard export placeholder (${job.format}, quality=${job.quality}, pages=${job.pages?.length ?? 0})`;
  }

  private requireJob(exportId: string): ExportJob {
    const job = this.store.exportJobs.get(exportId);
    if (!job) throw ApiError.notFound('Export not found', { exportId });
    return job;
  }
}
