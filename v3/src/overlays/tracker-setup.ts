import type { OverlayManager, OverlayItem } from '../overlay.js';
import type { Config } from '../config.js';

interface LinearTeam {
  id: string;
  key: string;
  name: string;
}

interface LinearProject {
  id: string;
  name: string;
}

interface LinearWorkflowState {
  id: string;
  name: string;
  type: string;
}

async function linearGql(apiKey: string, query: string, variables: Record<string, unknown> = {}): Promise<any> {
  const res = await fetch('https://api.linear.app/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: apiKey },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`Linear API ${res.status}`);
  const json = await res.json();
  if (json.errors?.length) throw new Error(json.errors[0].message);
  return json.data;
}

export function showTrackerSetup(
  overlay: OverlayManager,
  config: Config,
  onConfigured: () => void,
  onUpdate: () => void,
): void {
  overlay.show({
    title: 'Configure Issue Tracker',
    items: [
      { label: 'Select tracker type:', dimmed: true },
      { label: '', dimmed: true },
      {
        label: '[L] Linear',
        shortcut: 'l',
        action: () => setupLinear(overlay, config, onConfigured, onUpdate),
      },
      {
        label: '[J] Jira',
        shortcut: 'j',
        action: () => setupJira(overlay, config, onConfigured, onUpdate),
      },
      { label: '', dimmed: true },
      {
        label: '[N] No tracker',
        shortcut: 'n',
        action: () => {
          config.save({ tracker: { type: 'none' } });
          onConfigured();
          overlay.showMessage('Tracker disabled');
        },
      },
    ],
    onClose: onUpdate,
    footer: '[L] Linear  [J] Jira  [N] None',
  });
}

async function setupLinear(
  overlay: OverlayManager,
  config: Config,
  onConfigured: () => void,
  onUpdate: () => void,
): Promise<void> {
  // Check for API key
  const apiKey = process.env.LINEAR_API_KEY;
  if (!apiKey) {
    overlay.updateItems([
      { label: 'LINEAR_API_KEY not found in environment', dimmed: true },
      { label: '', dimmed: true },
      { label: 'To set up Linear:', dimmed: true },
      { label: '  1. Get an API key from Linear Settings > API', dimmed: true },
      { label: '  2. Add to your .env file:', dimmed: true },
      { label: '     LINEAR_API_KEY=lin_api_xxxxx', dimmed: true },
      { label: '  3. Restart orch3', dimmed: true },
      { label: '', dimmed: true },
      {
        label: '\u2190 Back',
        shortcut: 'b',
        action: () => showTrackerSetup(overlay, config, onConfigured, onUpdate),
      },
    ]);
    return;
  }

  // Discover teams
  overlay.setLoading(true);
  try {
    const data = await linearGql(apiKey, `query {
      teams { nodes { id key name } }
    }`);
    const teams: LinearTeam[] = data.teams?.nodes || [];
    overlay.setLoading(false);

    if (teams.length === 0) {
      overlay.updateItems([
        { label: 'No teams found in your Linear workspace', dimmed: true },
        { label: '', dimmed: true },
        {
          label: '\u2190 Back',
          shortcut: 'b',
          action: () => showTrackerSetup(overlay, config, onConfigured, onUpdate),
        },
      ]);
      return;
    }

    // Let user pick a team
    const items: OverlayItem[] = [
      { label: 'Select your Linear team:', dimmed: true },
      { label: '', dimmed: true },
    ];

    for (const team of teams) {
      items.push({
        label: `${team.key} — ${team.name}`,
        action: () => pickLinearProject(overlay, config, apiKey, team, onConfigured, onUpdate),
      });
    }

    items.push({ label: '', dimmed: true });
    items.push({
      label: '\u2190 Back',
      shortcut: 'b',
      action: () => showTrackerSetup(overlay, config, onConfigured, onUpdate),
    });

    overlay.updateItems(items);
  } catch (err: any) {
    overlay.setLoading(false);
    overlay.updateItems([
      { label: `Error connecting to Linear: ${err.message}`, dimmed: true },
      { label: '', dimmed: true },
      {
        label: '[R] Retry',
        shortcut: 'r',
        action: () => setupLinear(overlay, config, onConfigured, onUpdate),
      },
      {
        label: '\u2190 Back',
        shortcut: 'b',
        action: () => showTrackerSetup(overlay, config, onConfigured, onUpdate),
      },
    ]);
  }
}

async function pickLinearProject(
  overlay: OverlayManager,
  config: Config,
  apiKey: string,
  team: LinearTeam,
  onConfigured: () => void,
  onUpdate: () => void,
): Promise<void> {
  overlay.setLoading(true);
  try {
    // Fetch projects and workflow states for this team
    const data = await linearGql(apiKey, `query($teamId: String!) {
      team(id: $teamId) {
        projects { nodes { id name } }
        states { nodes { id name type } }
      }
    }`, { teamId: team.id });

    const projects: LinearProject[] = data.team?.projects?.nodes || [];
    const states: LinearWorkflowState[] = data.team?.states?.nodes || [];
    overlay.setLoading(false);

    // Build workflow mapping from state types
    const workflow: Record<string, string> = {};
    for (const state of states) {
      switch (state.type) {
        case 'backlog': workflow.queued = state.name; break;
        case 'started': workflow.in_progress = state.name; break;
        case 'completed': workflow.done = state.name; break;
        case 'cancelled': workflow.abandoned = state.name; break;
      }
    }

    const items: OverlayItem[] = [
      { label: `Team: ${team.key} — ${team.name}`, dimmed: true },
      { label: '', dimmed: true },
    ];

    if (projects.length > 0) {
      items.push({ label: 'Link to a Linear project (optional):', dimmed: true });
      items.push({ label: '', dimmed: true });

      // Option to skip project
      items.push({
        label: 'No project (team-level issues only)',
        action: () => saveLinearConfig(config, team, null, workflow, onConfigured, overlay),
      });

      for (const project of projects) {
        items.push({
          label: project.name,
          action: () => saveLinearConfig(config, team, project, workflow, onConfigured, overlay),
        });
      }
    } else {
      items.push({
        label: 'Save configuration',
        action: () => saveLinearConfig(config, team, null, workflow, onConfigured, overlay),
      });
    }

    items.push({ label: '', dimmed: true });
    items.push({
      label: '\u2190 Back to teams',
      shortcut: 'b',
      action: () => setupLinear(overlay, config, onConfigured, onUpdate),
    });

    overlay.updateItems(items);
  } catch (err: any) {
    overlay.setLoading(false);
    overlay.showMessage(`Error: ${err.message}`);
  }
}

function saveLinearConfig(
  config: Config,
  team: LinearTeam,
  project: LinearProject | null,
  workflow: Record<string, string>,
  onConfigured: () => void,
  overlay: OverlayManager,
): void {
  config.save({
    tracker: { type: 'linear', title_prefix: '[AI]' },
    linear: {
      team_key: team.key,
      ...(project ? { project_name: project.name } : {}),
      workflow,
      auth: { api_key_env: 'LINEAR_API_KEY' },
    },
  });

  onConfigured();

  const msg = project
    ? `Configured: ${team.key} / ${project.name}`
    : `Configured: ${team.key}`;
  overlay.showMessage(msg);

  // Show summary
  setTimeout(() => {
    overlay.updateItems([
      { label: `\u2713 Linear configured!`, dimmed: true },
      { label: '', dimmed: true },
      { label: `Team: ${team.key} — ${team.name}`, dimmed: true },
      ...(project ? [{ label: `Project: ${project.name}`, dimmed: true }] : []),
      { label: `Config saved to .orch/project.json`, dimmed: true },
      { label: '', dimmed: true },
      { label: 'Press Esc to close, then F3 to browse issues' , dimmed: true },
    ]);
  }, 500);
}

function setupJira(
  overlay: OverlayManager,
  config: Config,
  onConfigured: () => void,
  onUpdate: () => void,
): void {
  const baseUrl = process.env.JIRA_BASE_URL;
  const email = process.env.JIRA_EMAIL;
  const token = process.env.JIRA_API_TOKEN;

  if (!baseUrl || !email || !token) {
    const missing = [];
    if (!baseUrl) missing.push('JIRA_BASE_URL');
    if (!email) missing.push('JIRA_EMAIL');
    if (!token) missing.push('JIRA_API_TOKEN');

    overlay.updateItems([
      { label: 'Missing Jira environment variables:', dimmed: true },
      { label: '', dimmed: true },
      ...missing.map(v => ({ label: `  \u2717 ${v}`, dimmed: true })),
      { label: '', dimmed: true },
      { label: 'Add these to your .env file and restart orch3', dimmed: true },
      { label: '', dimmed: true },
      {
        label: '\u2190 Back',
        shortcut: 'b',
        action: () => showTrackerSetup(overlay, config, onConfigured, onUpdate),
      },
    ]);
    return;
  }

  // Discover Jira projects
  discoverJiraProjects(overlay, config, baseUrl, email, token, onConfigured, onUpdate);
}

async function discoverJiraProjects(
  overlay: OverlayManager,
  config: Config,
  baseUrl: string,
  email: string,
  token: string,
  onConfigured: () => void,
  onUpdate: () => void,
): Promise<void> {
  overlay.setLoading(true);
  try {
    const auth = Buffer.from(`${email}:${token}`).toString('base64');
    const res = await fetch(`${baseUrl}/rest/api/3/project/search?maxResults=50`, {
      headers: { Authorization: `Basic ${auth}`, Accept: 'application/json' },
    });
    if (!res.ok) throw new Error(`Jira API ${res.status}`);
    const data = await res.json();
    const projects = data.values || [];
    overlay.setLoading(false);

    if (projects.length === 0) {
      overlay.updateItems([
        { label: 'No projects found in Jira', dimmed: true },
        { label: '', dimmed: true },
        {
          label: '\u2190 Back',
          shortcut: 'b',
          action: () => showTrackerSetup(overlay, config, onConfigured, onUpdate),
        },
      ]);
      return;
    }

    const items: OverlayItem[] = [
      { label: 'Select your Jira project:', dimmed: true },
      { label: '', dimmed: true },
    ];

    for (const proj of projects) {
      items.push({
        label: `${proj.key} — ${proj.name}`,
        action: () => {
          config.save({
            tracker: { type: 'jira', title_prefix: '[AI]' },
            jira: {
              project_key: proj.key,
              issue_type: 'Task',
              subtask_issue_type: 'Sub-task',
              status: { todo: 'To Do', in_progress: 'In Progress', done: 'Done' },
              auth: {
                base_url_env: 'JIRA_BASE_URL',
                email_env: 'JIRA_EMAIL',
                api_token_env: 'JIRA_API_TOKEN',
              },
            },
          });
          onConfigured();
          overlay.showMessage(`Configured: ${proj.key}`);
          setTimeout(() => {
            overlay.updateItems([
              { label: `\u2713 Jira configured!`, dimmed: true },
              { label: '', dimmed: true },
              { label: `Project: ${proj.key} — ${proj.name}`, dimmed: true },
              { label: `Config saved to .orch/project.json`, dimmed: true },
              { label: '', dimmed: true },
              { label: 'Press Esc to close, then F3 to browse issues', dimmed: true },
            ]);
          }, 500);
        },
      });
    }

    items.push({ label: '', dimmed: true });
    items.push({
      label: '\u2190 Back',
      shortcut: 'b',
      action: () => showTrackerSetup(overlay, config, onConfigured, onUpdate),
    });

    overlay.updateItems(items);
  } catch (err: any) {
    overlay.setLoading(false);
    overlay.updateItems([
      { label: `Error connecting to Jira: ${err.message}`, dimmed: true },
      { label: '', dimmed: true },
      {
        label: '[R] Retry',
        shortcut: 'r',
        action: () => discoverJiraProjects(overlay, config, baseUrl, email, token, onConfigured, onUpdate),
      },
      {
        label: '\u2190 Back',
        shortcut: 'b',
        action: () => showTrackerSetup(overlay, config, onConfigured, onUpdate),
      },
    ]);
  }
}
