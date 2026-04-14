use std::{collections::HashMap, net::TcpListener, path::PathBuf, sync::Arc, time::Instant};

use anyhow::Result;
use log::{info, warn};
use axum::{
    Router,
    body::Body,
    extract::{Path as AxumPath, State as AxumState},
    http::{
        HeaderMap, HeaderValue, Response, StatusCode,
        header::{ACCEPT_RANGES, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE, RANGE},
    },
    response::IntoResponse,
    routing::get,
};
use bytes::Bytes;
use mime_guess::MimeGuess;
use reqwest::{Client, StatusCode as ReqwestStatusCode, header::RANGE as REQWEST_RANGE};
use tauri::{AppHandle, Manager};
use tokio::{
    fs,
    io::{AsyncWriteExt, BufWriter},
    sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc},
};
use tokio_stream::wrappers::ReceiverStream;

use crate::{cloud189::build_media_client, models::TransferStatus, state::AppState};

const MAX_STREAM_RESUME_ATTEMPTS: u8 = 6;
const STREAM_RESUME_DELAY_MS: u64 = 900;

pub type StreamSourceStore = Arc<Mutex<HashMap<String, StreamSource>>>;
pub type TransferStore = Arc<Mutex<HashMap<String, TransferStatus>>>;

#[derive(Debug, Clone)]
pub struct StreamSource {
    pub track_id: String,
    pub playback_url: String,
    pub cache_path: PathBuf,
    pub expected_size: u64,
    pub label: String,
}

#[derive(Clone)]
struct StreamServerState {
    app_handle: AppHandle,
    client: Client,
    sources: StreamSourceStore,
    transfers: TransferStore,
    remote_request_slots: Arc<Semaphore>,
}

pub fn start_stream_server(
    app_handle: AppHandle,
    sources: StreamSourceStore,
    transfers: TransferStore,
    remote_request_slots: Arc<Semaphore>,
) -> Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let port = listener.local_addr()?.port();

    let state = StreamServerState {
        app_handle,
        client: build_media_client()?,
        sources,
        transfers,
        remote_request_slots,
    };

    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("failed to build streaming runtime");

        runtime.block_on(async move {
            let listener = tokio::net::TcpListener::from_std(listener)
                .expect("failed to adopt streaming listener");
            let router = Router::new()
                .route(
                    "/stream/{track_id}/{file_name}",
                    get(handle_stream).head(handle_stream_head),
                )
                .with_state(state);
            let _ = axum::serve(listener, router).await;
        });
    });

    Ok(port)
}

