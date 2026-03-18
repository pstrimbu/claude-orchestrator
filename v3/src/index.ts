import { App } from './app.js';
import { resolve } from 'path';
import type { SessionMode } from './claude-session.js';

// Parse args: orch3 [options] [project-path]
// Options:
//   -c, --continue       Resume most recent session
//   -r, --resume <id>    Resume specific session by ID
//   -h, --help           Show help
const args = process.argv.slice(2);
let projectPath = process.cwd();
let sessionMode: SessionMode = { type: 'new' };

for (let i = 0; i < args.length; i++) {
  const arg = args[i]!;
  switch (arg) {
    case '-c':
    case '--continue':
      sessionMode = { type: 'continue' };
      break;
    case '-r':
    case '--resume': {
      const id = args[++i];
      if (!id) {
        console.error('--resume requires a session ID');
        process.exit(1);
      }
      sessionMode = { type: 'resume', id };
      break;
    }
    case '-h':
    case '--help':
      console.log(`Claude Orchestrator v3

Usage: orch3 [options] [project-path]

Options:
  -c, --continue       Resume most recent Claude session
  -r, --resume <id>    Resume specific session by ID
  -h, --help           Show this help

Hotkeys:
  F13     Open menu (project, time, issues, git)
  F5      Reload orch3 (picks up code changes)
  Ctrl+R  Restart Claude session (preserves history)

Status info is shown in the terminal title bar.`);
      process.exit(0);
      break;
    default:
      // Treat as project path if it doesn't start with -
      if (!arg.startsWith('-')) {
        projectPath = arg;
      } else {
        console.error(`Unknown option: ${arg}`);
        process.exit(1);
      }
  }
}

projectPath = resolve(projectPath);

const modeLabel = sessionMode.type === 'new' ? 'new session'
  : sessionMode.type === 'continue' ? 'continuing last session'
  : `resuming ${sessionMode.id}`;

console.log(`Claude Orchestrator v3 (${modeLabel})`);
console.log(`Project: ${projectPath}`);
console.log('');

const app = new App(projectPath, sessionMode);
app.start().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
