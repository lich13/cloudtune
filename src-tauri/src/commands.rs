use crate::{
    cloud189::{ROOT_FOLDER_ID, build_media_client},
    models::{
        BootstrapPayload, MAX_CACHE_THREADS, MAX_DOWNLOAD_THREADS, NowPlayingMetadata,
        PreparedTrack, SettingsPayload, TrackSummary, TransferSnapshotPayload,
    },
    runtime_paths::RuntimePaths,
    state::{AppState, DownloadSpec, RuntimeState, TransferControl},
};
use anyhow::{Context, Result};
use lofty::{
    picture::PictureType,
    prelude::{ItemKey, TaggedFileExt},
    probe::Probe,
};
use reqwest::{
    Client, StatusCode,
    header::{CONTENT_LENGTH, CONTENT_RANGE, RANGE},
};
use sha1::{Digest, Sha1};
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use tauri::{Manager, State};
use tauri_plugin_log::log::{info, warn};
use tokio::{
    fs,
    io::{AsyncWriteExt, BufWriter},
    sync::{Mutex, Semaphore},
    task::JoinSet,
    time::{Duration, Instant},
};
use uuid::Uuid;

const MAX_DOWNLOAD_PART_RETRY_ATTEMPTS: u8 = 12;
const DOWNLOAD_PART_RETRY_DELAY_MS: u64 = 1500;
const DOWNLOAD_PART_RETRY_MAX_DELAY_MS: u64 = 12000;
const TOTAL_SIZE_PROBE_RETRY_ATTEMPTS: u8 = 4;
const PLAYBACK_DOWNLOAD_THREAD_LIMIT: usize = 1;
const PREFETCH_CACHE_THREAD_LIMIT: usize = 1;

fn to_command_error(error: anyhow::Error) -> String {
    error.to_string()
}

fn sync_refresh_token(runtime: &mut RuntimeState) -> Result<()> {
    let refresh_token = runtime.cloud.refresh_token();
    let account_name = runtime.cloud.account_name();
    if runtime.config.refresh_token != refresh_token || runtime.config.account_name != account_name
    {
        runtime.config.refresh_token = refresh_token;
        runtime.config.account_name = account_name;
        runtime.save_config()?;
    }
    Ok(())
}

async fn ensure_authenticated(runtime: &mut RuntimeState) -> Result<()> {
    if runtime.cloud.is_authenticated() {
        return Ok(());
    }

    let refresh_token = runtime
        .config
        .refresh_token
        .clone()
        .filter(|token| !token.trim().is_empty())
        .context("请先扫码登录天翼云盘")?;
    runtime
        .cloud
        .restore_from_refresh_token(refresh_token)
        .await?;
    sync_refresh_token(runtime)?;
    Ok(())
}

fn build_bootstrap_payload(
    runtime: &mut RuntimeState,
    last_error: Option<String>,
) -> Result<BootstrapPayload> {
    let cache_usage_bytes = runtime.cache_index.estimated_usage_bytes();

    Ok(BootstrapPayload {
        authenticated: runtime.cloud.is_authenticated()
            || runtime
                .config
                .refresh_token
                .as_ref()
                .is_some_and(|token| !token.trim().is_empty()),
        account_name: runtime
            .cloud
            .account_name()
            .or(runtime.config.account_name.clone()),
        current_folder: runtime.config.current_folder(),
        library_tracks: runtime.load_library_tracks(),
        cache_limit_mb: runtime.config.cache_limit_mb,
        download_threads: runtime.config.download_threads,
        cache_threads: runtime.config.cache_threads,
        playback_mode: runtime.config.playback_mode.clone(),
        cache_usage_bytes,
        last_error,
    })
}

fn build_settings_payload(runtime: &mut RuntimeState) -> Result<SettingsPayload> {
    let cache_usage_bytes = runtime.cache_index.estimated_usage_bytes();

    Ok(SettingsPayload {
        current_folder: runtime.config.current_folder(),
        cache_limit_mb: runtime.config.cache_limit_mb,
        download_threads: runtime.config.download_threads,
        cache_threads: runtime.config.cache_threads,
        playback_mode: runtime.config.playback_mode.clone(),
        cache_usage_bytes,
    })
}

fn sanitize_file_name(name: &str) -> String {
    let sanitized = name
        .chars()
        .map(|character| match character {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            other if other.is_control() => '_',
            other => other,
        })
        .collect::<String>();

    if sanitized.is_empty() {
        "track.bin".to_string()
    } else {
        sanitized
    }
}

struct ParsedTrackMetadata {
    title: String,
    artist: Option<String>,
    album: Option<String>,
    artwork_bytes: Option<Vec<u8>>,
    artwork_extension: Option<String>,
}

