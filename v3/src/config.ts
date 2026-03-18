import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, basename, resolve } from 'path';

export interface TrackerConfig {
  type: 'linear' | 'jira' | 'none';
  title_prefix?: string;
  labels?: string[];
}

export interface LinearConfig {
  team_key?: string;
  project_name?: string;
  workflow?: Record<string, string>;
  labels?: Record<string, string>;
  auth?: { api_key_env?: string };
}

export interface JiraConfig {
  project_key?: string;
  issue_type?: string;
  subtask_issue_type?: string;
  status?: Record<string, string>;
  labels?: string[];
  auth?: {
    base_url_env?: string;
    email_env?: string;
    api_token_env?: string;
  };
}

export interface ProjectJson {
  project_id?: string;
  tracker?: TrackerConfig;
  linear?: LinearConfig;
  jira?: JiraConfig;
}

export class Config {
  readonly projectPath: string;
  readonly projectName: string;
  readonly orchDir: string;
  private projectJson: ProjectJson | null = null;

  constructor(projectPath: string) {
    this.projectPath = resolve(projectPath);
    this.projectName = basename(this.projectPath);
    this.orchDir = join(this.projectPath, '.orch');
  }

  loadProjectJson(): ProjectJson {
    if (this.projectJson) return this.projectJson;
    this.projectJson = this.readProjectJson();
    return this.projectJson;
  }

  private readProjectJson(): ProjectJson {
    const configPath = join(this.orchDir, 'project.json');
    if (existsSync(configPath)) {
      try {
        return JSON.parse(readFileSync(configPath, 'utf-8'));
      } catch {
        return {};
      }
    }
    return {};
  }

  reload(): void {
    this.projectJson = null;
  }

  save(updates: Partial<ProjectJson>): void {
    // Merge updates into existing config
    const existing = this.readProjectJson();
    const merged = { ...existing, ...updates };

    // Ensure .orch directory exists
    mkdirSync(this.orchDir, { recursive: true });

    const configPath = join(this.orchDir, 'project.json');
    writeFileSync(configPath, JSON.stringify(merged, null, 2) + '\n', 'utf-8');

    // Reload cached config
    this.projectJson = merged;
  }

  get projectId(): string {
    return this.loadProjectJson().project_id || this.projectName;
  }

  get trackerType(): 'linear' | 'jira' | 'none' {
    const cfg = this.loadProjectJson();
    if (cfg.tracker?.type) return cfg.tracker.type;
    if (cfg.linear?.team_key) return 'linear';
    if (cfg.jira?.project_key) return 'jira';
    return 'none';
  }

  get linearConfig(): LinearConfig | null {
    const cfg = this.loadProjectJson();
    return cfg.linear || null;
  }

  get jiraConfig(): JiraConfig | null {
    const cfg = this.loadProjectJson();
    return cfg.jira || null;
  }

  get trackerTitlePrefix(): string {
    return this.loadProjectJson().tracker?.title_prefix || '[AI]';
  }

  // Clockify
  get clockifyApiKey(): string | undefined {
    return process.env.CLOCKIFY_API_KEY;
  }

  get clockifyWorkspaceId(): string {
    return 'REDACTED-CLOCKIFY-WORKSPACE-ID';
  }

  get clockifyUserId(): string {
    return 'REDACTED-CLOCKIFY-USER-ID';
  }

  // Linear
  get linearApiKey(): string | undefined {
    const envVar = this.linearConfig?.auth?.api_key_env || 'LINEAR_API_KEY';
    return process.env[envVar];
  }

  // Jira
  get jiraBaseUrl(): string | undefined {
    const envVar = this.jiraConfig?.auth?.base_url_env || 'JIRA_BASE_URL';
    return process.env[envVar];
  }

  get jiraEmail(): string | undefined {
    const envVar = this.jiraConfig?.auth?.email_env || 'JIRA_EMAIL';
    return process.env[envVar];
  }

  get jiraApiToken(): string | undefined {
    const envVar = this.jiraConfig?.auth?.api_token_env || 'JIRA_API_TOKEN';
    return process.env[envVar];
  }
}
