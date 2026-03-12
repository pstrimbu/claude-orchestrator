import { appendFileSync, readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';

interface HistoryEntry {
  ts: string;
  cmd: string;
}

export class CommandHistoryService {
  private readonly filePath: string;
  private _lastFlushTs: string | null = null;
  private readonly flushTsPath: string;

  constructor(orchDir: string) {
    mkdirSync(orchDir, { recursive: true });
    this.filePath = join(orchDir, 'command-history.jsonl');
    this.flushTsPath = join(orchDir, 'command-history-flushed.txt');

    // Load last flush timestamp
    if (existsSync(this.flushTsPath)) {
      try {
        this._lastFlushTs = readFileSync(this.flushTsPath, 'utf-8').trim();
      } catch { /* ignore */ }
    }
  }

  append(cmd: string): void {
    const entry: HistoryEntry = { ts: new Date().toISOString(), cmd };
    appendFileSync(this.filePath, JSON.stringify(entry) + '\n');
  }

  getRecent(n = 50): HistoryEntry[] {
    return this.readAll().slice(-n);
  }

  getSince(isoTimestamp: string): HistoryEntry[] {
    return this.readAll().filter((e) => e.ts > isoTimestamp);
  }

  getSinceLastFlush(): HistoryEntry[] {
    if (this._lastFlushTs) {
      return this.getSince(this._lastFlushTs);
    }
    return this.readAll();
  }

  markFlushed(): void {
    this._lastFlushTs = new Date().toISOString();
    writeFileSync(this.flushTsPath, this._lastFlushTs);
  }

  get lastFlushTs(): string | null {
    return this._lastFlushTs;
  }

  private readAll(): HistoryEntry[] {
    if (!existsSync(this.filePath)) return [];
    try {
      const lines = readFileSync(this.filePath, 'utf-8').trim().split('\n');
      return lines
        .filter((l) => l.length > 0)
        .map((l) => {
          try { return JSON.parse(l) as HistoryEntry; }
          catch { return null; }
        })
        .filter((e): e is HistoryEntry => e !== null);
    } catch {
      return [];
    }
  }
}
