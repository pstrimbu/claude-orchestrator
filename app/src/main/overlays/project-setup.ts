import type { OverlayManager, OverlayItem } from '../overlay-manager';
import type { Config } from '../config';
import { showTrackerSetup } from './tracker-setup';

// Wizard state accumulates choices across steps
interface WizardState {
  projectId: string;
  titlePrefix: string;
}

export function showProjectSetup(
  overlay: OverlayManager,
  config: Config,
  onConfigured: () => void,
  onUpdate: () => void,
): void {
  const state: WizardState = {
    projectId: config.projectId,
    titlePrefix: config.trackerTitlePrefix,
  };

  stepProjectId(overlay, config, state, onConfigured, onUpdate);
}

// Step 1: Project ID
function stepProjectId(
  overlay: OverlayManager,
  config: Config,
  state: WizardState,
  onConfigured: () => void,
  onUpdate: () => void,
): void {
  overlay.show({
    title: 'Setup \u2014 Step 1/4: Project ID',
    width: 65,
    items: [
      { label: 'Project ID is used for Clockify entries and display.', dimmed: true },
      { label: '', dimmed: true },
      {
        label: 'Project ID:',
        editable: true,
        editValue: state.projectId,
        placeholder: config.projectName,
        onEdit: (v) => { state.projectId = v; },
      },
      { label: '', dimmed: true },
      {
        label: `\u2713 Accept "${state.projectId}" and continue`,
        action: () => stepTitlePrefix(overlay, config, state, onConfigured, onUpdate),
      },
      {
        label: 'Use folder name: ' + config.projectName,
        action: () => {
          state.projectId = config.projectName;
          stepTitlePrefix(overlay, config, state, onConfigured, onUpdate);
        },
      },
      { label: '', dimmed: true },
      { label: '[Enter] on the field to edit, then type. [Enter] again to stop editing.', dimmed: true },
    ],
    onClose: onUpdate,
    footer: 'Step 1 of 4',
  });
}

// Step 2: Title prefix for issues
function stepTitlePrefix(
  overlay: OverlayManager,
  config: Config,
  state: WizardState,
  onConfigured: () => void,
  onUpdate: () => void,
): void {
  overlay.updateItems([
    { label: 'Prefix added to issue titles created by the orchestrator.', dimmed: true },
    { label: '', dimmed: true },
    {
      label: 'Title Prefix:',
      editable: true,
      editValue: state.titlePrefix,
      placeholder: '[AI]',
      onEdit: (v) => { state.titlePrefix = v; },
    },
    { label: '', dimmed: true },
    {
      label: `\u2713 Accept "${state.titlePrefix}" and continue`,
      action: () => stepClockify(overlay, config, state, onConfigured, onUpdate),
    },
    {
      label: 'Use default: [AI]',
      action: () => {
        state.titlePrefix = '[AI]';
        stepClockify(overlay, config, state, onConfigured, onUpdate);
      },
    },
    {
      label: 'Skip (no prefix)',
      action: () => {
        state.titlePrefix = '';
        stepClockify(overlay, config, state, onConfigured, onUpdate);
      },
    },
    { label: '', dimmed: true },
    {
      label: '\u2190 Back',
      shortcut: 'b',
      action: () => stepProjectId(overlay, config, state, onConfigured, onUpdate),
    },
  ]);

  // Update title
  if (overlay['_active']) {
    (overlay as any)._active.title = 'Setup \u2014 Step 2/4: Title Prefix';
    (overlay as any)._active.footer = 'Step 2 of 4';
  }
}

