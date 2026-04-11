use crate::{
    cache::CacheIndex,
    cloud189::Cloud189Client,
    models::{StoredConfig, TrackSummary, TransferStatus},
};
use anyhow::{Context, Result};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::PathBuf,
    sync::{Arc, atomic::AtomicBool},
};
use tauri::{AppHandle, Manager};
use tokio::sync::{Mutex, Semaphore};

use crate::streaming::{StreamSource, StreamSourceStore, TransferStore, start_stream_server};

const MAX_CONCURRENT_REMOTE_REQUESTS: usize = 8;

pub struct AppState {
    pub inner: Mutex<RuntimeState>,
    pub stream_sources: StreamSourceStore,
    pub transfer_statuses: TransferStore,
    pub transfer_controls: TransferControlStore,
    pub remote_request_slots: Arc<Semaphore>,
    pub stream_server_port: u16,
}

pub type TransferControlStore = Arc<Mutex<HashMap<String, TransferControl>>>;

#[derive(Clone)]
pub struct DownloadSpec {
    pub track_id: String,
    pub file_name: String,
    pub size_bytes: u64,
    pub destination: PathBuf,
    pub thread_count: usize,
}

pub struct TransferControl {
    pub cancel: Arc<AtomicBool>,
    pub path: Option<PathBuf>,
    pub download: Option<DownloadSpec>,
}

pub struct RuntimeState {
    pub app_handle: AppHandle,
    pub config_path: PathBuf,
    pub cache_dir: PathBuf,
    pub cache_index_path: PathBuf,
    pub library_index_path: PathBuf,
    pub config: StoredConfig,
    pub cache_index: CacheIndex,
    pub cloud: Cloud189Client,
    pub active_cache_downloads: HashSet<String>,
}

impl AppState {
    pub fn new(app_handle: AppHandle) -> Result<Self> {
        let app_data_dir = app_handle
            .path()
            .app_data_dir()
            .context("failed to resolve app data directory")?;
        let cache_dir = app_data_dir.join("cache");
        let config_path = app_data_dir.join("settings.json");
        let cache_index_path = cache_dir.join("index.json");
        let library_index_path = app_data_dir.join("library.json");

        fs::create_dir_all(&cache_dir)?;

        let mut config = if config_path.exists() {
            serde_json::from_str(&fs::read_to_string(&config_path)?).unwrap_or_default()
        } else {
            StoredConfig::default()
        };
        config.normalize_transfer_tuning();

        let cache_index = CacheIndex::load(&cache_index_path);
        let cloud = Cloud189Client::new()?;
        let stream_sources: StreamSourceStore =
            Arc::new(Mutex::new(HashMap::<String, StreamSource>::new()));
        let transfer_statuses: TransferStore =
            Arc::new(Mutex::new(HashMap::<String, TransferStatus>::new()));
        let transfer_controls: TransferControlStore =
            Arc::new(Mutex::new(HashMap::<String, TransferControl>::new()));
        let remote_request_slots = Arc::new(Semaphore::new(MAX_CONCURRENT_REMOTE_REQUESTS));
        let stream_server_port = start_stream_server(
            app_handle.clone(),
            stream_sources.clone(),
            transfer_statuses.clone(),
            remote_request_slots.clone(),
        )?;

        Ok(Self {
            stream_sources,
            transfer_statuses,
            transfer_controls,
            remote_request_slots,
            stream_server_port,
            inner: Mutex::new(RuntimeState {
                app_handle,
                config_path,
                cache_dir,
                cache_index_path,
                library_index_path,
                config,
                cache_index,
                cloud,
                active_cache_downloads: HashSet::new(),
            }),
        })
    }
}

impl RuntimeState {
    pub fn save_config(&self) -> Result<()> {
        if let Some(parent) = self.config_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.config_path, serde_json::to_vec_pretty(&self.config)?)?;
        Ok(())
    }

    pub fn save_cache_index(&self) -> Result<()> {
        self.cache_index.save(&self.cache_index_path)
    }

    pub fn load_library_tracks(&self) -> Vec<TrackSummary> {
        if !self.library_index_path.exists() {
            return Vec::new();
        }

        fs::read_to_string(&self.library_index_path)
            .ok()
            .and_then(|content| serde_json::from_str::<Vec<TrackSummary>>(&content).ok())
            .unwrap_or_default()
    }

    pub fn save_library_tracks(&self, tracks: &[TrackSummary]) -> Result<()> {
        if let Some(parent) = self.library_index_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.library_index_path, serde_json::to_vec_pretty(tracks)?)?;
        Ok(())
    }
}
