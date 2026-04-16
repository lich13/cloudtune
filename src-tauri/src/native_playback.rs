use std::{path::PathBuf, time::Duration};

use anyhow::Result;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePlaybackSnapshot {
    pub supported: bool,
    pub state: String,
    pub track_id: Option<String>,
    pub local_path: Option<String>,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub error: Option<String>,
}

impl NativePlaybackSnapshot {
    #[cfg(not(target_os = "windows"))]
    fn unsupported() -> Self {
        Self {
            supported: false,
            state: "idle".to_string(),
            track_id: None,
            local_path: None,
            position_seconds: 0.0,
            duration_seconds: None,
            error: None,
        }
    }
}

#[cfg(target_os = "windows")]
mod imp {
    use super::{Duration, NativePlaybackSnapshot, PathBuf, Result};
    use anyhow::Context;
    use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};
    use std::{
        fs::File,
        io::BufReader,
        sync::{Arc, Mutex},
    };

    #[derive(Default)]
    struct PlaybackState {
        handle: Option<MixerDeviceSink>,
        player: Option<Player>,
        track_id: Option<String>,
        local_path: Option<String>,
        duration: Option<Duration>,
        last_error: Option<String>,
        manual_stop: bool,
    }

    #[derive(Clone, Default)]
    pub struct NativePlaybackController {
        inner: Arc<Mutex<PlaybackState>>,
    }

    impl NativePlaybackController {
        pub fn new() -> Self {
            Self::default()
        }

        pub fn snapshot(&self) -> NativePlaybackSnapshot {
            let inner = self.inner.lock().unwrap();
            snapshot_from_state(&inner)
        }

        pub fn play_track(
            &self,
            track_id: String,
            local_path: PathBuf,
            position: Duration,
        ) -> Result<NativePlaybackSnapshot> {
            let mut inner = self.inner.lock().unwrap();
            inner.last_error = None;
            inner.manual_stop = false;
            ensure_output_handle(&mut inner)?;

            if let Some(player) = inner.player.take() {
                player.stop();
            }

            let file = File::open(&local_path)
                .with_context(|| format!("failed to open audio file {}", local_path.display()))?;
            let decoder = Decoder::try_from(BufReader::new(file))
                .with_context(|| format!("failed to decode audio file {}", local_path.display()))?;
            let duration = decoder.total_duration();
            let player = Player::connect_new(inner.handle.as_ref().unwrap().mixer());
            player.append(decoder);
            if position > Duration::ZERO {
                player.try_seek(position).with_context(|| {
                    format!("failed to seek audio file {}", local_path.display())
                })?;
            }
            player.play();

            inner.duration = duration;
            inner.track_id = Some(track_id);
            inner.local_path = Some(local_path.to_string_lossy().into_owned());
            inner.player = Some(player);

            Ok(snapshot_from_state(&inner))
        }

        pub fn pause(&self) -> Result<NativePlaybackSnapshot> {
            let mut inner = self.inner.lock().unwrap();
            if let Some(player) = &inner.player {
                player.pause();
            }
            inner.last_error = None;
            Ok(snapshot_from_state(&inner))
        }

        pub fn resume(&self) -> Result<NativePlaybackSnapshot> {
            let mut inner = self.inner.lock().unwrap();
            if let Some(player) = &inner.player {
                player.play();
                inner.manual_stop = false;
            }
            inner.last_error = None;
            Ok(snapshot_from_state(&inner))
        }

        pub fn seek(&self, position: Duration) -> Result<NativePlaybackSnapshot> {
            let mut inner = self.inner.lock().unwrap();
            let player = inner
                .player
                .as_ref()
                .context("no active native playback session")?;
            let clamped = clamp_position(position, inner.duration);
            player.try_seek(clamped)?;
            inner.last_error = None;
            Ok(snapshot_from_state(&inner))
        }

        pub fn stop(&self) -> Result<NativePlaybackSnapshot> {
            let mut inner = self.inner.lock().unwrap();
            if let Some(player) = inner.player.take() {
                player.stop();
            }
            inner.track_id = None;
            inner.local_path = None;
            inner.duration = None;
            inner.last_error = None;
            inner.manual_stop = true;
            Ok(snapshot_from_state(&inner))
        }
    }

    fn ensure_output_handle(inner: &mut PlaybackState) -> Result<()> {
        if inner.handle.is_none() {
            inner.handle = Some(DeviceSinkBuilder::open_default_sink()?);
        }

        Ok(())
    }

    fn clamp_position(position: Duration, duration: Option<Duration>) -> Duration {
        match duration {
            Some(duration) if position > duration => duration,
            _ => position,
        }
    }

    fn snapshot_from_state(inner: &PlaybackState) -> NativePlaybackSnapshot {
        let Some(track_id) = inner.track_id.clone() else {
            return NativePlaybackSnapshot {
                supported: true,
                state: "idle".to_string(),
                track_id: None,
                local_path: None,
                position_seconds: 0.0,
                duration_seconds: None,
                error: inner.last_error.clone(),
            };
        };

        let (state, position_seconds) = if let Some(player) = &inner.player {
            let position_seconds = player.get_pos().as_secs_f64();
            let state = if inner.last_error.is_some() {
                "error"
            } else if player.is_paused() {
                "paused"
            } else if player.empty() {
                if inner.manual_stop { "idle" } else { "ended" }
            } else {
                "playing"
            };
            (state.to_string(), position_seconds)
        } else if inner.last_error.is_some() {
            ("error".to_string(), 0.0)
        } else if inner.manual_stop {
            ("idle".to_string(), 0.0)
        } else {
            (
                "ended".to_string(),
                inner
                    .duration
                    .map(|value| value.as_secs_f64())
                    .unwrap_or(0.0),
            )
        };

        NativePlaybackSnapshot {
            supported: true,
            state,
            track_id: Some(track_id),
            local_path: inner.local_path.clone(),
            position_seconds,
            duration_seconds: inner.duration.map(|value| value.as_secs_f64()),
            error: inner.last_error.clone(),
        }
    }
}

#[cfg(not(target_os = "windows"))]
mod imp {
    use super::{Duration, NativePlaybackSnapshot, PathBuf, Result};

    #[derive(Clone, Default)]
    pub struct NativePlaybackController;

    impl NativePlaybackController {
        pub fn new() -> Self {
            Self
        }

        pub fn snapshot(&self) -> NativePlaybackSnapshot {
            NativePlaybackSnapshot::unsupported()
        }

        pub fn play_track(
            &self,
            _track_id: String,
            _local_path: PathBuf,
            _position: Duration,
        ) -> Result<NativePlaybackSnapshot> {
            anyhow::bail!("native playback is only supported on Windows")
        }

        pub fn pause(&self) -> Result<NativePlaybackSnapshot> {
            anyhow::bail!("native playback is only supported on Windows")
        }

        pub fn resume(&self) -> Result<NativePlaybackSnapshot> {
            anyhow::bail!("native playback is only supported on Windows")
        }

        pub fn seek(&self, _position: Duration) -> Result<NativePlaybackSnapshot> {
            anyhow::bail!("native playback is only supported on Windows")
        }

        pub fn stop(&self) -> Result<NativePlaybackSnapshot> {
            Ok(NativePlaybackSnapshot::unsupported())
        }
    }
}

pub use imp::NativePlaybackController;