async fn handle_stream(
    AxumPath((track_id, _file_name)): AxumPath<(String, String)>,
    AxumState(state): AxumState<StreamServerState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let source = {
        let sources = state.sources.lock().await;
        sources.get(&track_id).cloned()
    };

    let Some(mut source) = source else {
        return (StatusCode::NOT_FOUND, "stream source not found").into_response();
    };

    let range_header = headers
        .get(RANGE)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string);

    let request_slot = match state.remote_request_slots.clone().acquire_owned().await {
        Ok(slot) => slot,
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "stream request queue is unavailable",
            )
                .into_response();
        }
    };

    let mut response =
        match send_stream_request(&state.client, &source.playback_url, range_header.as_deref())
            .await
        {
            Ok(response) => response,
            Err(error) => {
                return (
                    StatusCode::BAD_GATEWAY,
                    format!("failed to fetch remote media: {error}"),
                )
                    .into_response();
            }
        };

    if should_refresh_playback_url(response.status()) {
        if let Some(refreshed_source) =
            refresh_stream_source(&state.app_handle, &state.sources, &track_id).await
        {
            source = refreshed_source;
            response = match send_stream_request(
                &state.client,
                &source.playback_url,
                range_header.as_deref(),
            )
            .await
            {
                Ok(response) => response,
                Err(error) => {
                    return (
                        StatusCode::BAD_GATEWAY,
                        format!("failed to refresh remote media: {error}"),
                    )
                        .into_response();
                }
            };
        }
    }

    let status = response.status();
    if !status.is_success() && status != StatusCode::PARTIAL_CONTENT {
        return (
            StatusCode::BAD_GATEWAY,
            format!("remote media returned {}", status.as_u16()),
        )
            .into_response();
    }

    let mut response_headers = HeaderMap::new();
    let content_type = guess_content_type(&source.label)
        .or_else(|| response.headers().get(CONTENT_TYPE).cloned())
        .unwrap_or_else(|| HeaderValue::from_static("application/octet-stream"));
    response_headers.insert(CONTENT_TYPE, content_type);
    if let Some(value) = response.headers().get(CONTENT_LENGTH).cloned() {
        response_headers.insert(CONTENT_LENGTH, value);
    }
    if let Some(value) = response.headers().get(CONTENT_RANGE).cloned() {
        response_headers.insert(CONTENT_RANGE, value);
    }
    response_headers.insert(ACCEPT_RANGES, HeaderValue::from_static("bytes"));

    let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(16);
    let transfer_id = format!("stream:{}", source.track_id);
    let can_cache = range_header
        .as_ref()
        .map(|value| value.starts_with("bytes=0-"))
        .unwrap_or(true);

    tokio::spawn(stream_and_cache_task(
        state.app_handle.clone(),
        state.transfers.clone(),
        transfer_id,
        source,
        response,
        tx,
        can_cache,
        request_slot,
    ));

    let body = Body::from_stream(ReceiverStream::new(rx));
    let mut builder = Response::builder().status(status);
    if let Some(headers_mut) = builder.headers_mut() {
        *headers_mut = response_headers;
    }
    builder
        .body(body)
        .unwrap_or_else(|_| Response::new(Body::empty()))
}

async fn handle_stream_head(
    AxumPath((track_id, _file_name)): AxumPath<(String, String)>,
    AxumState(state): AxumState<StreamServerState>,
) -> impl IntoResponse {
    let source = {
        let sources = state.sources.lock().await;
        sources.get(&track_id).cloned()
    };

    let Some(mut source) = source else {
        return (StatusCode::NOT_FOUND, "stream source not found").into_response();
    };

    let request_slot = match state.remote_request_slots.clone().acquire_owned().await {
        Ok(slot) => slot,
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "stream request queue is unavailable",
            )
                .into_response();
        }
    };

    let mut response =
        match send_stream_request(&state.client, &source.playback_url, Some("bytes=0-0")).await {
            Ok(response) => response,
            Err(error) => {
                return (
                    StatusCode::BAD_GATEWAY,
                    format!("failed to probe remote media: {error}"),
                )
                    .into_response();
            }
        };
    drop(request_slot);

    if should_refresh_playback_url(response.status()) {
        if let Some(refreshed_source) =
            refresh_stream_source(&state.app_handle, &state.sources, &track_id).await
        {
            source = refreshed_source;
            response =
                match send_stream_request(&state.client, &source.playback_url, Some("bytes=0-0"))
                    .await
                {
                    Ok(response) => response,
                    Err(error) => {
                        return (
                            StatusCode::BAD_GATEWAY,
                            format!("failed to refresh remote media probe: {error}"),
                        )
                            .into_response();
                    }
                };
        }
    }

    let mut headers = HeaderMap::new();
    let content_type = guess_content_type(&source.label)
        .or_else(|| response.headers().get(CONTENT_TYPE).cloned())
        .unwrap_or_else(|| HeaderValue::from_static("application/octet-stream"));
    headers.insert(CONTENT_TYPE, content_type);
    let total_length = total_size_from_content_range(response.headers().get(CONTENT_RANGE))
        .or_else(|| {
            header_to_u64(response.headers().get(CONTENT_LENGTH)).or(if source.expected_size > 0 {
                Some(source.expected_size)
            } else {
                None
            })
        });
    if let Some(total_length) = total_length {
        if let Ok(value) = HeaderValue::from_str(&total_length.to_string()) {
            headers.insert(CONTENT_LENGTH, value);
        }
    }
    headers.insert(ACCEPT_RANGES, HeaderValue::from_static("bytes"));

    let mut builder = Response::builder().status(StatusCode::OK);
    if let Some(headers_mut) = builder.headers_mut() {
        *headers_mut = headers;
    }
    builder
        .body(Body::empty())
        .unwrap_or_else(|_| Response::new(Body::empty()))
}

