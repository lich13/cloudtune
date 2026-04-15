use crate::models::{
    FolderBrowsePayload, QrLoginStart, QrLoginState, QrPollResponse, RemoteFolder, TrackSummary,
};
use anyhow::{Context, Result, bail};
use hmac::{Hmac, Mac};
use httpdate::fmt_http_date;
use quick_xml::de::from_str as parse_xml;
use rand::Rng;
use regex::Regex;
use reqwest::{
    Client, StatusCode,
    header::{
        ACCEPT, ACCEPT_RANGES, CONTENT_LENGTH, CONTENT_RANGE, HeaderMap, HeaderValue, RANGE,
        REFERER,
    },
};
use serde::Deserialize;
use serde_json::Value;
use sha1::Sha1;
use std::{
    collections::VecDeque,
    path::{Path, PathBuf},
    time::SystemTime,
};
use tauri_plugin_log::log::{info, warn};
use tokio::{
    fs,
    io::{AsyncWriteExt, BufWriter},
};
use url::Url;
use uuid::Uuid;

pub const ROOT_FOLDER_ID: &str = "-11";
const ROOT_FOLDER_NAME: &str = "我的云盘";
const WEB_URL: &str = "https://cloud.189.cn";
const AUTH_URL: &str = "https://open.e.189.cn";
const API_URL: &str = "https://api.cloud.189.cn";
const APP_ID: &str = "8025431004";
const CLIENT_TYPE: &str = "10020";
const RETURN_URL: &str = "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html";
const PC_CLIENT: &str = "TELEPC";
const VERSION: &str = "6.2";
const CHANNEL_ID: &str = "web_cloud.189.cn";
pub const CLOUDTUNE_USER_AGENT: &str = "CloudTune/0.1.0";
pub const CLOUD189_REFERER: &str = "https://cloud.189.cn/";
const MIN_PARALLEL_DOWNLOAD_SIZE: u64 = 512 * 1024;
const MAX_PARALLEL_DOWNLOADS: usize = 32;
const MAX_PARALLEL_RANGE_RETRY_ATTEMPTS: u8 = 10;
const PARALLEL_RANGE_RETRY_DELAY_MS: u64 = 1200;
const PARALLEL_RANGE_RETRY_MAX_DELAY_MS: u64 = 10000;

type HmacSha1 = Hmac<Sha1>;

#[derive(Debug, Clone, Default)]
struct SessionTokens {
    access_token: String,
    refresh_token: String,
    session_key: String,
    session_secret: String,
    login_name: Option<String>,
}

#[derive(Debug, Clone)]
struct PendingQrLogin {
    lt: String,
    param_id: String,
    req_id: String,
    uuid: String,
    encry_uuid: String,
}

#[derive(Debug, Clone)]
pub struct Cloud189Client {
    client: Client,
    session: Option<SessionTokens>,
    pending_qr: Option<PendingQrLogin>,
}