fn parse_track_metadata(
    local_path: PathBuf,
    fallback_name: String,
    fallback_album: String,
) -> ParsedTrackMetadata {
    let fallback_title = if fallback_name.trim().is_empty() {
        local_path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("未知曲目")
            .to_string()
    } else {
        fallback_name
    };

    let fallback_album = if fallback_album.trim().is_empty() {
        "CloudTune".to_string()
    } else {
        fallback_album
    };

    let mut metadata = ParsedTrackMetadata {
        title: fallback_title,
        artist: None,
        album: Some(fallback_album),
        artwork_bytes: None,
        artwork_extension: None,
    };

    if !local_path.is_file() {
        return metadata;
    }

    let probe = match Probe::open(&local_path) {
        Ok(probe) => probe,
        Err(_) => return metadata,
    };
    let probe = match probe.guess_file_type() {
        Ok(probe) => probe,
        Err(_) => return metadata,
    };
    let tagged_file = match probe.read() {
        Ok(tagged_file) => tagged_file,
        Err(_) => return metadata,
    };

    let Some(tag) = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
    else {
        return metadata;
    };

    if let Some(title) = tag
        .get_string(ItemKey::TrackTitle)
        .filter(|value| !value.trim().is_empty())
    {
        metadata.title = title.to_string();
    }

    if let Some(artist) = tag
        .get_string(ItemKey::TrackArtist)
        .filter(|value| !value.trim().is_empty())
    {
        metadata.artist = Some(artist.to_string());
    } else {
        let artists = tag
            .get_strings(ItemKey::TrackArtists)
            .filter(|value| !value.trim().is_empty())
            .collect::<Vec<_>>();
        if !artists.is_empty() {
            metadata.artist = Some(artists.join(", "));
        }
    }

    if let Some(album) = tag
        .get_string(ItemKey::AlbumTitle)
        .filter(|value| !value.trim().is_empty())
    {
        metadata.album = Some(album.to_string());
    }

    let picture = tag
        .pictures()
        .iter()
        .find(|picture| picture.pic_type() == PictureType::CoverFront)
        .or_else(|| tag.pictures().first());

    if let Some(picture) = picture {
        metadata.artwork_bytes = Some(picture.data().to_vec());
        metadata.artwork_extension = Some(
            picture
                .mime_type()
                .and_then(|mime_type| mime_type.ext())
                .unwrap_or("jpg")
                .to_string(),
        );
    }

    metadata
}

async fn persist_artwork_file(
    artwork_dir: &Path,
    local_path: &str,
    bytes: &[u8],
    extension: &str,
) -> Result<String> {
    fs::create_dir_all(artwork_dir).await?;

    let mut hasher = Sha1::new();
    hasher.update(local_path.as_bytes());
    hasher.update(bytes);
    let file_name = format!("{}.{}", hex::encode(hasher.finalize()), extension);
    let artwork_path = artwork_dir.join(file_name);

    if fs::metadata(&artwork_path).await.is_err() {
        fs::write(&artwork_path, bytes).await?;
    }

    Ok(artwork_path.to_string_lossy().into_owned())
}

async fn upsert_transfer_status(
    state: &AppState,
    id: &str,
    label: String,
    kind: String,
    state_label: String,
    path: Option<String>,
    can_pause: bool,
    can_delete: bool,
    bytes_per_second: u64,
    transferred_bytes: u64,
    total_bytes: Option<u64>,
) {
    let mut transfers = state.transfer_statuses.lock().await;
    transfers.insert(
        id.to_string(),
        crate::models::TransferStatus {
            id: id.to_string(),
            label,
            kind,
            state: state_label.clone(),
            path,
            can_pause,
            can_resume: state_label == "paused",
            can_delete,
            bytes_per_second,
            transferred_bytes,
            total_bytes,
        },
    );
}

fn transfer_kind_from_id(id: &str) -> String {
    if id.starts_with("playback:") {
        "playback".to_string()
    } else {
        "download".to_string()
    }
}

fn effective_download_thread_count(task_id: &str, requested: usize) -> usize {
    let requested = requested.max(1);
    if task_id.starts_with("playback:") {
        requested.min(PLAYBACK_DOWNLOAD_THREAD_LIMIT).max(1)
    } else {
        requested
    }
}

fn effective_prefetch_thread_count(requested: usize) -> usize {
    requested.min(PREFETCH_CACHE_THREAD_LIMIT).max(1)
}

fn next_download_retry_delay_ms(attempt: u8) -> u64 {
    (DOWNLOAD_PART_RETRY_DELAY_MS * u64::from(attempt)).min(DOWNLOAD_PART_RETRY_MAX_DELAY_MS)
}

fn should_refresh_download_url(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::FORBIDDEN | StatusCode::NOT_FOUND | StatusCode::GONE
    )
}

fn should_retry_download_status(status: StatusCode) -> bool {
    should_refresh_download_url(status)
        || matches!(
            status,
            StatusCode::REQUEST_TIMEOUT
                | StatusCode::TOO_MANY_REQUESTS
                | StatusCode::BAD_GATEWAY
                | StatusCode::SERVICE_UNAVAILABLE
                | StatusCode::GATEWAY_TIMEOUT
                | StatusCode::INTERNAL_SERVER_ERROR
        )
}

async fn refresh_download_playback_url(
    app_handle: &tauri::AppHandle,
    track_id: &str,
) -> Result<String> {
    let state = app_handle.state::<AppState>();
    let mut runtime = state.inner.lock().await;
    runtime.cloud.playback_url(track_id).await
}