async fn stream_and_cache_task(
    app_handle: AppHandle,
    transfers: TransferStore,
    transfer_id: String,
    source: StreamSource,
    mut response: reqwest::Response,
    tx: mpsc::Sender<Result<Bytes, std::io::Error>>,
    can_cache: bool,
    _request_slot: OwnedSemaphorePermit,
) {
    let expected_total =
        header_to_u64(response.headers().get(CONTENT_LENGTH)).or(if source.expected_size > 0 {
            Some(source.expected_size)
        } else {
            None
        });

    let temp_path = source.cache_path.with_extension("part");
    let mut writer = if can_cache {
        if let Some(parent) = temp_path.parent() {
            let _ = fs::create_dir_all(parent).await;
        }
        let _ = fs::remove_file(&temp_path).await;
        match fs::File::create(&temp_path).await {
            Ok(file) => Some(BufWriter::new(file)),
            Err(_) => None,
        }
    } else {
        None
    };

    let mut transferred = 0_u64;
    let mut last_tick = Instant::now();
    let mut last_transferred = 0_u64;
    let mut resume_attempts = 0_u8;
    update_transfer(
        &transfers,
        transfer_id.clone(),
        source.label.clone(),
        "stream".to_string(),
        "running".to_string(),
        None,
        false,
        false,
        0,
        0,
        expected_total,
    )
    .await;

    let mut finished_without_error = true;
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) => {
                transferred = transferred.saturating_add(chunk.len() as u64);
                resume_attempts = 0;

                if let Some(writer_ref) = writer.as_mut() {
                    if writer_ref.write_all(&chunk).await.is_err() {
                        writer = None;
                    }
                }

                if tx.send(Ok(chunk.clone())).await.is_err() {
                    finished_without_error = false;
                    break;
                }

                if last_tick.elapsed().as_millis() >= 350 {
                    let delta_bytes = transferred.saturating_sub(last_transferred);
                    let delta_secs = last_tick.elapsed().as_secs_f64().max(0.001);
                    let speed = (delta_bytes as f64 / delta_secs) as u64;
                    update_transfer(
                        &transfers,
                        transfer_id.clone(),
                        source.label.clone(),
                        "stream".to_string(),
                        "running".to_string(),
                        None,
                        false,
                        false,
                        speed,
                        transferred,
                        expected_total,
                    )
                    .await;
                    last_tick = Instant::now();
                    last_transferred = transferred;
                }
            }
            Ok(None) => break,
            Err(error) => {
                if transferred == 0 || resume_attempts >= MAX_STREAM_RESUME_ATTEMPTS {
                    warn!(target: "cloudtune::streaming", "stream {} stopped after {} bytes: {}", source.track_id, transferred, error);
                    finished_without_error = false;
                    break;
                }

                resume_attempts = resume_attempts.saturating_add(1);
                warn!(target: "cloudtune::streaming", "stream {} interrupted, resume attempt {} from byte {}", source.track_id, resume_attempts, transferred);
                let resume_range = format!("bytes={}-", transferred);
                tokio::time::sleep(tokio::time::Duration::from_millis(
                    STREAM_RESUME_DELAY_MS * u64::from(resume_attempts),
                ))
                .await;

                match send_stream_request(
                    &build_media_client().unwrap_or_else(|_| Client::new()),
                    &source.playback_url,
                    Some(&resume_range),
                )
                .await
                {
                    Ok(next_response)
                        if next_response.status().is_success()
                            || next_response.status() == ReqwestStatusCode::PARTIAL_CONTENT =>
                    {
                        info!(target: "cloudtune::streaming", "stream {} resumed from byte {}", source.track_id, transferred);
                        response = next_response;
                        continue;
                    }
                    Ok(next_response) => {
                        warn!(target: "cloudtune::streaming", "stream {} resume returned {}", source.track_id, next_response.status());
                        finished_without_error = false;
                        break;
                    }
                    Err(resume_error) => {
                        warn!(target: "cloudtune::streaming", "stream {} resume failed: {}", source.track_id, resume_error);
                        finished_without_error = false;
                        break;
                    }
                }
            }
        }
    }

    drop(tx);

    if let Some(mut writer) = writer {
        let _ = writer.flush().await;
    }

    remove_transfer(&transfers, &transfer_id).await;

    if can_cache && finished_without_error {
        let total_size = expected_total.unwrap_or(transferred);
        if transferred >= total_size && total_size > 0 {
            let _ = fs::rename(&temp_path, &source.cache_path).await;
            let state = app_handle.state::<AppState>();
            let mut runtime = state.inner.lock().await;
            runtime.cache_index.record(
                source.track_id.clone(),
                source
                    .cache_path
                    .file_name()
                    .map(|value| value.to_string_lossy().into_owned())
                    .unwrap_or_else(|| source.track_id.clone()),
                transferred,
            );
            let cache_dir = runtime.cache_dir.clone();
            let cache_limit_bytes = runtime.config.cache_limit_bytes();
            let _ = runtime.cache_index.prune_to_limit(
                &cache_dir,
                cache_limit_bytes,
                Some(source.track_id.as_str()),
            );
            let _ = runtime.save_cache_index();
        } else {
            let _ = fs::remove_file(&temp_path).await;
        }
    } else {
        let _ = fs::remove_file(&temp_path).await;
    }
}

