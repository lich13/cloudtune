mod cache;
mod cloud189;
mod commands;
mod models;
mod runtime_paths;
mod state;
mod streaming;

use std::sync::atomic::{AtomicBool, Ordering};

use tauri::{
    Manager, Runtime, WindowEvent,
    menu::{Menu, MenuItemBuilder},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
};
use tauri_plugin_log::{Target, TargetKind};

const MAIN_WINDOW_LABEL: &str = "main";
const TRAY_ID: &str = "main-tray";
const TRAY_TOGGLE_ID: &str = "tray.toggle";
const TRAY_QUIT_ID: &str = "tray.quit";

struct ShellState {
    quit_requested: AtomicBool,
}

impl Default for ShellState {
    fn default() -> Self {
        Self {
            quit_requested: AtomicBool::new(false),
        }
    }
}

fn reveal_main_window<R: Runtime>(app: &tauri::AppHandle<R>) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        let _ = window.unminimize();
        window.show()?;
        window.set_focus()?;
    }
    Ok(())
}

fn hide_main_window<R: Runtime>(app: &tauri::AppHandle<R>) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        window.hide()?;
    }
    Ok(())
}

fn toggle_main_window<R: Runtime>(app: &tauri::AppHandle<R>) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        if window.is_visible().unwrap_or(true) {
            return hide_main_window(app);
        }
    }

    reveal_main_window(app)
}

fn build_tray<R: Runtime>(app: &tauri::AppHandle<R>) -> tauri::Result<()> {
    let menu = Menu::new(app)?;
    let toggle = MenuItemBuilder::with_id(TRAY_TOGGLE_ID, "显示 / 隐藏窗口").build(app)?;
    let quit = MenuItemBuilder::with_id(TRAY_QUIT_ID, "退出").build(app)?;
    menu.append(&toggle)?;
    menu.append(&quit)?;

    let mut tray_builder = TrayIconBuilder::with_id(TRAY_ID)
        .menu(&menu)
        .tooltip("CloudTune")
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            TRAY_TOGGLE_ID => {
                let _ = toggle_main_window(app);
            }
            TRAY_QUIT_ID => {
                let shell = app.state::<ShellState>();
                shell.quit_requested.store(true, Ordering::SeqCst);
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let _ = toggle_main_window(tray.app_handle());
            }
        });

    if let Some(icon) = app.default_window_icon().cloned() {
        tray_builder = tray_builder.icon(icon);
    }

    tray_builder.build(app)?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let runtime_paths = runtime_paths::RuntimePaths::resolve(&app.handle())?;
            app.handle().plugin(
                tauri_plugin_log::Builder::default()
                    .clear_targets()
                    .target(Target::new(TargetKind::Stdout))
                    .target(Target::new(TargetKind::Folder {
                        path: runtime_paths.logs_dir.clone(),
                        file_name: Some("CloudTune".into()),
                    }))
                    .build(),
            )?;
            tauri_plugin_log::log::info!(
                target: "cloudtune::runtime",
                "runtime data root [{}]: {}",
                runtime_paths.root_kind.label(),
                runtime_paths.root_dir.display(),
            );
            tauri_plugin_log::log::info!(
                target: "cloudtune::runtime",
                "cache dir: {}",
                runtime_paths.cache_dir.display(),
            );
            tauri_plugin_log::log::info!(
                target: "cloudtune::runtime",
                "logs dir: {}",
                runtime_paths.logs_dir.display(),
            );
            let shared_state = state::AppState::new(app.handle().clone())?;
            app.manage(shared_state);
            app.manage(ShellState::default());
            build_tray(&app.handle())?;
            #[cfg(target_os = "macos")]
            {
                let _ = app.set_dock_visibility(false);
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() != MAIN_WINDOW_LABEL {
                return;
            }

            if let WindowEvent::CloseRequested { api, .. } = event {
                let shell = window.state::<ShellState>();
                if !shell.quit_requested.load(Ordering::SeqCst) {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::bootstrap,
            commands::start_qr_login,
            commands::poll_qr_login,
            commands::list_remote_folder,
            commands::save_music_folder,
            commands::scan_library,
            commands::prepare_track,
            commands::update_cache_limit,
            commands::update_transfer_tuning,
            commands::update_playback_mode,
            commands::get_transfer_snapshot,
            commands::pick_download_directory,
            commands::download_track_to_directory,
            commands::download_folder_to_directory,
            commands::open_video_in_system,
            commands::read_track_metadata,
            commands::pause_transfer,
            commands::resume_transfer,
            commands::delete_transfer,
            commands::logout,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
