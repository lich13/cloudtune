export type LoopMode = 'off' | 'all' | 'one'

export interface FolderSelection {
  id: string
  name: string
}

export interface BootstrapPayload {
  authenticated: boolean
  accountName: string | null
  currentFolder: FolderSelection | null
  libraryTracks: TrackSummary[]
  cacheLimitMb: number
  downloadThreads: number
  cacheThreads: number
  playbackMode: string
  cacheUsageBytes: number
  lastError: string | null
}

export interface QrLoginStart {
  qrContent: string
  message: string
}

export interface QrPollResponse {
  state: 'waiting_scan' | 'waiting_confirm' | 'authenticated' | 'expired'
  message: string
  accountName: string | null
}

export interface RemoteFolder {
  id: string
  name: string
  parentId: string | null
}

export interface TrackSummary {
  id: string
  name: string
  folderPath: string
  sizeBytes: number
  modifiedAt: string | null
}

export interface FolderBrowsePayload {
  currentFolderId: string
  currentFolderName: string
  parentFolderId: string | null
  isRoot: boolean
  folders: RemoteFolder[]
  audioFiles: TrackSummary[]
  videoFiles: TrackSummary[]
  otherFiles: TrackSummary[]
}

export interface PreparedTrack {
  trackId: string
  localPath: string
  playbackUrl: string
  isStreaming: boolean
  cacheUsageBytes: number
}

export interface SettingsPayload {
  currentFolder: FolderSelection | null
  cacheLimitMb: number
  downloadThreads: number
  cacheThreads: number
  playbackMode: string
  cacheUsageBytes: number
}

export interface TransferStatus {
  id: string
  label: string
  kind: string
  state: string
  path: string | null
  canPause: boolean
  canResume: boolean
  canDelete: boolean
  bytesPerSecond: number
  transferredBytes: number
  totalBytes: number | null
}

export interface TransferSnapshotPayload {
  totalSpeedBytesPerSecond: number
  items: TransferStatus[]
}

export interface NowPlayingMetadata {
  title: string
  artist: string | null
  album: string | null
  artworkPath: string | null
}