// Step 3: Clockify
function stepClockify(
  overlay: OverlayManager,
  config: Config,
  state: WizardState,
  onConfigured: () => void,
  onUpdate: () => void,
): void {
  const hasKey = !!process.env.CLOCKIFY_API_KEY;

  const items: OverlayItem[] = [
    { label: 'Clockify tracks time spent on this project.', dimmed: true },
    { label: '', dimmed: true },
    {
      label: `CLOCKIFY_API_KEY: ${hasKey ? '\u2713 Found in environment' : '\u2717 Not set'}`,
      dimmed: true,
    },
  ];

  if (hasKey) {
    items.push({ label: '', dimmed: true });
    items.push({
      label: `\u2713 Clockify is ready \u2014 continue to tracker setup`,
      action: () => stepTracker(overlay, config, state, onConfigured, onUpdate),
    });
  } else {
    items.push({ label: '', dimmed: true });
    items.push({ label: 'To enable Clockify time tracking:', dimmed: true });
    items.push({ label: '  1. Get API key from clockify.me/user/settings', dimmed: true });
    items.push({ label: '  2. Add CLOCKIFY_API_KEY=xxx to .env', dimmed: true });
    items.push({ label: '  3. Restart orch', dimmed: true });
    items.push({ label: '', dimmed: true });
    items.push({
      label: 'Skip Clockify for now \u2014 continue',
      action: () => stepTracker(overlay, config, state, onConfigured, onUpdate),
    });
  }

  items.push({ label: '', dimmed: true });
  items.push({
    label: '\u2190 Back',
    shortcut: 'b',
    action: () => stepTitlePrefix(overlay, config, state, onConfigured, onUpdate),
  });

  overlay.updateItems(items);
  if ((overlay as any)._active) {
    (overlay as any)._active.title = 'Setup \u2014 Step 3/4: Clockify';
    (overlay as any)._active.footer = 'Step 3 of 4';
  }
}

// Step 4: Issue tracker — delegates to the existing tracker-setup wizard
function stepTracker(
  overlay: OverlayManager,
  config: Config,
  state: WizardState,
  onConfigured: () => void,
  onUpdate: () => void,
): void {
  // Save project-level config first (project_id, title_prefix)
  config.save({
    project_id: state.projectId,
    tracker: {
      ...config.loadProjectJson().tracker,
      type: config.trackerType,
      title_prefix: state.titlePrefix || undefined,
    },
  });

  // Now show tracker type selection
  // When tracker setup completes, show the final summary
  showTrackerSetup(overlay, config, () => {
    onConfigured();
    showSummary(overlay, config, state, onUpdate);
  }, () => {
    // If user closes without picking tracker, still save project-level settings
    onConfigured();
    onUpdate();
  });

  // Update title to reflect step 4
  if ((overlay as any)._active) {
    (overlay as any)._active.title = 'Setup \u2014 Step 4/4: Issue Tracker';
    (overlay as any)._active.footer = 'Step 4 of 4';
  }
}

function showSummary(
  overlay: OverlayManager,
  config: Config,
  state: WizardState,
  onUpdate: () => void,
): void {
  config.reload();
  const cfg = config.loadProjectJson();

  const items: OverlayItem[] = [
    { label: '\u2713 Project configured!', dimmed: true },
    { label: '', dimmed: true },
    { label: `Project ID:    ${config.projectId}`, dimmed: true },
    { label: `Title Prefix:  ${config.trackerTitlePrefix || '(none)'}`, dimmed: true },
    { label: `Clockify:      ${config.clockifyApiKey ? 'Enabled' : 'Not configured'}`, dimmed: true },
    { label: `Tracker:       ${config.trackerType}`, dimmed: true },
  ];

  if (config.trackerType === 'linear' && cfg.linear) {
    items.push({ label: `  Team:        ${cfg.linear.team_key}`, dimmed: true });
    if (cfg.linear.project_name) {
      items.push({ label: `  Project:     ${cfg.linear.project_name}`, dimmed: true });
    }
  } else if (config.trackerType === 'jira' && cfg.jira) {
    items.push({ label: `  Project:     ${cfg.jira.project_key}`, dimmed: true });
  }

  items.push({ label: '', dimmed: true });
  items.push({ label: `Saved to: .orch/project.json`, dimmed: true });
  items.push({ label: '', dimmed: true });
  items.push({ label: 'Press Esc to close. Use F2 for time, F3 for issues.', dimmed: true });

  overlay.show({
    title: 'Setup Complete',
    items,
    onClose: onUpdate,
    width: 60,
  });
}
