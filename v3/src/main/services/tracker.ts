import type { Config } from '../config';

export interface Issue {
  id: string;
  key: string;
  title: string;
  status: string;
  priority: string;
  url: string;
  assignee?: string;
}

export interface TrackerService {
  readonly type: 'linear' | 'jira' | 'none';
  readonly enabled: boolean;
  readonly teamKey: string;
  listIssues(options?: { status?: string; assignedToMe?: boolean; limit?: number }): Promise<Issue[]>;
  getIssue(key: string): Promise<Issue | null>;
  updateStatus(key: string, status: string): Promise<void>;
  addComment(key: string, comment: string): Promise<void>;
  createIssue(title: string, description: string): Promise<Issue>;
}

// Linear GraphQL tracker
export class LinearTracker implements TrackerService {
  readonly type = 'linear' as const;
  readonly enabled: boolean;
  readonly teamKey: string;
  private apiKey: string;

  constructor(private config: Config) {
    this.enabled = !!config.linearApiKey && !!config.linearConfig?.team_key;
    this.teamKey = config.linearConfig?.team_key || '';
    this.apiKey = config.linearApiKey || '';
  }

  async listIssues(options?: { status?: string; assignedToMe?: boolean; limit?: number }): Promise<Issue[]> {
    const limit = options?.limit || 25;
    const filter: Record<string, unknown> = {
      team: { key: { eq: this.teamKey } },
      state: { type: { nin: ['completed', 'canceled'] } },
    };

    if (options?.assignedToMe) {
      filter.assignee = { isMe: { eq: true } };
    }

    const query = `query($filter: IssueFilter, $first: Int) {
      issues(filter: $filter, first: $first, orderBy: updatedAt) {
        nodes {
          id identifier title url
          state { name }
          priority priorityLabel
          assignee { name }
        }
      }
    }`;

    const data = await this.gql(query, { filter, first: limit });
    return (data.issues?.nodes || []).map((n: any) => ({
      id: n.id,
      key: n.identifier,
      title: n.title,
      status: n.state?.name || 'Unknown',
      priority: n.priorityLabel || 'None',
      url: n.url,
      assignee: n.assignee?.name,
    }));
  }

  async getIssue(key: string): Promise<Issue | null> {
    const query = `query($key: String!) {
      issueSearch(query: $key, first: 1) {
        nodes {
          id identifier title url
          state { name }
          priority priorityLabel
          assignee { name }
        }
      }
    }`;
    const data = await this.gql(query, { key });
    const node = data.issueSearch?.nodes?.[0];
    if (!node) return null;
    return {
      id: node.id,
      key: node.identifier,
      title: node.title,
      status: node.state?.name || 'Unknown',
      priority: node.priorityLabel || 'None',
      url: node.url,
      assignee: node.assignee?.name,
    };
  }

  async updateStatus(key: string, status: string): Promise<void> {
    const issue = await this.getIssue(key);
    if (!issue) throw new Error(`Issue ${key} not found`);

    // Resolve state ID
    const statesQuery = `query($teamKey: String!) {
      teams(filter: { key: { eq: $teamKey } }) {
        nodes { states { nodes { id name } } }
      }
    }`;
    const statesData = await this.gql(statesQuery, { teamKey: this.teamKey });
    const states = statesData.teams?.nodes?.[0]?.states?.nodes || [];
    const target = states.find((s: any) => s.name.toLowerCase() === status.toLowerCase());
    if (!target) throw new Error(`State "${status}" not found`);

    await this.gql(
      `mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }`,
      { id: issue.id, stateId: target.id },
    );
  }

  async addComment(key: string, comment: string): Promise<void> {
    const issue = await this.getIssue(key);
    if (!issue) throw new Error(`Issue ${key} not found`);

    await this.gql(
      `mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success } }`,
      { issueId: issue.id, body: comment },
    );
  }

  async createIssue(title: string, description: string): Promise<Issue> {
    // Get team ID
    const teamQuery = `query($key: String!) { teams(filter: { key: { eq: $key } }) { nodes { id } } }`;
    const teamData = await this.gql(teamQuery, { key: this.teamKey });
    const teamId = teamData.teams?.nodes?.[0]?.id;
    if (!teamId) throw new Error(`Team ${this.teamKey} not found`);

    const prefix = this.config.trackerTitlePrefix;
    const mutation = `mutation($teamId: String!, $title: String!, $description: String) {
      issueCreate(input: { teamId: $teamId, title: $title, description: $description }) {
        success issue { id identifier title url state { name } priorityLabel }
      }
    }`;
    const data = await this.gql(mutation, { teamId, title: `${prefix} ${title}`, description });
    const n = data.issueCreate?.issue;
    return {
      id: n.id,
      key: n.identifier,
      title: n.title,
      status: n.state?.name || 'Backlog',
      priority: n.priorityLabel || 'None',
      url: n.url,
    };
  }