async fn update_transfer(
    store: &TransferStore,
    id: String,
    label: String,
    kind: String,
    state: String,
    path: Option<String>,
    can_pause: bool,
    can_delete: bool,
    bytes_per_second: u64,
    transferred_bytes: u64,
    total_bytes: Option<u64>,
) {
    let mut transfers = store.lock().await;
    transfers.insert(
        id.clone(),
        TransferStatus {
            id,
            label,
            kind,
            can_resume: state == "paused",
            state,
            path,
            can_pause,
            can_delete,
            bytes_per_second,
            transferred_bytes,
            total_bytes,
        },
    );
}

async fn remove_transfer(store: &TransferStore, id: &str) {
    let mut transfers = store.lock().await;
    transfers.remove(id);
}

async fn send_stream_request(
    client: &Client,
    playback_url: &str,
    range_header: Option<&str>,
) -> reqwest::Result<reqwest::Response> {
    let mut request = client.get(playback_url);
    if let Some(range) = range_header {
        request = request.header(REQWEST_RANGE, range);
    }
    request.send().await
}

async fn refresh_stream_source(
    app_handle: &AppHandle,
    sources: &StreamSourceStore,
    track_id: &str,
) -> Option<StreamSource> {
    let playback_url = {
        let state = app_handle.state::<AppState>();
        let mut runtime = state.inner.lock().await;
        runtime.cloud.playback_url(track_id).await.ok()?
    };

    let mut source_store = sources.lock().await;
    let source = source_store.get_mut(track_id)?;
    source.playback_url = playback_url;
    Some(source.clone())
}

fn should_refresh_playback_url(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::FORBIDDEN | StatusCode::NOT_FOUND | StatusCode::GONE
    )
}

fn header_to_u64(value: Option<&HeaderValue>) -> Option<u64> {
    value
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
}

fn total_size_from_content_range(value: Option<&HeaderValue>) -> Option<u64> {
    let text = value?.to_str().ok()?;
    text.rsplit('/').next()?.parse::<u64>().ok()
}

fn guess_content_type(name: &str) -> Option<HeaderValue> {
    let mime = MimeGuess::from_path(name).first_raw()?;
    HeaderValue::from_str(mime).ok()
}