async fn probe_total_size_with_retries(
    client: &Client,
    playback_url: Arc<Mutex<String>>,
    app_handle: &tauri::AppHandle,
    track_id: &str,
    fallback: u64,
) -> Result<u64> {
    let mut last_error: Option<anyhow::Error> = None;

    for attempt in 1..=TOTAL_SIZE_PROBE_RETRY_ATTEMPTS {
        let current_url = playback_url.lock().await.clone();
        match probe_total_size(client, &current_url, fallback).await {
            Ok(total_size) => return Ok(total_size),
            Err(error) => {
                warn!(
                    target: "cloudtune::download",
                    "track {} size probe attempt {}/{} failed: {}",
                    track_id,
                    attempt,
                    TOTAL_SIZE_PROBE_RETRY_ATTEMPTS,
                    error
                );
                last_error = Some(error);
            }
        }

        if attempt < TOTAL_SIZE_PROBE_RETRY_ATTEMPTS {
            if let Ok(refreshed_url) = refresh_download_playback_url(app_handle, track_id).await {
                *playback_url.lock().await = refreshed_url;
            }
            tokio::time::sleep(Duration::from_millis(next_download_retry_delay_ms(attempt))).await;
        }
    }

    if fallback > 0 {
        warn!(
            target: "cloudtune::download",
            "track {} size probe exhausted retries, falling back to known size {}",
            track_id,
            fallback
        );
        Ok(fallback)
    } else {
        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("failed to probe remote media size")))
    }
}

async fn download_range_part_with_retries(
    client: Client,
    app_handle: tauri::AppHandle,
    remote_request_slots: Arc<Semaphore>,
    playback_url: Arc<Mutex<String>>,
    track_id: String,
    start: u64,
    end: u64,
    part_path: PathBuf,
    transferred: Arc<AtomicU64>,
    cancel: Arc<AtomicBool>,
) -> Result<()> {
    let expected_len = end - start + 1;
    let mut written = fs::metadata(&part_path)
        .await
        .map(|meta| meta.len().min(expected_len))
        .unwrap_or(0);
    let mut retry_streak = 0_u8;
    let mut last_error = String::from("range download interrupted");

    while written < expected_len {
        if cancel.load(Ordering::SeqCst) {
            return Ok(());
        }

        let current_start = start + written;
        let current_url = playback_url.lock().await.clone();
        let _request_slot = remote_request_slots
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| anyhow::anyhow!("request slot closed"))?;

        let response = client
            .get(&current_url)
            .header(RANGE, format!("bytes={current_start}-{end}"))
            .send()
            .await;

        let mut response = match response {
            Ok(response) => {
                let status = response.status();
                if status == StatusCode::PARTIAL_CONTENT {
                    response
                } else {
                    last_error = format!("range request returned {}", status.as_u16());
                    retry_streak = retry_streak.saturating_add(1);
                    warn!(
                        target: "cloudtune::download",
                        "track {} part {}-{} attempt {}/{} returned {}",
                        track_id,
                        start,
                        end,
                        retry_streak,
                        MAX_DOWNLOAD_PART_RETRY_ATTEMPTS,
                        status
                    );

                    if should_refresh_download_url(status) {
                        if let Ok(refreshed_url) =
                            refresh_download_playback_url(&app_handle, &track_id).await
                        {
                            *playback_url.lock().await = refreshed_url;
                        }
                    }

                    if retry_streak >= MAX_DOWNLOAD_PART_RETRY_ATTEMPTS
                        || !should_retry_download_status(status)
                    {
                        anyhow::bail!(last_error);
                    }

                    tokio::time::sleep(Duration::from_millis(next_download_retry_delay_ms(
                        retry_streak,
                    )))
                    .await;
                    continue;
                }
            }
            Err(error) => {
                last_error = error.to_string();
                retry_streak = retry_streak.saturating_add(1);
                warn!(
                    target: "cloudtune::download",
                    "track {} part {}-{} attempt {}/{} request failed: {}",
                    track_id,
                    start,
                    end,
                    retry_streak,
                    MAX_DOWNLOAD_PART_RETRY_ATTEMPTS,
                    error
                );

                if retry_streak >= MAX_DOWNLOAD_PART_RETRY_ATTEMPTS {
                    return Err(error.into());
                }

                tokio::time::sleep(Duration::from_millis(next_download_retry_delay_ms(
                    retry_streak,
                )))
                .await;
                continue;
            }
        };

        let file = open_part_file(&part_path, written > 0).await?;
        let mut writer = BufWriter::new(file);
        let mut progressed = false;

        loop {
            match response.chunk().await {
                Ok(Some(chunk)) => {
                    if cancel.load(Ordering::SeqCst) {
                        let _ = writer.flush().await;
                        return Ok(());
                    }

                    writer.write_all(&chunk).await?;
                    transferred.fetch_add(chunk.len() as u64, Ordering::Relaxed);
                    written = written.saturating_add(chunk.len() as u64).min(expected_len);
                    progressed = true;
                }
                Ok(None) => {
                    writer.flush().await?;
                    break;
                }
                Err(error) => {
                    last_error = error.to_string();
                    warn!(
                        target: "cloudtune::download",
                        "track {} part {}-{} interrupted after {} bytes: {}",
                        track_id,
                        start,
                        end,
                        written,
                        error
                    );
                    let _ = writer.flush().await;
                    break;
                }
            }
        }

        if written >= expected_len {
            if retry_streak > 0 {
                info!(
                    target: "cloudtune::download",
                    "track {} part {}-{} recovered after retries",
                    track_id,
                    start,
                    end
                );
            }
            return Ok(());
        }

        if progressed {
            retry_streak = 0;
        } else {
            retry_streak = retry_streak.saturating_add(1);
        }

        if retry_streak >= MAX_DOWNLOAD_PART_RETRY_ATTEMPTS {
            anyhow::bail!(
                "range {}-{} failed after {} retries: {}",
                start,
                end,
                MAX_DOWNLOAD_PART_RETRY_ATTEMPTS,
                last_error
            );
        }

        warn!(
            target: "cloudtune::download",
            "track {} part {}-{} retrying from byte {} ({}/{})",
            track_id,
            start,
            end,
            start + written,
            retry_streak,
            MAX_DOWNLOAD_PART_RETRY_ATTEMPTS
        );
        tokio::time::sleep(Duration::from_millis(next_download_retry_delay_ms(
            retry_streak,
        )))
        .await;
    }

    Ok(())
}

