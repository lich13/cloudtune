import { invoke } from '@tauri-apps/api/core'
import type {
  BootstrapPayload,
  FolderBrowsePayload,
  NowPlayingMetadata,
  PreparedTrack,
  QrLoginStart,
  QrPollResponse,
  SettingsPayload,
  TrackSummary,
  TransferSnapshotPayload,
} from './types'

export const api = {
  bootstrap: () => invoke<BootstrapPayload>('bootstrap'),
  startQrLogin: () => invoke<QrLoginStart>('start_qr_login'),
  pollQrLogin: () => invoke<QrPollResponse>('poll_qr_login'),
  listRemoteFolder: (folderId?: string | null) =>
    invoke<FolderBrowsePayload>('list_remote_folder', { folderId }),
  saveMusicFolder: (folderId: string, folderName: string) =>
    invoke<SettingsPayload>('save_music_folder', { folderId, folderName }),
  scanLibrary: () => invoke<TrackSummary[]>('scan_library'),
  prepareTrack: (
    trackId: string,
    fileName: string,
    sizeBytes: number,
    playbackModeOverride?: 'download_first' | 'stream_cache',
  ) =>
    invoke<PreparedTrack>('prepare_track', {
      trackId,
      fileName,
      sizeBytes,
      forPlayback: true,
      ...(playbackModeOverride ? { playbackModeOverride } : {}),
    }),
  prefetchTrack: (trackId: string, fileName: string, sizeBytes: number) =>
    invoke<PreparedTrack>('prepare_track', {
      trackId,
      fileName,
      sizeBytes,
      forPlayback: false,
    }),
  updateCacheLimit: (limitMb: number) =>
    invoke<SettingsPayload>('update_cache_limit', { limitMb }),
  updateTransferTuning: (downloadThreads: number, cacheThreads: number) =>
    invoke<SettingsPayload>('update_transfer_tuning', {
      downloadThreads,
      cacheThreads,
    }),
  updatePlaybackMode: (playbackMode: string) =>
    invoke<SettingsPayload>('update_playback_mode', { playbackMode }),
  getTransferSnapshot: () =>
    invoke<TransferSnapshotPayload>('get_transfer_snapshot'),
  pickDownloadDirectory: () => invoke<string | null>('pick_download_directory'),
  downloadTrackToDirectory: (
    trackId: string,
    fileName: string,
    sizeBytes: number,
    directory: string,
  ) =>
    invoke<string>('download_track_to_directory', {
      trackId,
      fileName,
      sizeBytes,
      directory,
    }),
  downloadFolderToDirectory: (
    folderId: string,
    folderName: string,
    directory: string,
  ) =>
    invoke<string>('download_folder_to_directory', {
      folderId,
      folderName,
      directory,
    }),
  openVideoInSystem: (trackId: string) =>
    invoke<void>('open_video_in_system', { trackId }),
  readTrackMetadata: (localPath: string, fallbackName: string, fallbackAlbum: string) =>
    invoke<NowPlayingMetadata>('read_track_metadata', {
      localPath,
      fallbackName,
      fallbackAlbum,
    }),
  pauseTransfer: (id: string) => invoke<void>('pause_transfer', { id }),
  resumeTransfer: (id: string) => invoke<void>('resume_transfer', { id }),
  deleteTransfer: (id: string) => invoke<void>('delete_transfer', { id }),
  logout: () => invoke<BootstrapPayload>('logout'),
}
