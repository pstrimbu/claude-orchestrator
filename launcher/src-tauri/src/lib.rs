use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, State};

// --- Data types ---

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ProjectEntry {
    path: String,
    name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ProjectsConfig {
    projects: Vec<ProjectEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppStatus {
    name: String,
    session_path: Option<String>,
    session_running: bool,
    session_pid: Option<i32>,
    portal_name: Option<String>,
    ui_port: Option<u16>,
    api_port: Option<u16>,
    portal_path: Option<String>,
    portal_start_cmd: Option<String>,
    ui_running: bool,
    api_running: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PortalEntryResponse {
    name: String,
    ui_port: u16,
    api_port: u16,
    path: String,
    visible: bool,
}

struct PortalCsvEntry {
    name: String,
    ui_port: u16,
    api_port: u16,
    dir: String,
    start_cmd: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct HiddenPortals {
    hidden: Vec<String>,
}

// --- App state ---

struct LauncherState {
    projects: Mutex<Vec<ProjectEntry>>,
    expanded: Mutex<bool>,
    mouse_left_at: Mutex<Option<Instant>>,
    last_screen_width: Mutex<u32>,
}

const COLLAPSED_WIDTH: u32 = 40;
const EXPANDED_WIDTH: u32 = 520;
const COLLAPSE_DELAY_MS: u64 = 400;

// --- Native mouse position (macOS CoreGraphics) ---

#[repr(C)]
struct CGPoint {
    x: f64,
    y: f64,
}

extern "C" {
    fn CGEventCreate(source: *const std::ffi::c_void) -> *mut std::ffi::c_void;
    fn CGEventGetLocation(event: *const std::ffi::c_void) -> CGPoint;
    fn CFRelease(cf: *const std::ffi::c_void);
}

fn get_mouse_position() -> Option<(f64, f64)> {
    unsafe {
        let event = CGEventCreate(std::ptr::null());
        if event.is_null() {
            return None;
        }
        let pos = CGEventGetLocation(event);
        CFRelease(event);
        Some((pos.x, pos.y))
    }
}

// --- Path helpers ---

fn home_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
}

fn config_dir() -> PathBuf {
    home_dir().join(".config").join("orch3")
}

fn config_file() -> PathBuf {
    config_dir().join("launcher-projects.json")
}

fn portals_config_file() -> PathBuf {
    config_dir().join("launcher-portals.json")
}

fn ports_csv_path() -> PathBuf {
    home_dir().join("dev").join("dev-application-ports.csv")
}

// --- Config I/O ---

fn load_projects() -> Vec<ProjectEntry> {
    let path = config_file();
    if !path.exists() {
        return vec![];
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<ProjectsConfig>(&s).ok())
        .map(|c| c.projects)
        .unwrap_or_default()
}

fn save_projects(projects: &[ProjectEntry]) {
    let _ = fs::create_dir_all(config_dir());
    let config = ProjectsConfig {
        projects: projects.to_vec(),
    };
    let _ = fs::write(
        config_file(),
        serde_json::to_string_pretty(&config).unwrap_or_default(),
    );
}

fn load_portals_config() -> HiddenPortals {
    let path = portals_config_file();
    if !path.exists() {
        return HiddenPortals { hidden: vec![] };
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(HiddenPortals { hidden: vec![] })
}

fn save_portals_config(cfg: &HiddenPortals) {
    let _ = fs::create_dir_all(config_dir());
    let _ = fs::write(
        portals_config_file(),
        serde_json::to_string_pretty(cfg).unwrap_or_default(),
    );
}

fn load_ports_csv() -> Vec<PortalCsvEntry> {
    let path = ports_csv_path();
    if !path.exists() {
        return vec![];
    }
    let content = match fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };
    let mut result = vec![];
    for line in content.lines().skip(1) {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() < 3 {
            continue;
        }
        let name = parts[0].trim().to_string();
        let ui_port: u16 = parts[1].trim().parse().unwrap_or(0);
        let api_port: u16 = parts[2].trim().parse().unwrap_or(0);
        let dir = parts
            .get(6)
            .map(|s| s.trim())
            .unwrap_or(parts[0].trim())
            .to_string();
        let start_cmd = parts
            .get(7)
            .map(|s| s.trim())
            .unwrap_or("npm run dev")
            .to_string();
        if ui_port > 0 && api_port > 0 {
            result.push(PortalCsvEntry {
                name,
                ui_port,
                api_port,
                dir,
                start_cmd,
            });
        }
    }
    result
}

// --- Port scanning ---

fn get_listening_ports() -> HashSet<u16> {
    let output = Command::new("sh")
        .args([
            "-c",
            "lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk '{print $9}'",
        ])
        .output();

    let mut ports = HashSet::new();
    if let Ok(out) = output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            if let Some(port_str) = line.rsplit(':').next() {
                if let Ok(port) = port_str.parse::<u16>() {
                    ports.insert(port);
                }
            }
        }
    }
    ports
}

// --- Process detection ---

fn get_running_pid(project_path: &str) -> Option<i32> {
    // Check PID file first
    let pid_file = Path::new(project_path).join(".orch").join("orch3.pid");
    if pid_file.exists() {
        if let Ok(content) = fs::read_to_string(&pid_file) {
            if let Ok(pid) = content.trim().parse::<i32>() {
                if pid > 0 {
                    unsafe {
                        if libc::kill(pid, 0) == 0 {
                            return Some(pid);
                        }
                    }
                }
            }
        }
    }

    // Fallback: ps
    let proj_name = Path::new(project_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");

    let cmd = format!(
        "ps axo pid,command | grep -E 'orch3-{}|Electron.*{}' | grep -v grep | grep -v Helper | head -1",
        proj_name, project_path
    );

    if let Ok(out) = Command::new("sh").args(["-c", &cmd]).output() {
        let stdout = String::from_utf8_lossy(&out.stdout);
        let trimmed = stdout.trim();
        if !trimmed.is_empty() {
            if let Some(pid_str) = trimmed.split_whitespace().next() {
                if let Ok(pid) = pid_str.parse::<i32>() {
                    if pid > 0 {
                        return Some(pid);
                    }
                }
            }
        }
    }

    None
}

// --- Build statuses ---

fn build_app_statuses(projects: &[ProjectEntry]) -> Vec<AppStatus> {
    let listening = get_listening_ports();
    let csv_portals = load_ports_csv();
    let portal_cfg = load_portals_config();
    let home = home_dir();

    struct PortalInfo {
        name: String,
        ui_port: u16,
        api_port: u16,
        path: String,
        start_cmd: String,
        ui_running: bool,
        api_running: bool,
    }

    let visible_portals: Vec<PortalInfo> = csv_portals
        .iter()
        .filter(|p| !portal_cfg.hidden.contains(&p.name))
        .map(|p| {
            let path = home.join("dev").join(&p.dir);
            PortalInfo {
                name: p.name.clone(),
                ui_port: p.ui_port,
                api_port: p.api_port,
                path: path.to_string_lossy().to_string(),
                start_cmd: p.start_cmd.clone(),
                ui_running: listening.contains(&p.ui_port),
                api_running: listening.contains(&p.api_port),
            }
        })
        .collect();

    let mut portal_by_dir: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();
    for (i, p) in visible_portals.iter().enumerate() {
        let dir = Path::new(&p.path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();
        portal_by_dir.insert(dir, i);
    }

    let mut used_portals = HashSet::new();
    let mut apps = Vec::new();

    for proj in projects {
        let pid = get_running_pid(&proj.path);
        let portal = portal_by_dir.get(&proj.name).map(|&i| &visible_portals[i]);
        if portal.is_some() {
            used_portals.insert(proj.name.clone());
        }

        apps.push(AppStatus {
            name: proj.name.clone(),
            session_path: Some(proj.path.clone()),
            session_running: pid.is_some(),
            session_pid: pid,
            portal_name: portal.map(|p| p.name.clone()),
            ui_port: portal.map(|p| p.ui_port),
            api_port: portal.map(|p| p.api_port),
            portal_path: portal.map(|p| p.path.clone()),
            portal_start_cmd: portal.map(|p| p.start_cmd.clone()),
            ui_running: portal.map(|p| p.ui_running).unwrap_or(false),
            api_running: portal.map(|p| p.api_running).unwrap_or(false),
        });
    }

    for p in &visible_portals {
        let dir = Path::new(&p.path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();
        if !used_portals.contains(&dir) {
            apps.push(AppStatus {
                name: p.name.clone(),
                session_path: None,
                session_running: false,
                session_pid: None,
                portal_name: Some(p.name.clone()),
                ui_port: Some(p.ui_port),
                api_port: Some(p.api_port),
                portal_path: Some(p.path.clone()),
                portal_start_cmd: Some(p.start_cmd.clone()),
                ui_running: p.ui_running,
                api_running: p.api_running,
            });
        }
    }

    apps.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    apps
}

// --- Expand / Collapse (standalone, callable from any thread) ---

fn do_expand(app: &AppHandle) {
    let state = app.state::<LauncherState>();
    let mut expanded = state.expanded.lock().unwrap();
    if *expanded {
        return;
    }
    *expanded = true;

    if let Some(window) = app.get_webview_window("main") {
        let screen_w = window.primary_monitor().ok().flatten()
            .map(|m| m.size().width as i32)
            .unwrap_or(*state.last_screen_width.lock().unwrap() as i32);
        let new_x = screen_w - EXPANDED_WIDTH as i32;
        if let Ok(size) = window.outer_size() {
            let _ = window.set_size(PhysicalSize::new(EXPANDED_WIDTH, size.height));
        }
        if let Ok(pos) = window.outer_position() {
            let _ = window.set_position(PhysicalPosition::new(new_x, pos.y));
        }
        let _ = window.emit("expanded", true);
    }
}

fn do_collapse(app: &AppHandle) {
    let state = app.state::<LauncherState>();
    let mut expanded = state.expanded.lock().unwrap();
    if !*expanded {
        return;
    }
    *expanded = false;

    if let Some(window) = app.get_webview_window("main") {
        let screen_w = window.primary_monitor().ok().flatten()
            .map(|m| m.size().width as i32)
            .unwrap_or(*state.last_screen_width.lock().unwrap() as i32);
        let new_x = screen_w - COLLAPSED_WIDTH as i32;
        if let Ok(size) = window.outer_size() {
            let _ = window.set_size(PhysicalSize::new(COLLAPSED_WIDTH, size.height));
        }
        if let Ok(pos) = window.outer_position() {
            let _ = window.set_position(PhysicalPosition::new(new_x, pos.y));
        }
        let _ = window.emit("expanded", false);
    }
}

// --- Tauri commands ---

#[tauri::command]
fn add_project(path: String, state: State<LauncherState>, app: AppHandle) -> Result<(), String> {
    let name = Path::new(&path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let mut projects = state.projects.lock().unwrap();
    if projects.iter().any(|p| p.path == path) {
        return Ok(());
    }
    projects.push(ProjectEntry { path, name });
    save_projects(&projects);
    send_update(&app, &projects, &state.expanded);
    Ok(())
}

#[tauri::command]
fn remove_project(path: String, state: State<LauncherState>, app: AppHandle) {
    let mut projects = state.projects.lock().unwrap();
    projects.retain(|p| p.path != path);
    save_projects(&projects);
    send_update(&app, &projects, &state.expanded);
}

#[tauri::command]
fn open_project(path: String, state: State<LauncherState>, app: AppHandle) {
    // Add to projects list if not already present
    let mut projects = state.projects.lock().unwrap();
    if !projects.iter().any(|p| p.path == path) {
        let name = Path::new(&path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
            .to_string();
        projects.push(ProjectEntry { path: path.clone(), name });
        save_projects(&projects);
        send_update(&app, &projects, &state.expanded);
    }
    drop(projects);

    let _ = Command::new("sh")
        .args(["-c", &format!("orch3 '{}' --continue", path)])
        .current_dir(&path)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

#[tauri::command]
fn focus_project(pid: i32) {
    unsafe {
        libc::kill(pid, libc::SIGUSR1);
    }
}

#[tauri::command]
fn stop_project(pid: i32) {
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }
}

#[tauri::command]
fn reorder_projects(paths: Vec<String>, state: State<LauncherState>) {
    let mut projects = state.projects.lock().unwrap();
    let by_path: std::collections::HashMap<String, ProjectEntry> = projects
        .drain(..)
        .map(|p| (p.path.clone(), p))
        .collect();
    *projects = paths
        .into_iter()
        .filter_map(|p| by_path.get(&p).cloned())
        .collect();
    save_projects(&projects);
}

#[tauri::command]
fn cascade_windows(state: State<LauncherState>, app: AppHandle) {
    let projects = state.projects.lock().unwrap();
    let mut running: Vec<(String, String, i32)> = Vec::new();
    for p in projects.iter() {
        if let Some(pid) = get_running_pid(&p.path) {
            running.push((p.name.clone(), p.path.clone(), pid));
        }
    }
    if running.is_empty() {
        return;
    }

    running.sort_by(|a, b| a.0.cmp(&b.0));

    let window = match app.get_webview_window("main") {
        Some(w) => w,
        None => return,
    };
    let monitor = match window.primary_monitor() {
        Ok(Some(m)) => m,
        _ => return,
    };
    let screen_w = monitor.size().width;
    let screen_h = monitor.size().height;
    let scale = monitor.scale_factor();

    let menu_bar = (25.0 * scale) as u32;
    let work_h = screen_h - menu_bar;

    let max_offset: i32 = 80;
    let win_w: i32 = 1200;
    let win_h: i32 = 800;

    let base_x = ((screen_w as i32) - win_w) / 2;
    let base_y = (menu_bar as i32) + (work_h as i32) - win_h;

    let available_y = base_y - (menu_bar as i32);
    let gaps = running.len() as i32 - 1;
    let offset = if gaps > 0 {
        max_offset.min(available_y / gaps)
    } else {
        0
    };

    for i in (0..running.len()).rev() {
        let (_, ref path, pid) = running[i];
        let x = base_x + offset * (i as i32);
        let y = base_y - offset * (i as i32);
        let orch_dir = Path::new(path).join(".orch");
        let _ = fs::create_dir_all(&orch_dir);
        let cmd = serde_json::json!({ "x": x, "y": y, "focus": i == 0 });
        let _ = fs::write(orch_dir.join("window-cmd.json"), cmd.to_string());
        unsafe {
            libc::kill(pid, libc::SIGUSR2);
        }
    }

    if let Some((_, _, pid)) = running.first() {
        let pid = *pid;
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(500));
            unsafe {
                libc::kill(pid, libc::SIGUSR1);
            }
        });
    }
}

#[tauri::command]
fn show_window(app: AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
    }
}

#[tauri::command]
fn expand_window(app: AppHandle) {
    do_expand(&app);
}

#[tauri::command]
fn collapse_window(app: AppHandle) {
    do_collapse(&app);
}

#[tauri::command]
fn start_portal(path: String, start_cmd: String) {
    let _ = Command::new("sh")
        .args(["-c", &start_cmd])
        .current_dir(&path)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

#[tauri::command]
fn stop_portal(port: u16) {
    let cmd = format!(
        "lsof -iTCP:{} -sTCP:LISTEN -P -n -t 2>/dev/null",
        port
    );
    if let Ok(out) = Command::new("sh").args(["-c", &cmd]).output() {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.trim().lines() {
            if let Ok(pid) = line.trim().parse::<i32>() {
                unsafe {
                    libc::kill(pid, libc::SIGTERM);
                }
            }
        }
    }
}

#[tauri::command]
fn get_all_portal_entries() -> Vec<PortalEntryResponse> {
    let csv_portals = load_ports_csv();
    let cfg = load_portals_config();
    let home = home_dir();

    csv_portals
        .iter()
        .map(|p| PortalEntryResponse {
            name: p.name.clone(),
            ui_port: p.ui_port,
            api_port: p.api_port,
            path: home
                .join("dev")
                .join(&p.dir)
                .to_string_lossy()
                .to_string(),
            visible: !cfg.hidden.contains(&p.name),
        })
        .collect()
}

#[tauri::command]
fn set_portal_visibility(
    name: String,
    visible: bool,
    state: State<LauncherState>,
    app: AppHandle,
) {
    let mut cfg = load_portals_config();
    if visible {
        cfg.hidden.retain(|n| n != &name);
    } else if !cfg.hidden.contains(&name) {
        cfg.hidden.push(name);
    }
    save_portals_config(&cfg);
    let projects = state.projects.lock().unwrap();
    send_update(&app, &projects, &state.expanded);
}

// --- Polling & update ---

fn send_update(app: &AppHandle, projects: &[ProjectEntry], expanded: &Mutex<bool>) {
    let apps = build_app_statuses(projects);

    let _ = app.emit("apps-update", &apps);

    // Auto-resize window
    if let Some(window) = app.get_webview_window("main") {
        let is_expanded = *expanded.lock().unwrap();
        let item_height: u32 = if is_expanded { 32 } else { 16 };
        let chrome: u32 = if is_expanded { 50 } else { 16 };
        let target_h = (chrome + apps.len() as u32 * item_height).max(60).min(800);

        if let Ok(size) = window.outer_size() {
            if (size.height as i32 - target_h as i32).unsigned_abs() > 10 {
                let w = size.width;
                let _ = window.set_size(PhysicalSize::new(w, target_h));
            }
        }
    }
}

// --- Entry point ---

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .manage(LauncherState {
            projects: Mutex::new(load_projects()),
            expanded: Mutex::new(false),
            mouse_left_at: Mutex::new(None),
            last_screen_width: Mutex::new(0),
        })
        .invoke_handler(tauri::generate_handler![
            show_window,
            add_project,
            remove_project,
            open_project,
            focus_project,
            stop_project,
            reorder_projects,
            cascade_windows,
            expand_window,
            collapse_window,
            start_portal,
            stop_portal,
            get_all_portal_entries,
            set_portal_visibility,
        ])
        .setup(|app| {
            let handle = app.handle().clone();

            // Position window at right edge of screen
            if let Some(window) = app.get_webview_window("main") {
                if let Ok(Some(monitor)) = window.primary_monitor() {
                    let screen_w = monitor.size().width;
                    let x = screen_w as i32 - COLLAPSED_WIDTH as i32;
                    let _ = window.set_position(PhysicalPosition::new(x, 80));
                    *app.state::<LauncherState>().last_screen_width.lock().unwrap() = screen_w;
                }

                // Show window after a short delay to let frontend paint
                let show_handle = handle.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(500));
                    if let Some(w) = show_handle.get_webview_window("main") {
                        let _ = w.show();
                    }
                });

                // Initial update
                let state = app.state::<LauncherState>();
                let projects = state.projects.lock().unwrap();
                send_update(&handle, &projects, &state.expanded);
                drop(projects);
            }

            // Status polling thread — updates every 3 seconds
            let poll_handle = handle.clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_secs(3));
                let state = poll_handle.state::<LauncherState>();
                let projects = state.projects.lock().unwrap();
                send_update(&poll_handle, &projects, &state.expanded);
                drop(projects);

                // Reposition to right edge if screen size changed
                if let Some(window) = poll_handle.get_webview_window("main") {
                    if let Ok(Some(monitor)) = window.primary_monitor() {
                        let screen_w = monitor.size().width;
                        let mut last_w = state.last_screen_width.lock().unwrap();
                        if *last_w != screen_w && *last_w > 0 {
                            *last_w = screen_w;
                            let is_expanded = *state.expanded.lock().unwrap();
                            let w = if is_expanded { EXPANDED_WIDTH } else { COLLAPSED_WIDTH };
                            let x = screen_w as i32 - w as i32;
                            if let Ok(pos) = window.outer_position() {
                                let _ = window.set_position(PhysicalPosition::new(x, pos.y));
                            }
                        } else if *last_w == 0 {
                            *last_w = screen_w;
                        }
                    }
                }
            });

            // Mouse hover polling thread — checks every 150ms
            // macOS WebViews don't receive mouse events when window is unfocused,
            // so we poll the native mouse position via CoreGraphics instead.
            let mouse_handle = handle.clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_millis(150));

                let (mx, my) = match get_mouse_position() {
                    Some(pos) => pos,
                    None => continue,
                };

                let window = match mouse_handle.get_webview_window("main") {
                    Some(w) => w,
                    None => continue,
                };

                let (pos, size) = match (window.outer_position(), window.outer_size()) {
                    (Ok(p), Ok(s)) => (p, s),
                    _ => continue,
                };

                let in_bounds = mx >= pos.x as f64
                    && mx <= (pos.x as f64 + size.width as f64)
                    && my >= pos.y as f64
                    && my <= (pos.y as f64 + size.height as f64);

                let state = mouse_handle.state::<LauncherState>();
                let is_expanded = *state.expanded.lock().unwrap();

                if in_bounds {
                    // Mouse is inside — clear leave timer, expand if collapsed
                    *state.mouse_left_at.lock().unwrap() = None;
                    if !is_expanded {
                        do_expand(&mouse_handle);
                    }
                } else if is_expanded {
                    // Mouse is outside — start collapse delay
                    let mut left_at = state.mouse_left_at.lock().unwrap();
                    match *left_at {
                        None => {
                            *left_at = Some(Instant::now());
                        }
                        Some(t) if t.elapsed() >= Duration::from_millis(COLLAPSE_DELAY_MS) => {
                            drop(left_at);
                            do_collapse(&mouse_handle);
                        }
                        _ => {}
                    }
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error running launcher");
}