async fn run_download_task(
    app_handle: tauri::AppHandle,
    task_id: String,
    spec: DownloadSpec,
    playback_url: String,
) -> Result<()> {
    let cancel = Arc::new(AtomicBool::new(false));
    let state = app_handle.state::<AppState>();
    {
        let mut controls = state.transfer_controls.lock().await;
        controls.insert(
            task_id.clone(),
            TransferControl {
                cancel: cancel.clone(),
                path: Some(spec.destination.clone()),
                download: Some(spec.clone()),
            },
        );
    }

    let client = build_media_client()?;
    let remote_request_slots = state.remote_request_slots.clone();
    let playback_url = Arc::new(Mutex::new(playback_url));

    let parts_dir = spec.destination.with_extension("parts");
    if let Some(parent) = spec.destination.parent() {
        let _ = fs::create_dir_all(parent).await;
    }
    let _ = fs::create_dir_all(&parts_dir).await;

    let total_size = {
        let _request_slot = remote_request_slots
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| anyhow::anyhow!("request slot closed"))?;
        probe_total_size_with_retries(
            &client,
            playback_url.clone(),
            &app_handle,
            &spec.track_id,
            spec.size_bytes,
        )
        .await?
    };
    info!(
        target: "cloudtune::download",
        "task {} preparing download for track {} with known size {}",
        task_id,
        spec.track_id,
        total_size
    );
    upsert_transfer_status(
        &state,
        &task_id,
        spec.file_name.clone(),
        transfer_kind_from_id(&task_id),
        "running".to_string(),
        Some(spec.destination.to_string_lossy().into_owned()),
        true,
        true,
        0,
        0,
        Some(total_size),
    )
    .await;

    let effective_threads = effective_download_thread_count(&task_id, spec.thread_count);
    if effective_threads != spec.thread_count.max(1) {
        info!(
            target: "cloudtune::download",
            "task {} limited playback download threads from {} to {}",
            task_id,
            spec.thread_count.max(1),
            effective_threads
        );
    }
    let ranges = split_ranges(total_size, effective_threads);
    let transferred = Arc::new(AtomicU64::new(
        completed_bytes_for_parts(&parts_dir, &ranges).await,
    ));
    let cancel_flag = cancel.clone();
    let mut jobs = JoinSet::new();

    for (index, (start, end)) in ranges.iter().copied().enumerate() {
        let part_path = parts_dir.join(format!("{index:02}.part"));
        let expected_len = end - start + 1;
        let existing = fs::metadata(&part_path)
            .await
            .map(|meta| meta.len())
            .unwrap_or(0);
        if existing >= expected_len {
            continue;
        }

        let client = client.clone();
        let playback_url = playback_url.clone();
        let transferred = transferred.clone();
        let cancel = cancel_flag.clone();
        let remote_request_slots = remote_request_slots.clone();
        let app_handle = app_handle.clone();
        let track_id = spec.track_id.clone();
        jobs.spawn(async move {
            download_range_part_with_retries(
                client,
                app_handle,
                remote_request_slots,
                playback_url,
                track_id,
                start + existing,
                end,
                part_path,
                transferred,
                cancel,
            )
            .await
        });
    }

    let mut failed: Option<String> = None;
    let mut last_transferred = transferred.load(Ordering::Relaxed);
    let mut last_tick = Instant::now();
    let mut ticker = tokio::time::interval(Duration::from_millis(350));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    while !jobs.is_empty() {
        tokio::select! {
            _ = ticker.tick() => {
                let transferred_now = transferred.load(Ordering::Relaxed);
                let delta = transferred_now.saturating_sub(last_transferred);
                let delta_secs = last_tick.elapsed().as_secs_f64().max(0.001);
                let speed = (delta as f64 / delta_secs) as u64;
                upsert_transfer_status(
                    &state,
                    &task_id,
                    spec.file_name.clone(),
                    transfer_kind_from_id(&task_id),
                    "running".to_string(),
                    Some(spec.destination.to_string_lossy().into_owned()),
                    true,
                    true,
                    speed,
                    transferred_now,
                    Some(total_size),
                ).await;
                last_transferred = transferred_now;
                last_tick = Instant::now();
            }
            Some(result) = jobs.join_next() => {
                match result {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => {
                        failed = Some(error.to_string());
                        cancel_flag.store(true, Ordering::SeqCst);
                        while jobs.join_next().await.is_some() {}
                    }
                    Err(error) => {
                        failed = Some(error.to_string());
                        cancel_flag.store(true, Ordering::SeqCst);
                        while jobs.join_next().await.is_some() {}
                    }
                }
            }
        }
    }

    let transferred = transferred.load(Ordering::Relaxed);
    if cancel_flag.load(Ordering::SeqCst) && failed.is_none() {
        upsert_transfer_status(
            &state,
            &task_id,
            spec.file_name.clone(),
            transfer_kind_from_id(&task_id),
            "paused".to_string(),
            Some(spec.destination.to_string_lossy().into_owned()),
            false,
            true,
            0,
            transferred,
            Some(total_size),
        )
        .await;
        return Ok(());
    }

    if let Some(error) = failed {
        upsert_transfer_status(
            &state,
            &task_id,
            spec.file_name.clone(),
            transfer_kind_from_id(&task_id),
            format!("failed: {error}"),
            Some(spec.destination.to_string_lossy().into_owned()),
            false,
            true,
            0,
            transferred,
            Some(total_size),
        )
        .await;
        warn!(
            target: "cloudtune::download",
            "task {} failed after {} bytes: {}",
            task_id,
            transferred,
            error
        );
        anyhow::bail!(error);
    }

    merge_part_files(&parts_dir, &spec.destination, ranges.len()).await?;
    upsert_transfer_status(
        &state,
        &task_id,
        spec.file_name,
        transfer_kind_from_id(&task_id),
        "completed".to_string(),
        Some(spec.destination.to_string_lossy().into_owned()),
        false,
        true,
        0,
        transferred,
        Some(total_size),
    )
    .await;
    Ok(())
}