  private async gql(query: string, variables: Record<string, unknown> = {}): Promise<any> {
    const res = await fetch('https://api.linear.app/graphql', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: this.apiKey,
      },
      body: JSON.stringify({ query, variables }),
    });
    if (!res.ok) throw new Error(`Linear API ${res.status}: ${await res.text()}`);
    const json = await res.json();
    if (json.errors?.length) throw new Error(json.errors[0].message);
    return json.data;
  }
}

// Jira REST tracker
export class JiraTracker implements TrackerService {
  readonly type = 'jira' as const;
  readonly enabled: boolean;
  readonly teamKey: string;
  private baseUrl: string;
  private authHeader: string;

  constructor(private config: Config) {
    this.enabled = !!config.jiraBaseUrl && !!config.jiraEmail && !!config.jiraApiToken;
    this.teamKey = config.jiraConfig?.project_key || '';
    this.baseUrl = config.jiraBaseUrl || '';
    const creds = Buffer.from(`${config.jiraEmail || ''}:${config.jiraApiToken || ''}`).toString('base64');
    this.authHeader = `Basic ${creds}`;
  }

  async listIssues(options?: { status?: string; assignedToMe?: boolean; limit?: number }): Promise<Issue[]> {
    const limit = options?.limit || 25;
    let jql = `project = ${this.teamKey} AND status != Done`;
    if (options?.assignedToMe) jql += ' AND assignee = currentUser()';
    if (options?.status) jql += ` AND status = "${options.status}"`;
    jql += ' ORDER BY updated DESC';

    const data = await this.api('GET', `/search?jql=${encodeURIComponent(jql)}&maxResults=${limit}&fields=summary,status,priority,assignee`);
    return (data.issues || []).map((i: any) => ({
      id: i.id,
      key: i.key,
      title: i.fields.summary,
      status: i.fields.status?.name || 'Unknown',
      priority: i.fields.priority?.name || 'None',
      url: `${this.baseUrl}/browse/${i.key}`,
      assignee: i.fields.assignee?.displayName,
    }));
  }

  async getIssue(key: string): Promise<Issue | null> {
    try {
      const data = await this.api('GET', `/issue/${key}?fields=summary,status,priority,assignee`);
      return {
        id: data.id,
        key: data.key,
        title: data.fields.summary,
        status: data.fields.status?.name || 'Unknown',
        priority: data.fields.priority?.name || 'None',
        url: `${this.baseUrl}/browse/${data.key}`,
        assignee: data.fields.assignee?.displayName,
      };
    } catch {
      return null;
    }
  }

  async updateStatus(key: string, status: string): Promise<void> {
    // Get available transitions
    const data = await this.api('GET', `/issue/${key}/transitions`);
    const semanticMap = this.config.jiraConfig?.status || {};
    const targetName = semanticMap[status] || status;
    const transition = data.transitions.find(
      (t: any) => t.name.toLowerCase() === targetName.toLowerCase() || t.to.name.toLowerCase() === targetName.toLowerCase(),
    );
    if (!transition) throw new Error(`Transition to "${status}" not available`);

    await this.api('POST', `/issue/${key}/transitions`, { transition: { id: transition.id } });
  }

  async addComment(key: string, comment: string): Promise<void> {
    await this.api('POST', `/issue/${key}/comment`, {
      body: {
        type: 'doc',
        version: 1,
        content: [{ type: 'paragraph', content: [{ type: 'text', text: comment }] }],
      },
    });
  }

  async createIssue(title: string, description: string): Promise<Issue> {
    const prefix = this.config.trackerTitlePrefix;
    const issueType = this.config.jiraConfig?.issue_type || 'Task';
    const data = await this.api('POST', '/issue', {
      fields: {
        project: { key: this.teamKey },
        summary: `${prefix} ${title}`,
        issuetype: { name: issueType },
        description: {
          type: 'doc',
          version: 1,
          content: [{ type: 'paragraph', content: [{ type: 'text', text: description }] }],
        },
      },
    });
    return {
      id: data.id,
      key: data.key,
      title: `${prefix} ${title}`,
      status: 'To Do',
      priority: 'Medium',
      url: `${this.baseUrl}/browse/${data.key}`,
    };
  }

  private async api(method: string, path: string, body?: unknown): Promise<any> {
    const url = `${this.baseUrl}/rest/api/3${path}`;
    const res = await fetch(url, {
      method,
      headers: {
        Authorization: this.authHeader,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`Jira API ${res.status}: ${await res.text()}`);
    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }
}

// No-op tracker
export class NullTracker implements TrackerService {
  readonly type = 'none' as const;
  readonly enabled = false;
  readonly teamKey = '';
  async listIssues(): Promise<Issue[]> { return []; }
  async getIssue(): Promise<Issue | null> { return null; }
  async updateStatus(): Promise<void> {}
  async addComment(): Promise<void> {}
  async createIssue(): Promise<Issue> { throw new Error('No tracker configured'); }
}

export function createTracker(config: Config): TrackerService {
  switch (config.trackerType) {
    case 'linear': return new LinearTracker(config);
    case 'jira': return new JiraTracker(config);
    default: return new NullTracker();
  }
}
