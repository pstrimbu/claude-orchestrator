import type { Issue } from './services/tracker';

export interface StatusBarState {
  currentIssue: Issue | null;
  gitBranch: string;
  gitDirty: boolean;
}
