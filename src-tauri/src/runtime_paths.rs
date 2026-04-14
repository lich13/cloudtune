use anyhow::{Context, Result};
use std::{
    fs, io,
    path::{Path, PathBuf},
};
use tauri::{AppHandle, Manager};

const PORTABLE_DATA_DIR: &str = "data";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeRootKind {
    Portable,
    AppDataFallback,
}

impl RuntimeRootKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::Portable => "portable-data",
            Self::AppDataFallback => "app-data-fallback",
        }
    }
}

#[derive(Debug, Clone)]
pub struct RuntimePaths {
    pub root_kind: RuntimeRootKind,
    pub root_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub config_path: PathBuf,
    pub cache_index_path: PathBuf,
    pub library_index_path: PathBuf,
    pub artwork_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub webview_dir: PathBuf,
}

impl RuntimePaths {
    pub fn resolve(app_handle: &AppHandle) -> Result<Self> {
        let fallback_root = app_handle
            .path()
            .app_data_dir()
            .context("failed to resolve app data directory")?;

        let (root_dir, root_kind) = resolve_preferred_root(app_handle)
            .map(|path| (path, RuntimeRootKind::Portable))
            .unwrap_or((fallback_root, RuntimeRootKind::AppDataFallback));
        let cache_dir = root_dir.join("cache");
        let artwork_dir = root_dir.join("artwork");
        let logs_dir = root_dir.join("logs");
        let webview_dir = root_dir.join("webview");

        if root_kind == RuntimeRootKind::Portable {
            migrate_legacy_root(app_handle.path().app_data_dir().ok().as_deref(), &root_dir)?;
            migrate_legacy_webview_root(app_handle, &webview_dir)?;
        }

        fs::create_dir_all(&cache_dir)?;
        fs::create_dir_all(&artwork_dir)?;
        fs::create_dir_all(&logs_dir)?;
        fs::create_dir_all(&webview_dir)?;

        Ok(Self {
            root_kind,
            root_dir: root_dir.clone(),
            cache_dir: cache_dir.clone(),
            config_path: root_dir.join("settings.json"),
            cache_index_path: cache_dir.join("index.json"),
            library_index_path: root_dir.join("library.json"),
            artwork_dir,
            logs_dir,
            webview_dir,
        })
    }
}

fn resolve_preferred_root(app_handle: &AppHandle) -> Option<PathBuf> {
    let executable_dir = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(Path::to_path_buf))
        .or_else(|| app_handle.path().executable_dir().ok())?;
    let candidate = executable_dir.join(PORTABLE_DATA_DIR);

    if ensure_writable_dir(&candidate).is_ok() {
        Some(candidate)
    } else {
        None
    }
}

fn ensure_writable_dir(path: &PathBuf) -> Result<()> {
    fs::create_dir_all(path)?;
    let probe = path.join(".write-test");
    fs::write(&probe, b"ok")?;
    let _ = fs::remove_file(&probe);
    Ok(())
}

fn migrate_legacy_root(legacy_root: Option<&Path>, portable_root: &Path) -> Result<()> {
    let Some(legacy_root) = legacy_root else {
        return Ok(());
    };

    if legacy_root == portable_root || !legacy_root.exists() {
        return Ok(());
    }

    fs::create_dir_all(portable_root)?;
    move_directory_contents(legacy_root, portable_root)?;

    if legacy_root.read_dir()?.next().is_none() {
        let _ = fs::remove_dir(legacy_root);
    }

    Ok(())
}

fn move_directory_contents(source_root: &Path, destination_root: &Path) -> Result<()> {
    for entry in fs::read_dir(source_root)? {
        let entry = entry?;
        let source_path = entry.path();
        let destination_path = destination_root.join(entry.file_name());
        move_entry(&source_path, &destination_path)?;
    }

    Ok(())
}

fn move_entry(source: &Path, destination: &Path) -> Result<()> {
    if !source.exists() {
        return Ok(());
    }

    if destination.exists() {
        if source.is_dir() && destination.is_dir() {
            move_directory_contents(source, destination)?;
            if source.read_dir()?.next().is_none() {
                let _ = fs::remove_dir(source);
            }
            return Ok(());
        }

        return Ok(());
    }

    match fs::rename(source, destination) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::CrossesDevices => {
            copy_entry(source, destination)
        }
        Err(error) => Err(error.into()),
    }
}

fn copy_entry(source: &Path, destination: &Path) -> Result<()> {
    if source.is_dir() {
        fs::create_dir_all(destination)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            let child_source = entry.path();
            let child_destination = destination.join(entry.file_name());
            copy_entry(&child_source, &child_destination)?;
        }
        fs::remove_dir_all(source)?;
    } else {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(source, destination)?;
        fs::remove_file(source)?;
    }

    Ok(())
}

fn migrate_legacy_webview_root(app_handle: &AppHandle, portable_webview_dir: &Path) -> Result<()> {
    let Some(legacy_local_root) = app_handle.path().app_local_data_dir().ok() else {
        return Ok(());
    };

    let legacy_webview_root = legacy_local_root.join("EBWebView");
    let destination_webview_root = portable_webview_dir.join("EBWebView");
    move_entry(&legacy_webview_root, &destination_webview_root)?;

    if legacy_local_root.exists() && legacy_local_root.read_dir()?.next().is_none() {
        let _ = fs::remove_dir(&legacy_local_root);
    }

    Ok(())
}