fn spawn_download_task(
    app_handle: tauri::AppHandle,
    task_id: String,
    spec: DownloadSpec,
    playback_url: String,
) {
    tauri::async_runtime::spawn(async move {
        let _ = run_download_task(app_handle, task_id, spec, playback_url).await;
    });
}

async fn probe_total_size(client: &Client, url: &str, fallback: u64) -> Result<u64> {
    let response = client
        .get(url)
        .header(RANGE, "bytes=0-0")
        .send()
        .await?
        .error_for_status()?;
    let size = if response.status() == StatusCode::PARTIAL_CONTENT {
        total_size_from_content_range(response.headers().get(CONTENT_RANGE))
    } else {
        response
            .headers()
            .get(CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok())
    }
    .unwrap_or(fallback);
    Ok(size.max(fallback))
}

fn total_size_from_content_range(value: Option<&reqwest::header::HeaderValue>) -> Option<u64> {
    let text = value?.to_str().ok()?;
    text.rsplit('/').next()?.parse::<u64>().ok()
}

fn split_ranges(total_size: u64, parts: usize) -> Vec<(u64, u64)> {
    let part_size = total_size.div_ceil(parts as u64);
    let mut ranges = Vec::new();
    let mut start = 0_u64;
    while start < total_size {
        let end = (start + part_size - 1).min(total_size - 1);
        ranges.push((start, end));
        start = end + 1;
    }
    ranges
}

async fn completed_bytes_for_parts(parts_dir: &PathBuf, ranges: &[(u64, u64)]) -> u64 {
    let mut completed = 0_u64;
    for (index, (start, end)) in ranges.iter().enumerate() {
        let expected_len = end - start + 1;
        let path = parts_dir.join(format!("{index:02}.part"));
        let existing = fs::metadata(path).await.map(|meta| meta.len()).unwrap_or(0);
        completed += existing.min(expected_len);
    }
    completed
}

async fn open_part_file(path: &PathBuf, append: bool) -> Result<fs::File> {
    if append {
        Ok(tokio::fs::OpenOptions::new()
            .append(true)
            .open(path)
            .await?)
    } else {
        Ok(fs::File::create(path).await?)
    }
}

async fn merge_part_files(
    parts_dir: &PathBuf,
    destination: &PathBuf,
    part_count: usize,
) -> Result<()> {
    let file = fs::File::create(destination).await?;
    let mut writer = BufWriter::new(file);
    for index in 0..part_count {
        let part_path = parts_dir.join(format!("{index:02}.part"));
        if let Ok(bytes) = fs::read(&part_path).await {
            writer.write_all(&bytes).await?;
        }
    }
    writer.flush().await?;
    let _ = fs::remove_dir_all(parts_dir).await;
    Ok(())
}