#[derive(Debug, Deserialize)]
struct QrUuidResponse {
    uuid: String,
    encryuuid: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QrStateResponse {
    status: i64,
    redirect_url: Option<String>,
    to_url: Option<String>,
    msg: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RefreshTokenResponse {
    #[serde(default, rename = "accessToken")]
    access_token: String,
    #[serde(default, rename = "refreshToken")]
    refresh_token: String,
}

#[derive(Debug, Deserialize)]
struct SessionResponse {
    #[serde(default, rename = "accessToken")]
    access_token: String,
    #[serde(default, rename = "refreshToken")]
    refresh_token: String,
    #[serde(default, rename = "loginName")]
    login_name: Option<String>,
    #[serde(default, rename = "sessionKey")]
    session_key: String,
    #[serde(default, rename = "sessionSecret")]
    session_secret: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct XmlSessionResponse {
    login_name: Option<String>,
    session_key: Option<String>,
    session_secret: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Common189Error {
    #[serde(default, rename = "res_code")]
    res_code: Option<Value>,
    #[serde(default, rename = "res_message")]
    res_message: Option<String>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    msg: Option<String>,
    #[serde(default, rename = "errorCode")]
    error_code: Option<String>,
    #[serde(default, rename = "errorMsg")]
    error_msg: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListFilesResponse {
    #[serde(rename = "fileListAO")]
    file_list_ao: FileListBlock,
}

#[derive(Debug, Deserialize)]
struct FileListBlock {
    count: usize,
    #[serde(default, rename = "fileList")]
    file_list: Vec<CloudFile>,
    #[serde(default, rename = "folderList")]
    folder_list: Vec<CloudFolder>,
}

#[derive(Debug, Deserialize)]
struct CloudFile {
    id: Value,
    name: String,
    #[serde(default)]
    size: u64,
    #[serde(default, rename = "lastOpTime")]
    last_op_time: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CloudFolder {
    id: Value,
    name: String,
    #[serde(default, rename = "parentId")]
    parent_id: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct DownloadUrlResponse {
    #[serde(rename = "fileDownloadUrl")]
    file_download_url: String,
}

#[derive(Debug, Clone)]
struct DownloadProbe {
    final_url: String,
    content_length: Option<u64>,
    range_supported: bool,
}

impl Cloud189Client {
    pub fn new() -> Result<Self> {
        let mut default_headers = HeaderMap::new();
        default_headers.insert(
            ACCEPT,
            HeaderValue::from_static("application/json;charset=UTF-8"),
        );
        default_headers.insert(REFERER, HeaderValue::from_static(CLOUD189_REFERER));

        let client = Client::builder()
            .cookie_store(true)
            .default_headers(default_headers)
            .no_proxy()
            .user_agent(CLOUDTUNE_USER_AGENT)
            // Some 189 endpoints close idle keep-alive sockets abruptly, which shows up
            // as `hyper::Error(IncompleteMessage)` on the next reused request.
            .pool_max_idle_per_host(0)
            .build()?;

        Ok(Self {
            client,
            session: None,
            pending_qr: None,
        })
    }

    pub fn is_authenticated(&self) -> bool {
        self.session.is_some()
    }

    pub fn account_name(&self) -> Option<String> {
        self.session
            .as_ref()
            .and_then(|session| session.login_name.clone())
    }

    pub fn refresh_token(&self) -> Option<String> {
        self.session
            .as_ref()
            .map(|session| session.refresh_token.clone())
            .filter(|token| !token.trim().is_empty())
    }

    pub fn clear_session(&mut self) {
        self.session = None;
        self.pending_qr = None;
    }

    pub async fn restore_from_refresh_token(&mut self, refresh_token: String) -> Result<()> {
        if refresh_token.trim().is_empty() {
            bail!("缺少可用的 refresh token");
        }

        self.session = Some(SessionTokens {
            refresh_token,
            ..SessionTokens::default()
        });
        self.refresh_token_exchange().await
    }

    pub async fn start_qr_login(&mut self) -> Result<QrLoginStart> {
        let (lt, param_id, req_id) = self.init_login_base().await?;
        let response = self
            .client
            .post(format!("{AUTH_URL}/api/logbox/oauth2/getUUID.do"))
            .form(&[("appId", APP_ID)])
            .send()
            .await?;
        let status = response.status();
        let body = response.text().await?;

        if let Some(message) = api_error_message(&body) {
            bail!(message);
        }

        let payload: QrUuidResponse = parse_json_response(&body, status.as_u16(), "二维码初始化")?;
        self.pending_qr = Some(PendingQrLogin {
            lt,
            param_id,
            req_id,
            uuid: payload.uuid.clone(),
            encry_uuid: payload.encryuuid,
        });

        Ok(QrLoginStart {
            qr_content: payload.uuid,
            message: "请使用天翼云盘 App 扫码，并在手机端确认登录".to_string(),
        })
    }

    pub async fn poll_qr_login(&mut self) -> Result<QrPollResponse> {
        let pending = self
            .pending_qr
            .clone()
            .context("请先生成二维码，再轮询登录状态")?;

        let response = self
            .client
            .post(format!("{AUTH_URL}/api/logbox/oauth2/qrcodeLoginState.do"))
            .header("Referer", AUTH_URL)
            .header("Reqid", pending.req_id)
            .header("lt", pending.lt)
            .form(&[
                ("appId", APP_ID.to_string()),
                ("clientType", CLIENT_TYPE.to_string()),
                ("returnUrl", RETURN_URL.to_string()),
                ("paramId", pending.param_id),
                ("uuid", pending.uuid),
                ("encryuuid", pending.encry_uuid),
                (
                    "date",
                    chrono::Local::now()
                        .format("%Y-%m-%d%H:%M:%S%.3f")
                        .to_string(),
                ),
                (
                    "timeStamp",
                    chrono::Utc::now().timestamp_millis().to_string(),
                ),
            ])
            .send()
            .await?;
        let status = response.status();
        let body = response.text().await?;
        let payload: QrStateResponse = parse_json_response(&body, status.as_u16(), "二维码轮询")?;

        match payload.status {
            0 => {
                let redirect_url = payload
                    .redirect_url
                    .or(payload.to_url)
                    .context("二维码登录成功，但没有返回 redirectURL")?;
                self.exchange_redirect_for_session(redirect_url).await?;
                self.pending_qr = None;
                Ok(QrPollResponse {
                    state: QrLoginState::Authenticated,
                    message: "扫码登录成功".to_string(),
                    account_name: self.account_name(),
                })
            }
            -106 => Ok(QrPollResponse {
                state: QrLoginState::WaitingScan,
                message: "二维码已生成，等待手机扫码".to_string(),
                account_name: None,
            }),
            -11002 => Ok(QrPollResponse {
                state: QrLoginState::WaitingConfirm,
                message: "手机已扫码，等待你在 App 里确认登录".to_string(),
                account_name: None,
            }),
            -11001 => {
                self.pending_qr = None;
                Ok(QrPollResponse {
                    state: QrLoginState::Expired,
                    message: "二维码已过期，请重新生成".to_string(),
                    account_name: None,
                })
            }
            other => bail!(
                "二维码登录失败，status={other}, msg={}",
                payload.msg.unwrap_or_else(|| "未知错误".to_string())
            ),
        }
    }

    pub async fn list_remote_folder(
        &mut self,
        folder_id: Option<String>,
    ) -> Result<FolderBrowsePayload> {
        let is_root = folder_id.is_none();
        let current_folder_id = folder_id.unwrap_or_else(|| ROOT_FOLDER_ID.to_string());
        let current_folder_name = if current_folder_id == ROOT_FOLDER_ID {
            ROOT_FOLDER_NAME.to_string()
        } else {
            "当前目录".to_string()
        };

        let mut folders = Vec::new();
        let mut audio_files = Vec::new();
        let mut video_files = Vec::new();
        let mut other_files = Vec::new();

        for page_num in 1.. {
            let payload: ListFilesResponse = self
                .signed_get_json(
                    &format!("{API_URL}/listFiles.action"),
                    &[
                        ("folderId", current_folder_id.clone()),
                        ("fileType", "0".to_string()),
                        ("mediaAttr", "0".to_string()),
                        ("iconOption", "5".to_string()),
                        ("pageNum", page_num.to_string()),
                        ("pageSize", "1000".to_string()),
                        ("recursive", "0".to_string()),
                        ("orderBy", "filename".to_string()),
                        ("descending", "false".to_string()),
                    ],
                )
                .await?;

            if payload.file_list_ao.count == 0 {
                break;
            }

            for folder in payload.file_list_ao.folder_list {
                if let Some(id) = value_to_string(&folder.id) {
                    folders.push(RemoteFolder {
                        id,
                        name: folder.name,
                        parent_id: folder.parent_id.as_ref().and_then(value_to_string),
                    });
                }
            }

            for file in payload.file_list_ao.file_list {
                if let Some(id) = value_to_string(&file.id) {
                    let summary = TrackSummary {
                        id,
                        name: file.name,
                        folder_path: current_folder_name.clone(),
                        size_bytes: file.size,
                        modified_at: file.last_op_time,
                    };
                    if is_audio_file(&summary.name) {
                        audio_files.push(summary);
                    } else if is_video_file(&summary.name) {
                        video_files.push(summary);
                    } else {
                        other_files.push(summary);
                    }
                }
            }
        }

        folders.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
        audio_files.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
        video_files.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
        other_files.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));

        Ok(FolderBrowsePayload {
            current_folder_id,
            current_folder_name,
            parent_folder_id: None,
            is_root,
            folders,
            audio_files,
            video_files,
            other_files,
        })
    }

    pub async fn scan_music_library(
        &mut self,
        folder_id: &str,
        folder_name: &str,
    ) -> Result<Vec<TrackSummary>> {
        let mut queue = VecDeque::from([(folder_id.to_string(), folder_name.to_string())]);
        let mut tracks = Vec::new();

        while let Some((current_folder_id, current_path)) = queue.pop_front() {
            let listing = self
                .list_remote_folder(Some(current_folder_id.clone()))
                .await?;
            for folder in listing.folders {
                queue.push_back((folder.id.clone(), format!("{current_path}/{}", folder.name)));
            }

            for mut track in listing.audio_files {
                track.folder_path = current_path.clone();
                tracks.push(track);
            }
        }

        tracks.sort_by(|left, right| {
            let left_key = format!(
                "{}{}",
                left.folder_path.to_lowercase(),
                left.name.to_lowercase()
            );
            let right_key = format!(
                "{}{}",
                right.folder_path.to_lowercase(),
                right.name.to_lowercase()
            );
            left_key.cmp(&right_key)
        });

        Ok(tracks)
    }

    pub async fn scan_all_files(
        &mut self,
        folder_id: &str,
        folder_name: &str,
    ) -> Result<Vec<TrackSummary>> {
        let mut queue = VecDeque::from([(folder_id.to_string(), folder_name.to_string())]);
        let mut files = Vec::new();

        while let Some((current_folder_id, current_path)) = queue.pop_front() {
            let listing = self
                .list_remote_folder(Some(current_folder_id.clone()))
                .await?;
            for folder in listing.folders {
                queue.push_back((folder.id.clone(), format!("{current_path}/{}", folder.name)));
            }

            for mut item in listing.audio_files {
                item.folder_path = current_path.clone();
                files.push(item);
            }
            for mut item in listing.video_files {
                item.folder_path = current_path.clone();
                files.push(item);
            }
            for mut item in listing.other_files {
                item.folder_path = current_path.clone();
                files.push(item);
            }
        }

        files.sort_by(|left, right| {
            let left_key = format!(
                "{}{}",
                left.folder_path.to_lowercase(),
                left.name.to_lowercase()
            );
            let right_key = format!(
                "{}{}",
                right.folder_path.to_lowercase(),
                right.name.to_lowercase()
            );
            left_key.cmp(&right_key)
        });

        Ok(files)
    }

    pub async fn playback_url(&mut self, file_id: &str) -> Result<String> {
        self.resolve_download_url(file_id).await
    }

    pub async fn cache_direct_url_to(
        &self,
        direct_url: &str,
        destination: &Path,
        expected_size: Option<u64>,
        parallelism: Option<usize>,
    ) -> Result<u64> {
        let probe = self.probe_download(direct_url, expected_size).await?;

        if probe.range_supported
            && probe.content_length.unwrap_or_default() >= MIN_PARALLEL_DOWNLOAD_SIZE
            && self
                .parallel_download_to(
                    &probe.final_url,
                    probe.content_length.unwrap_or_default(),
                    destination,
                    parallelism,
                )
                .await
                .is_ok()
        {
            return Ok(fs::metadata(destination).await?.len());
        }

        self.stream_download_to(&probe.final_url, destination).await
    }

    async fn init_login_base(&self) -> Result<(String, String, String)> {
        let response = self
            .client
            .get(format!("{WEB_URL}/api/portal/unifyLoginForPC.action"))
            .query(&[
                ("appId", APP_ID),
                ("clientType", CLIENT_TYPE),
                ("returnURL", RETURN_URL),
                (
                    "timeStamp",
                    &chrono::Utc::now().timestamp_millis().to_string(),
                ),
            ])
            .send()
            .await?;
        let status = response.status();
        let html = response.text().await?;
        if !status.is_success() {
            bail!(
                "获取扫码登录页失败，HTTP {}: {}",
                status.as_u16(),
                summarize_body(&html)
            );
        }

        let lt = extract_with_regex(&html, r#"lt = "(.+?)""#, "lt")?;
        let param_id = extract_with_regex(&html, r#"paramId = "(.+?)""#, "paramId")?;
        let req_id = extract_with_regex(&html, r#"reqId = "(.+?)""#, "reqId")?;
        Ok((lt, param_id, req_id))
    }

    async fn refresh_token_exchange(&mut self) -> Result<()> {
        let refresh_token = self
            .session
            .as_ref()
            .map(|session| session.refresh_token.clone())
            .context("缺少 refresh token")?;

        let response = self
            .client
            .post(format!("{AUTH_URL}/api/oauth2/refreshToken.do"))
            .form(&[
                ("clientId", APP_ID.to_string()),
                ("refreshToken", refresh_token.clone()),
                ("grantType", "refresh_token".to_string()),
                ("format", "json".to_string()),
            ])
            .send()
            .await?;
        let status = response.status();
        let body = response.text().await?;

        if let Some(message) = api_error_message(&body) {
            bail!(message);
        }

        let payload: RefreshTokenResponse =
            parse_json_response(&body, status.as_u16(), "refresh token")?;
        if payload.access_token.trim().is_empty() {
            bail!("刷新登录态失败，未拿到 access token");
        }

        self.session = Some(SessionTokens {
            access_token: payload.access_token,
            refresh_token: if payload.refresh_token.trim().is_empty() {
                refresh_token
            } else {
                payload.refresh_token
            },
            ..SessionTokens::default()
        });

        self.refresh_session_with_access_token().await
    }

    async fn refresh_session_with_access_token(&mut self) -> Result<()> {
        let access_token = self
            .session
            .as_ref()
            .map(|session| session.access_token.clone())
            .context("缺少 access token")?;

        let response = self
            .client
            .get(format!("{API_URL}/getSessionForPC.action"))
            .query(&client_suffix())
            .query(&[("appId", APP_ID.to_string()), ("accessToken", access_token)])
            .header("X-Request-ID", Uuid::new_v4().to_string())
            .send()
            .await?;
        let status = response.status();
        let body = response.text().await?;

        if let Some(message) = api_error_message(&body) {
            bail!(message);
        }

        let payload = parse_session_response(&body, status.as_u16(), "session refresh")?;
        self.apply_session_response(payload)
    }

    async fn exchange_redirect_for_session(&mut self, redirect_url: String) -> Result<()> {
        let response = self
            .client
            .post(format!("{API_URL}/getSessionForPC.action"))
            .query(&client_suffix())
            .query(&[("redirectURL", redirect_url)])
            .send()
            .await?;
        let status = response.status();
        let body = response.text().await?;

        if let Some(message) = api_error_message(&body) {
            bail!(message);
        }

        let payload = parse_session_response(&body, status.as_u16(), "扫码换取 session")?;
        self.apply_session_response(payload)
    }

    fn apply_session_response(&mut self, payload: SessionResponse) -> Result<()> {
        let existing = self.session.clone().unwrap_or_default();
        let next_access_token = if payload.access_token.trim().is_empty() {
            existing.access_token
        } else {
            payload.access_token
        };
        let next_refresh_token = if payload.refresh_token.trim().is_empty() {
            existing.refresh_token
        } else {
            payload.refresh_token
        };

        if payload.session_key.trim().is_empty() || payload.session_secret.trim().is_empty() {
            bail!("189CloudPC 会话初始化失败，session key 为空");
        }

        self.session = Some(SessionTokens {
            access_token: next_access_token,
            refresh_token: next_refresh_token,
            session_key: payload.session_key,
            session_secret: payload.session_secret,
            login_name: payload.login_name.or(existing.login_name),
        });
        Ok(())
    }

    async fn resolve_download_url(&mut self, file_id: &str) -> Result<String> {
        let payload: DownloadUrlResponse = self
            .signed_get_json(
                &format!("{API_URL}/getFileDownloadUrl.action"),
                &[
                    ("fileId", file_id.to_string()),
                    ("dt", "3".to_string()),
                    ("flag", "1".to_string()),
                ],
            )
            .await?;

        if payload.file_download_url.trim().is_empty() {
            bail!("没有获取到文件下载地址");
        }

        Ok(payload
            .file_download_url
            .replace("&amp;", "&")
            .replacen("http://", "https://", 1))
    }

    async fn probe_download(&self, url: &str, expected_size: Option<u64>) -> Result<DownloadProbe> {
        let head_result = self
            .client
            .head(url)
            .header(ACCEPT, "*/*")
            .header("User-Agent", CLOUDTUNE_USER_AGENT)
            .send()
            .await;

        if let Ok(response) = head_result {
            let final_url = response.url().to_string();
            let headers = response.headers();
            let content_length = header_to_u64(headers.get(CONTENT_LENGTH)).or(expected_size);
            let range_supported = headers
                .get(ACCEPT_RANGES)
                .and_then(|value| value.to_str().ok())
                .map(|value| value.contains("bytes"))
                .unwrap_or(false);

            if response.status().is_success() && (range_supported || content_length.is_some()) {
                return Ok(DownloadProbe {
                    final_url,
                    content_length,
                    range_supported,
                });
            }
        }

        let response = self
            .client
            .get(url)
            .header(ACCEPT, "*/*")
            .header("User-Agent", CLOUDTUNE_USER_AGENT)
            .header(RANGE, "bytes=0-0")
            .send()
            .await?;
        let final_url = response.url().to_string();
        let status = response.status();
        let headers = response.headers();
        let content_length = if status == StatusCode::PARTIAL_CONTENT {
            total_size_from_content_range(headers.get(CONTENT_RANGE)).or(expected_size)
        } else {
            header_to_u64(headers.get(CONTENT_LENGTH)).or(expected_size)
        };

        Ok(DownloadProbe {
            final_url,
            content_length,
            range_supported: status == StatusCode::PARTIAL_CONTENT,
        })
    }

    async fn stream_download_to(&self, url: &str, destination: &Path) -> Result<u64> {
        let mut response = self
            .client
            .get(url)
            .header(ACCEPT, "*/*")
            .header("User-Agent", CLOUDTUNE_USER_AGENT)
            .send()
            .await?
            .error_for_status()?;

        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).await?;
        }

        let temp_path = destination.with_extension("part");
        let _ = fs::remove_file(&temp_path).await;
        let _ = fs::remove_file(destination).await;

        let file = fs::File::create(&temp_path).await?;
        let mut writer = BufWriter::new(file);

        while let Some(chunk) = response.chunk().await? {
            writer.write_all(&chunk).await?;
        }

        writer.flush().await?;
        drop(writer);

        fs::rename(&temp_path, destination).await?;
        Ok(fs::metadata(destination).await?.len())
    }

    async fn parallel_download_to(
        &self,
        url: &str,
        content_length: u64,
        destination: &Path,
        parallelism: Option<usize>,
    ) -> Result<()> {
        if content_length == 0 {
            bail!("content length is empty");
        }

        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).await?;
        }

        let temp_path = destination.with_extension("part");
        let parts_dir = destination.with_extension("parts");
        let _ = fs::remove_file(&temp_path).await;
        let _ = fs::remove_file(destination).await;
        let _ = fs::remove_dir_all(&parts_dir).await;
        fs::create_dir_all(&parts_dir).await?;

        let ranges = split_ranges(
            content_length,
            parallelism.unwrap_or_else(|| suggested_parallelism(content_length)),
        );
        let mut tasks = Vec::with_capacity(ranges.len());

        for (index, (start, end)) in ranges.into_iter().enumerate() {
            let client = self.client.clone();
            let url = url.to_string();
            let part_path = parts_dir.join(format!("{index:02}.part"));

            tasks.push(tokio::spawn(async move {
                download_range_part(client, url, start, end, part_path.clone()).await?;
                Ok::<PathBuf, anyhow::Error>(part_path)
            }));
        }

        let mut part_paths = Vec::new();
        for task in tasks {
            match task.await {
                Ok(Ok(path)) => part_paths.push(path),
                Ok(Err(error)) => {
                    let _ = fs::remove_dir_all(&parts_dir).await;
                    return Err(error);
                }
                Err(error) => {
                    let _ = fs::remove_dir_all(&parts_dir).await;
                    bail!("parallel task join failed: {error}");
                }
            }
        }

        part_paths.sort();

        let merged = fs::File::create(&temp_path).await?;
        let mut writer = BufWriter::new(merged);
        for part_path in &part_paths {
            let bytes = fs::read(part_path).await?;
            writer.write_all(&bytes).await?;
        }
        writer.flush().await?;
        drop(writer);

        fs::rename(&temp_path, destination).await?;
        let _ = fs::remove_dir_all(&parts_dir).await;
        Ok(())
    }

    async fn signed_get_json<T>(&mut self, url: &str, extra_query: &[(&str, String)]) -> Result<T>
    where
        T: for<'de> Deserialize<'de>,
    {
        for attempt in 0..2 {
            let session = self.session.clone().context("请先扫码登录天翼云盘")?;
            let mut request = self.client.get(url).query(&client_suffix());
            for (key, value) in extra_query {
                request = request.query(&[(key.to_string(), value.to_string())]);
            }
            request = request.headers(signed_headers(&session, url, "GET")?);

            let response = request.send().await?;
            let status = response.status();
            let body = response.text().await?;

            if body.contains("userSessionBO is null") || body.contains("InvalidSessionKey") {
                if attempt == 0 {
                    self.refresh_session_with_access_token().await?;
                    continue;
                }
                bail!("天翼云盘会话已失效，请重新扫码登录");
            }

            if let Some(message) = api_error_message(&body) {
                bail!(message);
            }

            return parse_json_response(&body, status.as_u16(), url);
        }

        bail!("读取天翼云盘接口失败")
    }
}

fn signed_headers(session: &SessionTokens, url: &str, method: &str) -> Result<HeaderMap> {
    let date = fmt_http_date(SystemTime::now());
    let request_uri = Url::parse(url)?.path().to_string();
    let signature_payload = format!(
        "SessionKey={}&Operate={}&RequestURI={}&Date={}",
        session.session_key, method, request_uri, date
    );

    let mut mac = HmacSha1::new_from_slice(session.session_secret.as_bytes())?;
    mac.update(signature_payload.as_bytes());
    let signature = hex::encode(mac.finalize().into_bytes()).to_uppercase();

    let mut headers = HeaderMap::new();
    headers.insert("Date", date.parse()?);
    headers.insert("SessionKey", session.session_key.parse()?);
    headers.insert("X-Request-ID", Uuid::new_v4().to_string().parse()?);
    headers.insert("Signature", signature.parse()?);
    Ok(headers)
}

fn client_suffix() -> Vec<(&'static str, String)> {
    let mut random = rand::thread_rng();
    vec![
        ("clientType", PC_CLIENT.to_string()),
        ("version", VERSION.to_string()),
        ("channelId", CHANNEL_ID.to_string()),
        (
            "rand",
            format!(
                "{}_{}",
                random.gen_range(0_i64..100_000_i64),
                random.gen_range(0_i64..10_000_000_000_i64)
            ),
        ),
    ]
}

fn extract_with_regex(html: &str, pattern: &str, label: &str) -> Result<String> {
    let regex = Regex::new(pattern)?;
    let captures = regex
        .captures(html)
        .context(format!("登录页面中缺少 {label}"))?;
    let value = captures
        .get(1)
        .context(format!("无法解析 {label}"))?
        .as_str()
        .to_string();
    Ok(value)
}

fn api_error_message(body: &str) -> Option<String> {
    let error = serde_json::from_str::<Common189Error>(body).ok()?;

    if let Some(res_code) = error.res_code {
        match res_code {
            Value::Number(number) if number.as_i64().unwrap_or_default() != 0 => {
                return Some(
                    error
                        .res_message
                        .or(error.msg)
                        .or(error.message)
                        .unwrap_or_else(|| format!("189Cloud error {number}")),
                );
            }
            Value::String(text) if !text.is_empty() && text != "0" => {
                return Some(
                    error
                        .res_message
                        .or(error.msg)
                        .or(error.message)
                        .unwrap_or_else(|| format!("189Cloud error {text}")),
                );
            }
            _ => {}
        }
    }

    if let Some(error_code) = error.error_code {
        if !error_code.is_empty() {
            return Some(
                error
                    .error_msg
                    .or(error.msg)
                    .or(error.message)
                    .unwrap_or(error_code),
            );
        }
    }

    if let Some(code) = error.code {
        if !code.is_empty() && code != "SUCCESS" {
            return Some(error.msg.or(error.message).unwrap_or(code));
        }
    }

    if let Some(message) = error.error {
        if !message.is_empty() {
            return Some(error.message.or(error.msg).unwrap_or(message));
        }
    }

    None
}

fn parse_json_response<T>(body: &str, status_code: u16, label: &str) -> Result<T>
where
    T: for<'de> Deserialize<'de>,
{
    let normalized = body.trim().trim_start_matches('\u{feff}');
    if normalized.is_empty() {
        bail!("{label} 返回空响应，HTTP {status_code}");
    }

    serde_json::from_str(normalized).map_err(|error| {
        anyhow::anyhow!(
            "{label} 返回的不是可解析 JSON，HTTP {}，原始内容片段: {}，解析错误: {}",
            status_code,
            summarize_body(normalized),
            error
        )
    })
}

fn parse_session_response(body: &str, status_code: u16, label: &str) -> Result<SessionResponse> {
    let normalized = body.trim().trim_start_matches('\u{feff}');

    if normalized.starts_with('<') {
        let parsed: XmlSessionResponse = parse_xml(normalized).map_err(|error| {
            anyhow::anyhow!(
                "{label} 返回 XML 但解析失败，HTTP {}，原始内容片段: {}，解析错误: {}",
                status_code,
                summarize_body(normalized),
                error
            )
        })?;

        return Ok(SessionResponse {
            access_token: String::new(),
            refresh_token: String::new(),
            login_name: parsed.login_name,
            session_key: parsed.session_key.unwrap_or_default(),
            session_secret: parsed.session_secret.unwrap_or_default(),
        });
    }

    parse_json_response(normalized, status_code, label)
}

fn summarize_body(body: &str) -> String {
    body.chars()
        .filter(|character| !character.is_control() || *character == '\n' || *character == '\t')
        .collect::<String>()
        .replace('\n', " ")
        .replace('\t', " ")
        .chars()
        .take(180)
        .collect()
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

fn suggested_parallelism(content_length: u64) -> usize {
    let estimated =
        (content_length / MIN_PARALLEL_DOWNLOAD_SIZE).clamp(4, MAX_PARALLEL_DOWNLOADS as u64);
    estimated as usize
}

fn split_ranges(content_length: u64, parts: usize) -> Vec<(u64, u64)> {
    let part_size = content_length.div_ceil(parts as u64);
    let mut ranges = Vec::with_capacity(parts);
    let mut start = 0_u64;

    while start < content_length {
        let end = (start + part_size - 1).min(content_length - 1);
        ranges.push((start, end));
        start = end + 1;
    }

    ranges
}

fn next_parallel_range_retry_delay_ms(attempt: u8) -> u64 {
    (PARALLEL_RANGE_RETRY_DELAY_MS * u64::from(attempt)).min(PARALLEL_RANGE_RETRY_MAX_DELAY_MS)
}

async fn download_range_part(
    client: Client,
    url: String,
    start: u64,
    end: u64,
    destination: PathBuf,
) -> Result<()> {
    let expected_len = end - start + 1;
    let mut written = 0_u64;
    let mut retry_streak = 0_u8;
    let mut last_error = String::from("range download interrupted");

    while written < expected_len {
        let range_start = start + written;
        let response = client
            .get(&url)
            .header(ACCEPT, "*/*")
            .header("User-Agent", CLOUDTUNE_USER_AGENT)
            .header(RANGE, format!("bytes={range_start}-{end}"))
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
                        target: "cloudtune::cloud189",
                        "parallel range {}-{} attempt {}/{} returned {}",
                        start,
                        end,
                        retry_streak,
                        MAX_PARALLEL_RANGE_RETRY_ATTEMPTS,
                        status
                    );

                    if retry_streak >= MAX_PARALLEL_RANGE_RETRY_ATTEMPTS {
                        bail!(last_error);
                    }

                    tokio::time::sleep(tokio::time::Duration::from_millis(
                        next_parallel_range_retry_delay_ms(retry_streak),
                    ))
                    .await;
                    continue;
                }
            }
            Err(error) => {
                last_error = error.to_string();
                retry_streak = retry_streak.saturating_add(1);
                warn!(
                    target: "cloudtune::cloud189",
                    "parallel range {}-{} attempt {}/{} failed: {}",
                    start,
                    end,
                    retry_streak,
                    MAX_PARALLEL_RANGE_RETRY_ATTEMPTS,
                    error
                );

                if retry_streak >= MAX_PARALLEL_RANGE_RETRY_ATTEMPTS {
                    return Err(error.into());
                }

                tokio::time::sleep(tokio::time::Duration::from_millis(
                    next_parallel_range_retry_delay_ms(retry_streak),
                ))
                .await;
                continue;
            }
        };

        let file = if written > 0 {
            tokio::fs::OpenOptions::new()
                .append(true)
                .open(&destination)
                .await?
        } else {
            fs::File::create(&destination).await?
        };
        let mut writer = BufWriter::new(file);
        let mut progressed = false;

        loop {
            match response.chunk().await {
                Ok(Some(chunk)) => {
                    writer.write_all(&chunk).await?;
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
                        target: "cloudtune::cloud189",
                        "parallel range {}-{} interrupted after {} bytes: {}",
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
                    target: "cloudtune::cloud189",
                    "parallel range {}-{} recovered after retries",
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

        if retry_streak >= MAX_PARALLEL_RANGE_RETRY_ATTEMPTS {
            bail!(
                "range {}-{} failed after {} retries: {}",
                start,
                end,
                MAX_PARALLEL_RANGE_RETRY_ATTEMPTS,
                last_error
            );
        }

        warn!(
            target: "cloudtune::cloud189",
            "parallel range {}-{} retrying from byte {} ({}/{})",
            start,
            end,
            start + written,
            retry_streak,
            MAX_PARALLEL_RANGE_RETRY_ATTEMPTS
        );
        tokio::time::sleep(tokio::time::Duration::from_millis(
            next_parallel_range_retry_delay_ms(retry_streak),
        ))
        .await;
    }

    Ok(())
}

fn value_to_string(value: &Value) -> Option<String> {
    match value {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

fn is_audio_file(name: &str) -> bool {
    let lowered = name.to_lowercase();
    [
        ".mp3", ".flac", ".wav", ".m4a", ".aac", ".ogg", ".opus", ".ape", ".wma", ".alac",
    ]
    .iter()
    .any(|extension| lowered.ends_with(extension))
}

fn is_video_file(name: &str) -> bool {
    let lowered = name.to_lowercase();
    [
        ".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".wmv", ".flv", ".mpeg", ".mpg",
    ]
    .iter()
    .any(|extension| lowered.ends_with(extension))
}

pub fn build_media_client() -> Result<Client> {
    let mut default_headers = HeaderMap::new();
    default_headers.insert(ACCEPT, HeaderValue::from_static("*/*"));
    default_headers.insert(REFERER, HeaderValue::from_static(CLOUD189_REFERER));

    Ok(Client::builder()
        .cookie_store(true)
        .default_headers(default_headers)
        .no_proxy()
        .user_agent(CLOUDTUNE_USER_AGENT)
        // Use fresh connections for media fetches to avoid reusing half-closed idle sockets.
        .pool_max_idle_per_host(0)
        .build()?)
}

#[cfg(test)]
mod tests {
    use super::{QrStateResponse, parse_json_response, parse_session_response};

    #[test]
    fn qr_state_accepts_to_url_payload() {
        let parsed: QrStateResponse =
            parse_json_response(r#"{"status":0,"toUrl":"https://example.com"}"#, 200, "qr")
                .expect("payload should parse");

        assert_eq!(parsed.status, 0);
        assert_eq!(parsed.to_url.as_deref(), Some("https://example.com"));
    }

    #[test]
    fn blank_body_returns_diagnostic_error() {
        let error = parse_json_response::<QrStateResponse>("   ", 200, "qr")
            .expect_err("blank payload should fail");
        assert!(error.to_string().contains("空响应"));
    }

    #[test]
    fn session_xml_parses_successfully() {
        let parsed = parse_session_response(
            r#"<?xml version="1.0" encoding="UTF-8"?><userSession><loginName>13351215997@189.cn</loginName><sessionKey>abc</sessionKey><sessionSecret>def</sessionSecret></userSession>"#,
            200,
            "session",
        )
        .expect("xml session should parse");

        assert_eq!(parsed.login_name.as_deref(), Some("13351215997@189.cn"));
        assert_eq!(parsed.session_key, "abc");
        assert_eq!(parsed.session_secret, "def");
    }
}
