use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredConfig {
    pub refresh_token: Option<String>,
    pub account_name: Option<String>,
    pub music_folder_id: Option<String>,
    pub music_folder_name: Option<String>,
    pub cache_limit_mb: u64,
    pub download_threads: u16,
    pub cache_threads: u16,
    pub playback_mode: String,
}

impl Default for StoredConfig {
    fn default() -> Self {
        Self {
            refresh_token: None,
            account_name: None,
            music_folder_id: None,
            music_folder_name: None,
            cache_limit_mb: 1024,
            download_threads: 32,
            cache_threads: 16,
            playback_mode: "download_first".to_string(),
        }
    }
}

impl StoredConfig {
    pub fn current_folder(&self) -> Option<FolderSelection> {
        match (&self.music_folder_id, &self.music_folder_name) {
            (Some(id), Some(name)) => Some(FolderSelection {
                id: id.clone(),
                name: name.clone(),
            }),
            _ => None,
        }
    }

    pub fn cache_limit_bytes(&self) -> u64 {
        self.cache_limit_mb
            .saturating_mul(1024)
            .saturating_mul(1024)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderSelection {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BootstrapPayload {
    pub authenticated: bool,
    pub account_name: Option<String>,
    pub current_folder: Option<FolderSelection>,
    pub library_tracks: Vec<TrackSummary>,
    pub cache_limit_mb: u64,
    pub download_threads: u16,
    pub cache_threads: u16,
    pub playback_mode: String,
    pub cache_usage_bytes: u64,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QrLoginStart {
    pub qr_content: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QrLoginState {
    WaitingScan,
    WaitingConfirm,
    Authenticated,
    Expired,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QrPollResponse {
    pub state: QrLoginState,
    pub message: String,
    pub account_name: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteFolder {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackSummary {
    pub id: String,
    pub name: String,
    pub folder_path: String,
    pub size_bytes: u64,
    pub modified_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderBrowsePayload {
    pub current_folder_id: String,
    pub current_folder_name: String,
    pub parent_folder_id: Option<String>,
    pub is_root: bool,
    pub folders: Vec<RemoteFolder>,
    pub audio_files: Vec<TrackSummary>,
    pub video_files: Vec<TrackSummary>,
    pub other_files: Vec<TrackSummary>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedTrack {
    pub track_id: String,
    pub local_path: String,
    pub playback_url: String,
    pub is_streaming: bool,
    pub cache_usage_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsPayload {
    pub current_folder: Option<FolderSelection>,
    pub cache_limit_mb: u64,
    pub download_threads: u16,
    pub cache_threads: u16,
    pub playback_mode: String,
    pub cache_usage_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferStatus {
    pub id: String,
    pub label: String,
    pub kind: String,
    pub state: String,
    pub path: Option<String>,
    pub can_pause: bool,
    pub can_resume: bool,
    pub can_delete: bool,
    pub bytes_per_second: u64,
    pub transferred_bytes: u64,
    pub total_bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferSnapshotPayload {
    pub total_speed_bytes_per_second: u64,
    pub items: Vec<TransferStatus>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NowPlayingMetadata {
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub artwork_path: Option<String>,
}