async fn wait_for_prefetched_track(
    state: &AppState,
    track_id: &str,
    timeout: Duration,
) -> Option<(String, u64)> {
    let started_at = Instant::now();

    loop {
        {
            let mut runtime = state.inner.lock().await;
            let cache_dir = runtime.cache_dir.clone();

            if let Some(cached_path) = runtime.cache_index.existing_path(track_id, &cache_dir) {
                let cache_usage_bytes = runtime.prune_cache_to_limit(&[track_id]).ok()?;
                let _ = runtime.save_cache_index();
                return Some((
                    cached_path.to_string_lossy().into_owned(),
                    cache_usage_bytes,
                ));
            }

            if !runtime.active_cache_downloads.contains(track_id) {
                return None;
            }
        }

        if started_at.elapsed() >= timeout {
            return None;
        }

        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

fn spawn_background_cache(
    app_handle: tauri::AppHandle,
    track_id: String,
    cache_file_name: String,
    destination: std::path::PathBuf,
    playback_url: String,
    expected_size: u64,
    cache_threads: usize,
) {
    tauri::async_runtime::spawn(async move {
        let state = app_handle.state::<AppState>();

        let cloud = {
            let runtime = state.inner.lock().await;
            runtime.cloud.clone()
        };

        let result = cloud
            .cache_direct_url_to(
                &playback_url,
                &destination,
                Some(expected_size),
                Some(cache_threads),
            )
            .await;

        let mut runtime = state.inner.lock().await;
        runtime.active_cache_downloads.remove(&track_id);

        if let Ok(downloaded_size) = result {
            runtime.cache_index.record(
                track_id.clone(),
                cache_file_name,
                downloaded_size.max(expected_size),
            );
            let _ = runtime.prune_cache_to_limit(&[track_id.as_str()]);
            let _ = runtime.save_cache_index();
        }
    });
}

#[tauri::command]
pub async fn bootstrap(state: State<'_, AppState>) -> Result<BootstrapPayload, String> {
    let mut runtime = state.inner.lock().await;
    build_bootstrap_payload(&mut runtime, None).map_err(to_command_error)
}

#[tauri::command]
pub async fn start_qr_login(
    state: State<'_, AppState>,
) -> Result<crate::models::QrLoginStart, String> {
    let mut runtime = state.inner.lock().await;
    runtime
        .cloud
        .start_qr_login()
        .await
        .map_err(to_command_error)
}

#[tauri::command]
pub async fn poll_qr_login(
    state: State<'_, AppState>,
) -> Result<crate::models::QrPollResponse, String> {
    let mut runtime = state.inner.lock().await;
    let payload = runtime
        .cloud
        .poll_qr_login()
        .await
        .map_err(to_command_error)?;
    sync_refresh_token(&mut runtime).map_err(to_command_error)?;
    Ok(payload)
}

#[tauri::command]
pub async fn list_remote_folder(
    state: State<'_, AppState>,
    folder_id: Option<String>,
) -> Result<crate::models::FolderBrowsePayload, String> {
    let mut runtime = state.inner.lock().await;
    ensure_authenticated(&mut runtime)
        .await
        .map_err(to_command_error)?;
    runtime
        .cloud
        .list_remote_folder(folder_id)
        .await
        .map_err(to_command_error)
}

#[tauri::command]
pub async fn save_music_folder(
    state: State<'_, AppState>,
    folder_id: String,
    folder_name: String,
) -> Result<SettingsPayload, String> {
    let mut runtime = state.inner.lock().await;
    let next_folder_id = if folder_id.trim().is_empty() {
        ROOT_FOLDER_ID.to_string()
    } else {
        folder_id
    };

    runtime.config.music_folder_id = Some(next_folder_id);
    runtime.config.music_folder_name = Some(folder_name);
    runtime.save_config().map_err(to_command_error)?;

    build_settings_payload(&mut runtime).map_err(to_command_error)
}

#[tauri::command]
pub async fn scan_library(state: State<'_, AppState>) -> Result<Vec<TrackSummary>, String> {
    let mut runtime = state.inner.lock().await;
    ensure_authenticated(&mut runtime)
        .await
        .map_err(to_command_error)?;

    let current_folder = runtime
        .config
        .current_folder()
        .context("请先选择音乐目录")
        .map_err(to_command_error)?;

    runtime
        .cloud
        .scan_music_library(&current_folder.id, &current_folder.name)
        .await
        .and_then(|tracks| {
            runtime.save_library_tracks(&tracks)?;
            Ok(tracks)
        })
        .map_err(to_command_error)
}

#[tauri::command]
pub async fn prepare_track(
    state: State<'_, AppState>,
    track_id: String,
    file_name: String,
    size_bytes: u64,
    for_playback: bool,
    playback_mode_override: Option<String>,
) -> Result<PreparedTrack, String> {
    let mut runtime = state.inner.lock().await;
    ensure_authenticated(&mut runtime)
        .await
        .map_err(to_command_error)?;
    let cache_dir = runtime.cache_dir.clone();
    let cache_threads = runtime.config.cache_threads as usize;
    let playback_mode =
        playback_mode_override.unwrap_or_else(|| runtime.config.playback_mode.clone());

    if let Some(cached_path) = runtime.cache_index.existing_path(&track_id, &cache_dir) {
        let cache_usage_bytes = runtime
            .prune_cache_to_limit(&[track_id.as_str()])
            .map_err(to_command_error)?;
        runtime.save_cache_index().map_err(to_command_error)?;

        return Ok(PreparedTrack {
            track_id,
            local_path: cached_path.to_string_lossy().into_owned(),
            playback_url: cached_path.to_string_lossy().into_owned(),
            is_streaming: false,
            cache_usage_bytes,
        });
    }

    if for_playback
        && playback_mode == "download_first"
        && runtime.active_cache_downloads.contains(&track_id)
    {
        drop(runtime);

        if let Some((cached_path, cache_usage_bytes)) =
            wait_for_prefetched_track(&state, &track_id, Duration::from_secs(6)).await
        {
            return Ok(PreparedTrack {
                track_id,
                local_path: cached_path.clone(),
                playback_url: cached_path,
                is_streaming: false,
                cache_usage_bytes,
            });
        }

        runtime = state.inner.lock().await;
        ensure_authenticated(&mut runtime)
            .await
            .map_err(to_command_error)?;
    }

    let cache_file_name = format!("{}-{}", track_id, sanitize_file_name(&file_name));
    let destination = cache_dir.join(&cache_file_name);
    let playback_url = runtime
        .cloud
        .playback_url(&track_id)
        .await
        .map_err(to_command_error)?;
    let app_handle = runtime.app_handle.clone();
    if !for_playback && !runtime.active_cache_downloads.contains(&track_id) {
        let prefetch_threads = effective_prefetch_thread_count(cache_threads);
        if prefetch_threads != cache_threads.max(1) {
            info!(
                target: "cloudtune::download",
                "track {} limited prefetch threads from {} to {}",
                track_id,
                cache_threads.max(1),
                prefetch_threads
            );
        }
        runtime.active_cache_downloads.insert(track_id.clone());
        spawn_background_cache(
            app_handle.clone(),
            track_id.clone(),
            cache_file_name.clone(),
            destination.clone(),
            playback_url.clone(),
            size_bytes,
            prefetch_threads,
        );
    }

    let cache_usage_bytes = runtime.cache_index.usage_bytes(&cache_dir);
    runtime.save_cache_index().map_err(to_command_error)?;
    let playback_target = if for_playback {
        if playback_mode == "download_first" {
            info!(
                target: "cloudtune::playback",
                "track {} cache miss under preferred-cache mode, switching to resilient streaming",
                track_id
            );
        }
        let mut sources = state.stream_sources.lock().await;
        sources.insert(
            track_id.clone(),
            crate::streaming::StreamSource {
                track_id: track_id.clone(),
                playback_url: playback_url.clone(),
                cache_path: destination.clone(),
                expected_size: size_bytes,
                label: file_name.clone(),
            },
        );
        format!(
            "http://127.0.0.1:{}/stream/{}/{}",
            state.stream_server_port,
            track_id,
            sanitize_file_name(&file_name)
        )
    } else {
        playback_url.clone()
    };

    Ok(PreparedTrack {
        track_id,
        local_path: destination.to_string_lossy().into_owned(),
        playback_url: playback_target,
        is_streaming: for_playback,
        cache_usage_bytes,
    })
}

#[tauri::command]
pub async fn update_cache_limit(
    state: State<'_, AppState>,
    limit_mb: u64,
) -> Result<SettingsPayload, String> {
    if limit_mb < 256 {
        return Err("缓存上限至少设置为 256 MB".to_string());
    }

    let mut runtime = state.inner.lock().await;
    runtime.config.cache_limit_mb = limit_mb;
    runtime.save_config().map_err(to_command_error)?;
    build_settings_payload(&mut runtime).map_err(to_command_error)
}

#[tauri::command]
pub async fn update_transfer_tuning(
    state: State<'_, AppState>,
    download_threads: u16,
    cache_threads: u16,
) -> Result<SettingsPayload, String> {
    if !(1..=MAX_DOWNLOAD_THREADS).contains(&download_threads) {
        return Err(format!("下载线程范围是 1-{MAX_DOWNLOAD_THREADS}"));
    }
    if !(1..=MAX_CACHE_THREADS).contains(&cache_threads) {
        return Err(format!("缓存线程范围是 1-{MAX_CACHE_THREADS}"));
    }

    let mut runtime = state.inner.lock().await;
    runtime.config.download_threads = download_threads;
    runtime.config.cache_threads = cache_threads;
    runtime.save_config().map_err(to_command_error)?;
    build_settings_payload(&mut runtime).map_err(to_command_error)
}

#[tauri::command]
pub async fn update_playback_mode(
    state: State<'_, AppState>,
    playback_mode: String,
) -> Result<SettingsPayload, String> {
    if playback_mode != "download_first" && playback_mode != "stream_cache" {
        return Err("播放模式不合法".to_string());
    }

    let mut runtime = state.inner.lock().await;
    runtime.config.playback_mode = playback_mode;
    runtime.save_config().map_err(to_command_error)?;
    build_settings_payload(&mut runtime).map_err(to_command_error)
}

#[tauri::command]
pub async fn update_playback_context(
    state: State<'_, AppState>,
    current_track_id: Option<String>,
    next_track_id: Option<String>,
) -> Result<(), String> {
    let mut runtime = state.inner.lock().await;
    runtime.protected_cache_tracks.clear();
    if let Some(current_track_id) = current_track_id.filter(|value| !value.trim().is_empty()) {
        runtime.protected_cache_tracks.insert(current_track_id);
    }
    if let Some(next_track_id) = next_track_id.filter(|value| !value.trim().is_empty()) {
        runtime.protected_cache_tracks.insert(next_track_id);
    }
    let _ = runtime.prune_cache_to_limit(&[]);
    runtime.save_cache_index().map_err(to_command_error)?;
    Ok(())
}

#[tauri::command]
pub async fn logout(state: State<'_, AppState>) -> Result<BootstrapPayload, String> {
    let mut runtime = state.inner.lock().await;
    runtime.cloud.clear_session();
    runtime.config.refresh_token = None;
    runtime.config.account_name = None;
    runtime.save_config().map_err(to_command_error)?;
    build_bootstrap_payload(&mut runtime, None).map_err(to_command_error)
}

#[tauri::command]
pub async fn get_transfer_snapshot(
    state: State<'_, AppState>,
) -> Result<TransferSnapshotPayload, String> {
    let transfers = state.transfer_statuses.lock().await;
    let items = transfers.values().cloned().collect::<Vec<_>>();
    let total_speed_bytes_per_second = items
        .iter()
        .filter(|item| item.state == "running" || item.state == "streaming")
        .map(|item| item.bytes_per_second)
        .sum();

    Ok(TransferSnapshotPayload {
        total_speed_bytes_per_second,
        items,
    })
}

#[tauri::command]
pub async fn pick_download_directory() -> Result<Option<String>, String> {
    Ok(rfd::FileDialog::new()
        .pick_folder()
        .map(|path| path.to_string_lossy().into_owned()))
}

#[tauri::command]
pub async fn download_track_to_directory(
    state: State<'_, AppState>,
    track_id: String,
    file_name: String,
    size_bytes: u64,
    directory: String,
) -> Result<String, String> {
    let target_dir = std::path::PathBuf::from(&directory);
    let destination = target_dir.join(sanitize_file_name(&file_name));

    let mut runtime = state.inner.lock().await;
    ensure_authenticated(&mut runtime)
        .await
        .map_err(to_command_error)?;
    let playback_url = runtime
        .cloud
        .playback_url(&track_id)
        .await
        .map_err(to_command_error)?;
    let app_handle = runtime.app_handle.clone();
    let download_threads = runtime.config.download_threads as usize;
    drop(runtime);

    let task_id = format!("download:{}", Uuid::new_v4());
    spawn_download_task(
        app_handle,
        task_id.clone(),
        DownloadSpec {
            track_id,
            file_name,
            size_bytes,
            destination,
            thread_count: download_threads.max(1),
        },
        playback_url,
    );
    Ok(task_id)
}

#[tauri::command]
pub async fn download_folder_to_directory(
    state: State<'_, AppState>,
    folder_id: String,
    folder_name: String,
    directory: String,
) -> Result<String, String> {
    let target_dir = std::path::PathBuf::from(&directory);
    let mut runtime = state.inner.lock().await;
    ensure_authenticated(&mut runtime)
        .await
        .map_err(to_command_error)?;
    let files = runtime
        .cloud
        .scan_all_files(&folder_id, &folder_name)
        .await
        .map_err(to_command_error)?;
    let app_handle = runtime.app_handle.clone();
    let mut cloud = runtime.cloud.clone();
    let download_threads = runtime.config.download_threads as usize;
    drop(runtime);

    let mut queued = 0_u64;
    for track in files {
        let playback_url = cloud
            .playback_url(&track.id)
            .await
            .map_err(to_command_error)?;
        let relative_folder = track
            .folder_path
            .trim_start_matches(&folder_name)
            .trim_start_matches('/')
            .to_string();
        let destination_root = target_dir.join(&folder_name);
        let destination = if relative_folder.is_empty() {
            destination_root.join(sanitize_file_name(&track.name))
        } else {
            destination_root
                .join(relative_folder)
                .join(sanitize_file_name(&track.name))
        };
        let task_id = format!("download:{}", Uuid::new_v4());
        spawn_download_task(
            app_handle.clone(),
            task_id,
            DownloadSpec {
                track_id: track.id.clone(),
                file_name: track.name.clone(),
                size_bytes: track.size_bytes,
                destination,
                thread_count: download_threads.max(1),
            },
            playback_url,
        );
        queued += 1;
    }

    Ok(format!("queued:{queued}"))
}

#[tauri::command]
pub async fn open_video_in_system(
    state: State<'_, AppState>,
    track_id: String,
) -> Result<(), String> {
    let mut runtime = state.inner.lock().await;
    ensure_authenticated(&mut runtime)
        .await
        .map_err(to_command_error)?;
    let playback_url = runtime
        .cloud
        .playback_url(&track_id)
        .await
        .map_err(to_command_error)?;
    drop(runtime);
    open::that(playback_url).map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn read_track_metadata(
    state: State<'_, AppState>,
    local_path: String,
    fallback_name: String,
    fallback_album: String,
) -> Result<NowPlayingMetadata, String> {
    let app_handle = {
        let runtime = state.inner.lock().await;
        runtime.app_handle.clone()
    };
    let runtime_paths = RuntimePaths::resolve(&app_handle).map_err(|error| error.to_string())?;

    let parsed = tokio::task::spawn_blocking({
        let local_path = local_path.clone();
        move || parse_track_metadata(PathBuf::from(&local_path), fallback_name, fallback_album)
    })
    .await
    .map_err(|error| error.to_string())?;

    let artwork_path = if let (Some(bytes), Some(extension)) =
        (&parsed.artwork_bytes, &parsed.artwork_extension)
    {
        persist_artwork_file(&runtime_paths.artwork_dir, &local_path, bytes, extension)
            .await
            .ok()
    } else {
        None
    };

    Ok(NowPlayingMetadata {
        title: parsed.title,
        artist: parsed.artist,
        album: parsed.album,
        artwork_path,
    })
}

#[tauri::command]
pub async fn pause_transfer(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let controls = state.transfer_controls.lock().await;
    if let Some(control) = controls.get(&id) {
        control.cancel.store(true, Ordering::SeqCst);
    }
    Ok(())
}

#[tauri::command]
pub async fn delete_transfer(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let mut controls = state.transfer_controls.lock().await;
    if let Some(control) = controls.remove(&id) {
        control.cancel.store(true, Ordering::SeqCst);
        if let Some(path) = control.path {
            let _ = std::fs::remove_file(&path);
            let _ = std::fs::remove_file(path.with_extension("part"));
            let _ = std::fs::remove_dir_all(path.with_extension("parts"));
        }
    }
    drop(controls);
    let mut transfers = state.transfer_statuses.lock().await;
    transfers.remove(&id);
    Ok(())
}

#[tauri::command]
pub async fn resume_transfer(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let download_spec = {
        let controls = state.transfer_controls.lock().await;
        controls
            .get(&id)
            .and_then(|control| control.download.clone())
            .context("该任务不支持继续")
            .map_err(to_command_error)?
    };

    let mut runtime = state.inner.lock().await;
    ensure_authenticated(&mut runtime)
        .await
        .map_err(to_command_error)?;
    let playback_url = runtime
        .cloud
        .playback_url(&download_spec.track_id)
        .await
        .map_err(to_command_error)?;
    let app_handle = runtime.app_handle.clone();
    drop(runtime);

    spawn_download_task(app_handle, id, download_spec, playback_url);
    Ok(())
}
