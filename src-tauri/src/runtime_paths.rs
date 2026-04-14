use anyhow::{Context, Result};
use std::{fs, path::PathBuf};
use tauri::{AppHandle, Manager};

const PORTABLE_DATA_DIR: &str = "data";

#[derive(Debug, Clone)]
pub struct RuntimePaths {
    pub root_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub config_path: PathBuf,
    pub cache_index_path: PathBuf,
    pub library_index_path: PathBuf,
    pub artwork_dir: PathBuf,
    pub logs_dir: PathBuf,
}

impl RuntimePaths {
    pub fn resolve(app_handle: &AppHandle) -> Result<Self> {
        let fallback_root = app_handle
            .path()
            .app_data_dir()
            .context("failed to resolve app data directory")?;

        let root_dir = resolve_preferred_root(app_handle).unwrap_or(fallback_root);
        let cache_dir = root_dir.join("cache");
        let artwork_dir = root_dir.join("artwork");
        let logs_dir = root_dir.join("logs");

        fs::create_dir_all(&cache_dir)?;
        fs::create_dir_all(&artwork_dir)?;
        fs::create_dir_all(&logs_dir)?;

        Ok(Self {
            root_dir: root_dir.clone(),
            cache_dir: cache_dir.clone(),
            config_path: root_dir.join("settings.json"),
            cache_index_path: cache_dir.join("index.json"),
            library_index_path: root_dir.join("library.json"),
            artwork_dir,
            logs_dir,
        })
    }
}

fn resolve_preferred_root(app_handle: &AppHandle) -> Option<PathBuf> {
    let executable_dir = app_handle.path().executable_dir().ok()?;
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
