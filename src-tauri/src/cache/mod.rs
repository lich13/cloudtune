use anyhow::Result;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CacheIndex {
    pub entries: HashMap<String, CacheEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheEntry {
    pub relative_path: String,
    pub size_bytes: u64,
    pub last_accessed_ms: i64,
}

impl CacheIndex {
    pub fn load(index_path: &Path) -> Self {
        if !index_path.exists() {
            return Self::default();
        }

        fs::read_to_string(index_path)
            .ok()
            .and_then(|content| serde_json::from_str::<Self>(&content).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, index_path: &Path) -> Result<()> {
        if let Some(parent) = index_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(index_path, serde_json::to_vec_pretty(self)?)?;
        Ok(())
    }

    pub fn existing_path(&mut self, track_id: &str, cache_dir: &Path) -> Option<PathBuf> {
        let entry = self.entries.get_mut(track_id)?;
        let absolute_path = cache_dir.join(&entry.relative_path);
        if absolute_path.exists() {
            entry.last_accessed_ms = now_ms();
            return Some(absolute_path);
        }

        self.entries.remove(track_id);
        None
    }

    pub fn record(&mut self, track_id: String, relative_path: String, size_bytes: u64) {
        self.entries.insert(
            track_id,
            CacheEntry {
                relative_path,
                size_bytes,
                last_accessed_ms: now_ms(),
            },
        );
    }

    pub fn estimated_usage_bytes(&self) -> u64 {
        self.entries
            .values()
            .map(|entry| entry.size_bytes)
            .fold(0_u64, u64::saturating_add)
    }

    pub fn usage_bytes(&mut self, cache_dir: &Path) -> u64 {
        let mut missing = Vec::new();
        let mut total = 0_u64;

        for (track_id, entry) in &self.entries {
            let absolute_path = cache_dir.join(&entry.relative_path);
            if absolute_path.exists() {
                total = total.saturating_add(entry.size_bytes);
            } else {
                missing.push(track_id.clone());
            }
        }

        for track_id in missing {
            self.entries.remove(&track_id);
        }

        total
    }

    pub fn prune_to_limit(
        &mut self,
        cache_dir: &Path,
        limit_bytes: u64,
        preserve_track_id: Option<&str>,
    ) -> Result<u64> {
        let mut usage = self.usage_bytes(cache_dir);
        if usage <= limit_bytes {
            return Ok(usage);
        }

        let mut eviction_order = self
            .entries
            .iter()
            .map(|(track_id, entry)| (track_id.clone(), entry.last_accessed_ms))
            .collect::<Vec<_>>();
        eviction_order.sort_by_key(|(_, last_accessed_ms)| *last_accessed_ms);

        for (track_id, _) in eviction_order {
            if usage <= limit_bytes {
                break;
            }

            if preserve_track_id == Some(track_id.as_str()) {
                continue;
            }

            if let Some(entry) = self.entries.remove(&track_id) {
                let absolute_path = cache_dir.join(entry.relative_path);
                if absolute_path.exists() {
                    let _ = fs::remove_file(&absolute_path);
                }
                usage = usage.saturating_sub(entry.size_bytes);
            }
        }

        Ok(usage)
    }
}

fn now_ms() -> i64 {
    Utc::now().timestamp_millis()
}
