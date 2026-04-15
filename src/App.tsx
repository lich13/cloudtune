import { convertFileSrc } from '@tauri-apps/api/core'
import QRCode from 'qrcode'
import { startTransition, useDeferredValue, useEffect, useRef, useState } from 'react'
import { api } from './api'
import type {
  BootstrapPayload,
  FolderBrowsePayload,
  FolderSelection,
  LoopMode,
  NowPlayingMetadata,
  PreparedTrack,
  TrackSummary,
  TransferSnapshotPayload,
} from './types'

const ROOT_BREADCRUMB = { id: null as string | null, name: '我的云盘' }
type ModuleView = 'music' | 'video' | 'download'
const ACCOUNT_NAME_STORAGE_KEY = 'cloudtune.accountName'
const AUTHENTICATED_STORAGE_KEY = 'cloudtune.authenticated'
const MAX_DOWNLOAD_THREADS = 16
const MAX_CACHE_THREADS = 8
const MAX_PLAYBACK_RECOVERY_ATTEMPTS = 12
const PLAYBACK_RECOVERY_DELAY_MS = 2500
const PLAYBACK_RECOVERY_MAX_DELAY_MS = 15000
const PLAYBACK_BUFFERING_TIMEOUT_MS = 15000
const PLAYBACK_RECENT_ACTIVITY_WINDOW_MS = 120000
const PLAYBACK_SWITCH_RECOVERY_WINDOW_MS = 30000

type PlaybackModeOverride = 'download_first' | 'stream_cache'

interface PlayTrackOptions {
  playbackModeOverride?: PlaybackModeOverride
  recoveryReason?: string | null
  resumeTime?: number
}

function normalizeResumeTime(value?: number) {
  if (!Number.isFinite(value) || value == null || value <= 0) {
    return 0
  }

  return value
}

function isNotSupportedPlaybackError(error: unknown) {
  if (error instanceof DOMException && error.name === 'NotSupportedError') {
    return true
  }

  return String(error).includes('NotSupportedError')
}

function isTransientDownloadError(error: unknown) {
  const text = String(error).toLowerCase()
  return [
    'timed out',
    'tcp connect error',
    'client error (connect)',
    'incompletemessage',
    'incomplete message',
    'deadline has elapsed',
    'connection reset',
    'connection aborted',
    'connection refused',
    '10060',
    '连接尝试失败',
    '没有反应',
  ].some((fragment) => text.includes(fragment))
}

async function waitForAudioReady(
  audio: HTMLAudioElement,
  timeoutMs = PLAYBACK_BUFFERING_TIMEOUT_MS,
) {
  if (audio.readyState > 0) {
    return
  }

  await new Promise<void>((resolve) => {
    const events = ['loadedmetadata', 'canplay', 'canplaythrough', 'error']
    const timeout = window.setTimeout(() => {
      cleanup()
      resolve()
    }, timeoutMs)

    const onReady = () => {
      cleanup()
      resolve()
    }

    const cleanup = () => {
      window.clearTimeout(timeout)
      events.forEach((eventName) => audio.removeEventListener(eventName, onReady))
    }

    events.forEach((eventName) => audio.addEventListener(eventName, onReady, { once: true }))
  })
}

function readStoredString(key: string) {
  if (typeof window === 'undefined') {
    return null
  }

  try {
    return window.localStorage.getItem(key)
  } catch {
    return null
  }
}

function writeStoredString(key: string, value: string | null) {
  if (typeof window === 'undefined') {
    return
  }

  try {
    if (value == null || value === '') {
      window.localStorage.removeItem(key)
    } else {
      window.localStorage.setItem(key, value)
    }
  } catch {
    // Ignore storage write failures in restricted browser contexts.
  }
}

function formatBytes(value: number) {
  if (value <= 0) {
    return '0 MB'
  }

  const units = ['B', 'KB', 'MB', 'GB']
  let size = value
  let index = 0

  while (size >= 1024 && index < units.length - 1) {
    size /= 1024
    index += 1
  }

  return `${size.toFixed(index > 1 ? 1 : 0)} ${units[index]}`
}

function formatClock(seconds: number) {
  if (!Number.isFinite(seconds) || seconds < 0) {
    return '00:00'
  }

  const rounded = Math.floor(seconds)
  const minute = Math.floor(rounded / 60)
  const second = rounded % 60
  return `${String(minute).padStart(2, '0')}:${String(second).padStart(2, '0')}`
}

function formatPercent(transferred: number, total: number | null) {
  if (!total || total <= 0) {
    return null
  }

  return Math.min(100, (transferred / total) * 100)
}

function randomItem<T>(items: T[]) {
  if (items.length === 0) {
    return null
  }

  return items[Math.floor(Math.random() * items.length)] ?? null
}

function randomTrackFromPool(tracks: TrackSummary[], excludeId?: string | null) {
  const candidates =
    excludeId == null ? tracks : tracks.filter((track) => track.id !== excludeId)
  return randomItem(candidates)
}

function App() {
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const qrPolling = useRef(false)
  const prefetchedTrackId = useRef<string | null>(null)
  const prefetchingTrackId = useRef<string | null>(null)
  const playbackRequestId = useRef(0)
  const recoveryAttemptRef = useRef(0)
  const lastPlaybackStartRef = useRef(0)
  const recoveryTimerRef = useRef<number | null>(null)
  const lastTrackRef = useRef<TrackSummary | null>(null)
  const pendingTrackRef = useRef<TrackSummary | null>(null)
  const currentTrackRef = useRef<TrackSummary | null>(null)
  const loadingTrackIdRef = useRef<string | null>(null)
  const isPlayingRef = useRef(false)
  const lastTrackSwitchAtRef = useRef(0)

  const [bootstrapping, setBootstrapping] = useState(true)
  const [busyLabel, setBusyLabel] = useState<string | null>(null)
  const [statusMessage, setStatusMessage] = useState<string | null>(null)

  const [authenticated, setAuthenticated] = useState(
    () => readStoredString(AUTHENTICATED_STORAGE_KEY) === '1',
  )
  const [accountName, setAccountName] = useState<string | null>(() =>
    readStoredString(ACCOUNT_NAME_STORAGE_KEY),
  )
  const [currentFolder, setCurrentFolder] = useState<FolderSelection | null>(null)

  const [cacheLimitInput, setCacheLimitInput] = useState('1024')
  const [downloadThreadsInput, setDownloadThreadsInput] = useState('16')
  const [cacheThreadsInput, setCacheThreadsInput] = useState('16')
  const [playbackMode, setPlaybackMode] = useState('download_first')
  const [cacheUsageBytes, setCacheUsageBytes] = useState(0)

  const [qrText, setQrText] = useState<string | null>(null)
  const [qrImage, setQrImage] = useState<string | null>(null)
  const [qrHint, setQrHint] = useState<string | null>(null)

  const [browser, setBrowser] = useState<FolderBrowsePayload | null>(null)
  const [breadcrumbs, setBreadcrumbs] = useState([ROOT_BREADCRUMB])
  const [activeModule, setActiveModule] = useState<ModuleView>('music')

  const [tracks, setTracks] = useState<TrackSummary[]>([])
  const [search, setSearch] = useState('')
  const deferredSearch = useDeferredValue(search)

  const [currentTrackId, setCurrentTrackId] = useState<string | null>(null)
  const [currentLocalPath, setCurrentLocalPath] = useState<string | null>(null)
  const [nowPlayingMetadata, setNowPlayingMetadata] = useState<NowPlayingMetadata | null>(null)
  const [isPlaying, setIsPlaying] = useState(false)
  const [loadingTrackId, setLoadingTrackId] = useState<string | null>(null)
  const [shuffle, setShuffle] = useState(true)
  const [loopMode, setLoopMode] = useState<LoopMode>('all')
  const [currentTime, setCurrentTime] = useState(0)
  const [duration, setDuration] = useState(0)
  const [transferSnapshot, setTransferSnapshot] =
    useState<TransferSnapshotPayload | null>(null)

  const visibleTracks = tracks.filter((track) => {
    if (!deferredSearch.trim()) {
      return true
    }

    const needle = deferredSearch.toLowerCase()
    return (
      track.name.toLowerCase().includes(needle) ||
      track.folderPath.toLowerCase().includes(needle)
    )
  })

  const currentTrack =
    tracks.find((track) => track.id === currentTrackId) ??
    visibleTracks.find((track) => track.id === currentTrackId) ??
    null
  const downloadTransfers =
    transferSnapshot?.items.filter((item) => item.kind === 'download') ?? []
  const downloadFiles = browser
    ? [...browser.audioFiles, ...browser.videoFiles, ...browser.otherFiles]
    : []
  const qrHost = (() => {
    if (!qrText) {
      return null
    }

    try {
      return new URL(qrText).hostname
    } catch {
      return null
    }
  })()

  useEffect(() => {
    currentTrackRef.current = currentTrack
  }, [currentTrack])

  useEffect(() => {
    loadingTrackIdRef.current = loadingTrackId
  }, [loadingTrackId])

  useEffect(() => {
    isPlayingRef.current = isPlaying
  }, [isPlaying])

  function clearRecoveryTimer() {
    if (recoveryTimerRef.current != null) {
      window.clearTimeout(recoveryTimerRef.current)
      recoveryTimerRef.current = null
    }
  }

  function resolveRecoveryTrack() {
    const loadingTrackId = loadingTrackIdRef.current
    if (loadingTrackId && pendingTrackRef.current?.id === loadingTrackId) {
      return pendingTrackRef.current
    }

    return currentTrackRef.current ?? pendingTrackRef.current ?? lastTrackRef.current
  }

  async function recoverPlayback(reason: string) {
    const track = resolveRecoveryTrack()
    const audio = audioRef.current
    if (!track || !audio) {
      return
    }
    if (recoveryTimerRef.current != null) {
      return
    }
    if (!audio.currentSrc && loadingTrackIdRef.current == null) {
      return
    }
    if (audio.ended || audio.seeking) {
      return
    }
    const elapsedSinceStart = Date.now() - lastPlaybackStartRef.current
    const elapsedSinceSwitch = Date.now() - lastTrackSwitchAtRef.current
    const inSwitchRecoveryWindow = elapsedSinceSwitch < PLAYBACK_SWITCH_RECOVERY_WINDOW_MS
    const recentlyActive =
      isPlayingRef.current ||
      audio.currentTime > 0 ||
      elapsedSinceStart < PLAYBACK_RECENT_ACTIVITY_WINDOW_MS ||
      inSwitchRecoveryWindow
    if (!recentlyActive) {
      return
    }
    if (
      loadingTrackIdRef.current &&
      !(inSwitchRecoveryWindow && loadingTrackIdRef.current === track.id)
    ) {
      return
    }
    if (recoveryAttemptRef.current >= MAX_PLAYBACK_RECOVERY_ATTEMPTS) {
      setStatusMessage(`播放异常，已停止自动重试《${track.name}》`)
      setIsPlaying(false)
      return
    }

    recoveryAttemptRef.current += 1
    const resumeTime = audio.currentTime
    const nextDelay = Math.min(
      PLAYBACK_RECOVERY_DELAY_MS * recoveryAttemptRef.current,
      PLAYBACK_RECOVERY_MAX_DELAY_MS,
    )
    clearRecoveryTimer()
    recoveryTimerRef.current = window.setTimeout(() => {
      recoveryTimerRef.current = null
      void playTrack(track, {
        playbackModeOverride: reason === 'NotSupportedError' ? 'download_first' : undefined,
        recoveryReason: reason,
        resumeTime,
      })
    }, nextDelay)
    setIsPlaying(false)
    setStatusMessage(
      `播放异常，正在重试《${track.name}》(${recoveryAttemptRef.current}/${MAX_PLAYBACK_RECOVERY_ATTEMPTS})`,
    )
  }

  async function loadBootstrap(showBusy = true) {
    if (showBusy) {
      setBusyLabel('同步本地配置...')
    }

    try {
      const payload = await api.bootstrap()
      applyBootstrap(payload)
      if (payload.authenticated) {
        await browseTo(null, [ROOT_BREADCRUMB], false, true)
        const refreshed = await api.bootstrap()
        applyBootstrap(refreshed)
      }
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
      setBootstrapping(false)
    }
  }

  function applyBootstrap(payload: BootstrapPayload) {
    const nextAccountName =
      payload.accountName ?? (payload.authenticated ? accountName : null)

    setAuthenticated(payload.authenticated)
    setAccountName(nextAccountName)
    setCurrentFolder(payload.currentFolder)
    setTracks(payload.libraryTracks)
    setCacheLimitInput(String(payload.cacheLimitMb))
    setDownloadThreadsInput(String(payload.downloadThreads))
    setCacheThreadsInput(String(payload.cacheThreads))
    setPlaybackMode(payload.playbackMode)
    setCacheUsageBytes(payload.cacheUsageBytes)
    setStatusMessage(payload.lastError)

    writeStoredString(
      AUTHENTICATED_STORAGE_KEY,
      payload.authenticated ? '1' : null,
    )
    writeStoredString(
      ACCOUNT_NAME_STORAGE_KEY,
      payload.authenticated ? nextAccountName : null,
    )
  }

  async function browseTo(
    folderId: string | null,
    nextBreadcrumbs: Array<{ id: string | null; name: string }>,
    showBusy = true,
    force = false,
  ) {
    if (!force && !authenticated) {
      return
    }

    if (showBusy) {
      setBusyLabel('读取云盘目录...')
    }

    try {
      const payload = await api.listRemoteFolder(folderId)
      setBrowser(payload)
      setBreadcrumbs(nextBreadcrumbs)
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function refreshLibrary(showBusy = true) {
    if (!currentFolder) {
      setStatusMessage('先在左侧选择一个音乐目录。')
      return
    }

    if (showBusy) {
      setBusyLabel(`扫描 ${currentFolder.name} 中的音乐...`)
    }

    try {
      const payload = await api.scanLibrary()
      startTransition(() => {
        setTracks(payload)
      })
      setStatusMessage(`已载入 ${payload.length} 首音乐`)
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function beginQrLogin() {
    setBusyLabel('生成二维码...')
    try {
      const payload = await api.startQrLogin()
      const image = await QRCode.toDataURL(payload.qrContent, {
        width: 240,
        margin: 1,
        color: {
          dark: '#13271f',
          light: '#f6f1e8',
        },
      })
      setQrText(payload.qrContent)
      setQrImage(image)
      setQrHint(payload.message)
      setStatusMessage(payload.message)
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function playTrack(track: TrackSummary, options?: PlayTrackOptions) {
    const requestId = playbackRequestId.current + 1
    playbackRequestId.current = requestId
    lastTrackRef.current = track
    pendingTrackRef.current = track
    lastTrackSwitchAtRef.current = Date.now()
    clearRecoveryTimer()
    setLoadingTrackId(track.id)

    try {
      prefetchedTrackId.current = null
      prefetchingTrackId.current = null
      const payload: PreparedTrack = await api.prepareTrack(
        track.id,
        track.name,
        track.sizeBytes,
        options?.playbackModeOverride,
      )
      const audio = audioRef.current
      if (!audio || requestId !== playbackRequestId.current) {
        return
      }

      audio.src = payload.isStreaming
        ? payload.playbackUrl
        : convertFileSrc(payload.localPath)
      audio.load()
      await waitForAudioReady(audio, PLAYBACK_BUFFERING_TIMEOUT_MS)
      try {
        await audio.play()
      } catch (error) {
        if (
          payload.isStreaming &&
          isNotSupportedPlaybackError(error) &&
          options?.playbackModeOverride !== 'download_first'
        ) {
          await playTrack(track, {
            playbackModeOverride: 'download_first',
            recoveryReason: options?.recoveryReason ?? 'NotSupportedError',
            resumeTime: options?.resumeTime,
          })
          return
        }

        throw error
      }

      if (requestId !== playbackRequestId.current) {
        return
      }

      const resumeTime = normalizeResumeTime(options?.resumeTime)
      if (resumeTime > 0) {
        audio.currentTime = Math.min(resumeTime, audio.duration || resumeTime)
      }

      setCurrentTrackId(payload.trackId)
      setCurrentLocalPath(payload.localPath)
      setNowPlayingMetadata(null)
      setCacheUsageBytes(payload.cacheUsageBytes)
      setIsPlaying(true)
      pendingTrackRef.current = null
      recoveryAttemptRef.current = 0
      lastPlaybackStartRef.current = Date.now()
      const playbackStatusLabel = options?.recoveryReason
        ? `已恢复播放《${track.name}》`
        : payload.isStreaming
          ? `边播边缓存《${track.name}》`
          : `正在播放《${track.name}》`
      setStatusMessage(playbackStatusLabel)
    } catch (error) {
      if (requestId === playbackRequestId.current) {
        const effectivePlaybackMode = options?.playbackModeOverride ?? playbackMode
        if (
          effectivePlaybackMode === 'download_first' &&
          options?.playbackModeOverride !== 'stream_cache' &&
          options?.recoveryReason !== 'NotSupportedError' &&
          isTransientDownloadError(error)
        ) {
          setStatusMessage(`《${track.name}》下载后播放失败，改用边播边缓存继续播放`)
          await playTrack(track, {
            playbackModeOverride: 'stream_cache',
            recoveryReason: options?.recoveryReason ?? 'download-timeout-fallback',
            resumeTime: options?.resumeTime,
          })
          return
        }

        setStatusMessage(String(error))
        setIsPlaying(false)
        const reason = isNotSupportedPlaybackError(error)
          ? 'NotSupportedError'
          : 'playback-interrupted'
        void recoverPlayback(reason)
      }
    } finally {
      if (requestId === playbackRequestId.current) {
        setLoadingTrackId(null)
      }
    }
  }

  async function togglePlayback() {
    const audio = audioRef.current
    if (!audio) {
      return
    }

    if (!currentTrack) {
      const nextTrack = randomItem(tracks.length > 0 ? tracks : visibleTracks)
      if (nextTrack) {
        await playTrack(nextTrack)
      }
      return
    }

    if (audio.paused) {
      await audio.play()
      setIsPlaying(true)
      return
    }

    audio.pause()
    setIsPlaying(false)
  }

  function resolveUpcomingTrack() {
    if (prefetchedTrackId.current) {
      return tracks.find((track) => track.id === prefetchedTrackId.current) ?? null
    }

    if (tracks.length === 0 || !currentTrackId) {
      return null
    }

    if (shuffle) {
      return randomTrackFromPool(tracks, currentTrackId)
    }

    return pickAdjacentTrack(1)
  }

  function pickAdjacentTrack(direction: -1 | 1) {
    if (tracks.length === 0) {
      return null
    }

    const currentIndex = tracks.findIndex((track) => track.id === currentTrackId)
    if (currentIndex < 0) {
      return tracks[0]
    }

    if (shuffle) {
      if (tracks.length === 1) {
        return tracks[0]
      }

      let randomIndex = currentIndex
      while (randomIndex === currentIndex) {
        randomIndex = Math.floor(Math.random() * tracks.length)
      }
      return tracks[randomIndex]
    }

    const nextIndex = currentIndex + direction
    if (nextIndex >= 0 && nextIndex < tracks.length) {
      return tracks[nextIndex]
    }

    if (loopMode === 'all') {
      return direction > 0 ? tracks[0] : tracks[tracks.length - 1]
    }

    return null
  }

  async function playAdjacent(direction: -1 | 1) {
    const nextTrack = pickAdjacentTrack(direction)
    if (nextTrack) {
      await playTrack(nextTrack)
    }
  }

  async function saveCurrentFolder() {
    const breadcrumb = breadcrumbs[breadcrumbs.length - 1]
    if (!breadcrumb || !browser) {
      return
    }

    setBusyLabel(`保存 ${breadcrumb.name} 为音乐目录...`)
    try {
      const payload = await api.saveMusicFolder(
        browser.currentFolderId,
        breadcrumb.name,
      )
      setCurrentFolder(payload.currentFolder)
      setCacheUsageBytes(payload.cacheUsageBytes)
      setCacheLimitInput(String(payload.cacheLimitMb))
      setStatusMessage(`音乐目录已设置为 ${breadcrumb.name}`)
      await refreshLibrary(false)
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function saveCacheLimit() {
    const nextLimit = Number(cacheLimitInput)
    if (!Number.isFinite(nextLimit) || nextLimit < 256) {
      setStatusMessage('缓存上限至少设为 256 MB。')
      return
    }

    setBusyLabel('更新缓存上限...')
    try {
      const payload = await api.updateCacheLimit(nextLimit)
      setCurrentFolder(payload.currentFolder)
      setCacheLimitInput(String(payload.cacheLimitMb))
      setDownloadThreadsInput(String(payload.downloadThreads))
      setCacheThreadsInput(String(payload.cacheThreads))
      setPlaybackMode(payload.playbackMode)
      setCacheUsageBytes(payload.cacheUsageBytes)
      setStatusMessage('缓存限制已更新')
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function logout() {
    setBusyLabel('退出登录...')
    try {
      const payload = await api.logout()
      applyBootstrap(payload)
      setBrowser(null)
      setTracks([])
      setQrText(null)
      setQrImage(null)
      setQrHint(null)
      setBreadcrumbs([ROOT_BREADCRUMB])
      setCurrentTrackId(null)
      setCurrentLocalPath(null)
      setNowPlayingMetadata(null)
      setIsPlaying(false)
      const audio = audioRef.current
      if (audio) {
        audio.pause()
        audio.removeAttribute('src')
        audio.load()
      }
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function saveTransferTuning() {
    const downloadThreads = Number(downloadThreadsInput)
    const cacheThreads = Number(cacheThreadsInput)
    if (!Number.isFinite(downloadThreads) || downloadThreads < 1 || downloadThreads > MAX_DOWNLOAD_THREADS) {
      setStatusMessage(`下载线程范围是 1-${MAX_DOWNLOAD_THREADS}`)
      return
    }
    if (!Number.isFinite(cacheThreads) || cacheThreads < 1 || cacheThreads > MAX_CACHE_THREADS) {
      setStatusMessage(`缓存线程范围是 1-${MAX_CACHE_THREADS}`)
      return
    }

    setBusyLabel('更新传输参数...')
    try {
      const payload = await api.updateTransferTuning(downloadThreads, cacheThreads)
      setCacheLimitInput(String(payload.cacheLimitMb))
      setDownloadThreadsInput(String(payload.downloadThreads))
      setCacheThreadsInput(String(payload.cacheThreads))
      setPlaybackMode(payload.playbackMode)
      setCacheUsageBytes(payload.cacheUsageBytes)
      setStatusMessage('传输参数已更新')
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function savePlaybackMode(mode: string) {
    setPlaybackMode(mode)
    try {
      const payload = await api.updatePlaybackMode(mode)
      setPlaybackMode(payload.playbackMode)
      setCacheLimitInput(String(payload.cacheLimitMb))
      setDownloadThreadsInput(String(payload.downloadThreads))
      setCacheThreadsInput(String(payload.cacheThreads))
      setCacheUsageBytes(payload.cacheUsageBytes)
      setStatusMessage(
        mode === 'download_first' ? '已切到下载完成后播放' : '已切到边播边缓存',
      )
    } catch (error) {
      setStatusMessage(String(error))
    }
  }

  useEffect(() => {
    void loadBootstrap()
  }, [])

  useEffect(() => {
    if (!qrText || qrPolling.current) {
      return
    }

    qrPolling.current = true
    const timer = window.setInterval(async () => {
      try {
        const payload = await api.pollQrLogin()
        setQrHint(payload.message)
        setStatusMessage(payload.message)
        if (payload.state === 'authenticated') {
          window.clearInterval(timer)
          qrPolling.current = false
          setQrText(null)
          setQrImage(null)
          await loadBootstrap(false)
        }
        if (payload.state === 'expired') {
          window.clearInterval(timer)
          qrPolling.current = false
          setQrText(null)
          setQrImage(null)
        }
      } catch (error) {
        window.clearInterval(timer)
        qrPolling.current = false
        setStatusMessage(String(error))
      }
    }, 2500)

    return () => {
      qrPolling.current = false
      window.clearInterval(timer)
    }
  }, [qrText])

  useEffect(() => {
    const audio = audioRef.current
    if (!audio) {
      return
    }

    const onPlay = () => {
      clearRecoveryTimer()
      setIsPlaying(true)
    }
    const onPause = () => setIsPlaying(false)
    const onTimeUpdate = () => setCurrentTime(audio.currentTime)
    const onLoadedMetadata = () => setDuration(audio.duration)
    const onEnded = async () => {
      clearRecoveryTimer()
      recoveryAttemptRef.current = 0
      if (loopMode === 'one' && currentTrack) {
        audio.currentTime = 0
        await audio.play()
        return
      }

      const nextTrack = resolveUpcomingTrack()
      prefetchedTrackId.current = null
      prefetchingTrackId.current = null
      if (nextTrack) {
        await playTrack(nextTrack)
      } else {
        setIsPlaying(false)
      }
    }
    const onPlaybackProblem = () => {
      const reason = audio.error?.code === 4 ? 'NotSupportedError' : 'playback-interrupted'
      void recoverPlayback(reason)
    }

    audio.addEventListener('play', onPlay)
    audio.addEventListener('pause', onPause)
    audio.addEventListener('timeupdate', onTimeUpdate)
    audio.addEventListener('loadedmetadata', onLoadedMetadata)
    audio.addEventListener('ended', onEnded)
    audio.addEventListener('error', onPlaybackProblem)
    audio.addEventListener('stalled', onPlaybackProblem)
    audio.addEventListener('emptied', onPlaybackProblem)

    return () => {
      clearRecoveryTimer()
      audio.removeEventListener('play', onPlay)
      audio.removeEventListener('pause', onPause)
      audio.removeEventListener('timeupdate', onTimeUpdate)
      audio.removeEventListener('loadedmetadata', onLoadedMetadata)
      audio.removeEventListener('ended', onEnded)
      audio.removeEventListener('error', onPlaybackProblem)
      audio.removeEventListener('stalled', onPlaybackProblem)
      audio.removeEventListener('emptied', onPlaybackProblem)
    }
  }, [currentTrack, currentTrackId, loopMode, shuffle, tracks])

  useEffect(() => {
    if (!currentTrack || !currentLocalPath) {
      setNowPlayingMetadata(null)
      return
    }

    let disposed = false
    const fallbackAlbum = currentTrack.folderPath || currentFolder?.name || '天翼云盘'

    void api
      .readTrackMetadata(currentLocalPath, currentTrack.name, fallbackAlbum)
      .then((metadata) => {
        if (!disposed) {
          setNowPlayingMetadata(metadata)
        }
      })
      .catch(() => {
        if (!disposed) {
          setNowPlayingMetadata({
            title: currentTrack.name,
            artist: null,
            album: fallbackAlbum,
            artworkPath: null,
          })
        }
      })

    return () => {
      disposed = true
    }
  }, [currentFolder?.name, currentLocalPath, currentTrack])

  useEffect(() => {
    const audio = audioRef.current
    if (!audio) {
      return
    }

    const title = nowPlayingMetadata?.title ?? currentTrack?.name ?? null
    document.title = title ? `${title} · CloudTune` : 'CloudTune'

    if (!('mediaSession' in navigator)) {
      return
    }

    navigator.mediaSession.metadata = currentTrack
      ? new MediaMetadata({
          title: nowPlayingMetadata?.title ?? currentTrack.name,
          artist: nowPlayingMetadata?.artist ?? accountName ?? 'CloudTune',
          album:
            nowPlayingMetadata?.album ??
            currentTrack.folderPath ??
            currentFolder?.name ??
            '天翼云盘',
          artwork: nowPlayingMetadata?.artworkPath
            ? [
                {
                  src: convertFileSrc(nowPlayingMetadata.artworkPath),
                },
              ]
            : [
                {
                  src: '/app-cover.png',
                },
              ],
        })
      : null

    navigator.mediaSession.playbackState = isPlaying ? 'playing' : 'paused'

    try {
      navigator.mediaSession.setActionHandler('play', () => {
        void togglePlayback()
      })
      navigator.mediaSession.setActionHandler('pause', () => {
        const audio = audioRef.current
        if (!audio) {
          return
        }
        audio.pause()
        setIsPlaying(false)
      })
      navigator.mediaSession.setActionHandler('previoustrack', () => {
        void playAdjacent(-1)
      })
      navigator.mediaSession.setActionHandler('nexttrack', () => {
        void playAdjacent(1)
      })
      navigator.mediaSession.setActionHandler('seekbackward', () => {
        const audio = audioRef.current
        if (!audio) {
          return
        }
        audio.currentTime = Math.max(0, audio.currentTime - 15)
      })
      navigator.mediaSession.setActionHandler('seekforward', () => {
        const audio = audioRef.current
        if (!audio) {
          return
        }
        audio.currentTime = Math.min(audio.duration || audio.currentTime + 15, audio.currentTime + 15)
      })
    } catch {
      // Some browsers expose Media Session partially and reject unsupported handlers.
    }

    if ('setPositionState' in navigator.mediaSession && duration > 0) {
      try {
        navigator.mediaSession.setPositionState({
          duration,
          playbackRate: audio.playbackRate || 1,
          position: Math.min(currentTime, duration),
        })
      } catch {
        // Position state updates are best-effort only.
      }
    }
  }, [
    accountName,
    currentFolder?.name,
    currentTime,
    currentTrack,
    duration,
    isPlaying,
    nowPlayingMetadata,
    tracks.length,
  ])

  useEffect(() => {
    if (
      !authenticated ||
      !currentTrack ||
      loopMode === 'one' ||
      playbackMode !== 'stream_cache'
    ) {
      return
    }

    const remaining = duration - currentTime
    if (!Number.isFinite(remaining) || remaining > 30 || remaining <= 0) {
      return
    }

    const nextTrack = resolveUpcomingTrack()
    if (!nextTrack) {
      return
    }

    if (
      prefetchingTrackId.current === nextTrack.id ||
      prefetchedTrackId.current === nextTrack.id
    ) {
      return
    }

    prefetchingTrackId.current = nextTrack.id
    void api
      .prefetchTrack(nextTrack.id, nextTrack.name, nextTrack.sizeBytes)
      .then(() => {
        prefetchedTrackId.current = nextTrack.id
      })
      .catch(() => {
        if (prefetchedTrackId.current === nextTrack.id) {
          prefetchedTrackId.current = null
        }
      })
      .finally(() => {
        if (prefetchingTrackId.current === nextTrack.id) {
          prefetchingTrackId.current = null
        }
      })
  }, [authenticated, currentTrack, currentTime, duration, loopMode, playbackMode, shuffle, tracks])

  useEffect(() => {
    if (!authenticated) {
      setTransferSnapshot(null)
      return
    }

    const timer = window.setInterval(() => {
      void api
        .getTransferSnapshot()
        .then(setTransferSnapshot)
        .catch(() => {})
    }, 900)

    return () => {
      window.clearInterval(timer)
    }
  }, [authenticated])

  async function pickAndDownloadTrack(track: TrackSummary) {
    const directory = await api.pickDownloadDirectory()
    if (!directory) {
      return
    }

    setBusyLabel(`下载 ${track.name}...`)
    try {
      const taskId = await api.downloadTrackToDirectory(
        track.id,
        track.name,
        track.sizeBytes,
        directory,
      )
      setStatusMessage(`已创建下载任务 ${taskId}`)
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function pickAndDownloadFolder() {
    if (!browser) {
      return
    }

    const directory = await api.pickDownloadDirectory()
    if (!directory) {
      return
    }

    setBusyLabel(`下载 ${browser.currentFolderName}...`)
    try {
      const result = await api.downloadFolderToDirectory(
        browser.currentFolderId,
        browser.currentFolderName,
        directory,
      )
      setStatusMessage(`目录下载已入队：${result}`)
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function openVideo(track: TrackSummary) {
    setBusyLabel(`打开 ${track.name}...`)
    try {
      await api.openVideoInSystem(track.id)
      setStatusMessage(`已交给系统播放器：${track.name}`)
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setBusyLabel(null)
    }
  }

  async function pauseTransfer(id: string) {
    await api.pauseTransfer(id)
    const snapshot = await api.getTransferSnapshot()
    setTransferSnapshot(snapshot)
  }

  async function deleteTransfer(id: string) {
    await api.deleteTransfer(id)
    const snapshot = await api.getTransferSnapshot()
    setTransferSnapshot(snapshot)
  }

  async function resumeTransfer(id: string) {
    await api.resumeTransfer(id)
    const snapshot = await api.getTransferSnapshot()
    setTransferSnapshot(snapshot)
  }

  function renderModuleTabs() {
    const tabs: Array<{ id: ModuleView; label: string }> = [
      { id: 'music', label: '音乐' },
      { id: 'video', label: '视频' },
      { id: 'download', label: '下载' },
    ]

    return (
      <div className="module-tabs">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            className={`module-tab ${activeModule === tab.id ? 'active' : ''}`}
            onClick={() => setActiveModule(tab.id)}
          >
            {tab.label}
          </button>
        ))}
      </div>
    )
  }

  return (
    <main className="shell">
      <audio ref={audioRef} preload="metadata" />

      <section className="hero-panel">
        <div className="brand-panel">
          <p className="eyebrow">CloudTune</p>
          <h1>天翼云盘音乐播放器</h1>
          <p className="brand-caption">
            {authenticated
              ? `${currentFolder?.name ?? '未设置目录'} · ${tracks.length} 首`
              : '扫码后立即播放'}
          </p>
        </div>
        <div className="hero-meta">
          <div className={`status-pill ${authenticated ? 'online' : 'offline'}`}>
            {authenticated ? '已连接天翼云盘' : '未登录'}
          </div>
          <div className="metric-block">
            <span>当前账号</span>
            <strong>{accountName ?? '等待扫码登录'}</strong>
          </div>
          <div className="metric-block">
            <span>缓存占用</span>
            <strong>{formatBytes(cacheUsageBytes)}</strong>
          </div>
          <div className="metric-block">
            <span>缓存上限</span>
            <strong>{cacheLimitInput} MB</strong>
          </div>
          <div className="metric-block">
            <span>下载线程</span>
            <strong>{downloadThreadsInput}</strong>
          </div>
          <div className="metric-block">
            <span>缓存线程</span>
            <strong>{cacheThreadsInput}</strong>
          </div>
          <div className="metric-block">
            <span>播放模式</span>
            <strong>{playbackMode === 'download_first' ? '下载后播放' : '边播边缓存'}</strong>
          </div>
          <div className="metric-block">
            <span>实时速度</span>
            <strong>
              {formatBytes(transferSnapshot?.totalSpeedBytesPerSecond ?? 0)}/s
            </strong>
          </div>
          {authenticated ? (
            <>
              <div className="limit-editor">
                <input
                  aria-label="缓存上限"
                  type="number"
                  min="256"
                  step="128"
                  value={cacheLimitInput}
                  onChange={(event) => setCacheLimitInput(event.target.value)}
                />
                <button className="secondary-button" onClick={() => void saveCacheLimit()}>
                  保存上限
                </button>
              </div>
              <div className="limit-editor">
                <input
                  aria-label="下载线程"
                  type="number"
                  min="1"
                  max={String(MAX_DOWNLOAD_THREADS)}
                  step="1"
                  value={downloadThreadsInput}
                  onChange={(event) => setDownloadThreadsInput(event.target.value)}
                />
                <input
                  aria-label="缓存线程"
                  type="number"
                  min="1"
                  max={String(MAX_CACHE_THREADS)}
                  step="1"
                  value={cacheThreadsInput}
                  onChange={(event) => setCacheThreadsInput(event.target.value)}
                />
                <button className="secondary-button" onClick={() => void saveTransferTuning()}>
                  保存线程
                </button>
              </div>
              <div className="queue-tools">
                <button
                  className={`toggle-chip ${playbackMode === 'download_first' ? 'active' : ''}`}
                  onClick={() => void savePlaybackMode('download_first')}
                >
                  下载后播放
                </button>
                <button
                  className={`toggle-chip ${playbackMode === 'stream_cache' ? 'active' : ''}`}
                  onClick={() => void savePlaybackMode('stream_cache')}
                >
                  边播边缓存
                </button>
              </div>
            </>
          ) : null}
        </div>
      </section>

      {statusMessage ? <p className="notice">{statusMessage}</p> : null}
      {busyLabel ? <p className="busy">{busyLabel}</p> : null}

      {!authenticated ? (
        <section className="auth-stage">
          <div className="card auth-card">
            <div className="auth-copy">
              <p className="card-title">扫码登录</p>
              <h2>用天翼云盘 App 扫码。</h2>
              <button
                className="primary-button auth-action"
                disabled={bootstrapping || !!busyLabel}
                onClick={() => void beginQrLogin()}
              >
                {qrImage ? '重新生成二维码' : '生成扫码二维码'}
              </button>
            </div>
            <div className="auth-visual">
              {qrImage ? (
                <div className="qr-box qr-box-large">
                  <img src={qrImage} alt="天翼云盘扫码二维码" />
                  <div className="qr-meta">
                    <p className="qr-heading">打开天翼云盘 App 扫码</p>
                    <p>{qrHint}</p>
                    {qrHost ? <span>{qrHost}</span> : null}
                  </div>
                </div>
              ) : (
                <div className="qr-placeholder">
                  <div className="qr-placeholder-grid" />
                  <p>二维码会显示在这里</p>
                </div>
              )}
            </div>
          </div>
        </section>
      ) : (
        <>
          {renderModuleTabs()}
          <section className="workspace">
            <aside className="side-panel">
              <div className="card">
                <div className="card-header">
                  <div>
                    <p className="card-title">账户</p>
                  </div>
                  <button className="secondary-button" onClick={() => void logout()}>
                    退出登录
                  </button>
                </div>
                <div className="settings-panel">
                  <div className="field-group">
                    <span>账号</span>
                    <strong>{accountName ?? '未登录'}</strong>
                  </div>
                  {activeModule === 'music' ? (
                    <>
                      <div className="field-group">
                        <span>当前音乐目录</span>
                        <strong>{currentFolder?.name ?? '尚未设置'}</strong>
                      </div>
                      <div className="field-group">
                        <span>库内曲目</span>
                        <strong>{tracks.length} 首</strong>
                      </div>
                      <button className="secondary-button" onClick={() => void refreshLibrary()}>
                        扫描音乐库
                      </button>
                    </>
                  ) : null}
                  {activeModule === 'download' && currentTrack ? (
                    <button
                      className="secondary-button"
                      onClick={() => void pickAndDownloadTrack(currentTrack)}
                    >
                      下载当前曲目
                    </button>
                  ) : null}
                </div>
              </div>

              <div className="card">
                <div className="card-header">
                  <div>
                    <p className="card-title">
                      {activeModule === 'music'
                        ? '音乐目录'
                        : activeModule === 'video'
                          ? '视频目录'
                          : '下载目录'}
                    </p>
                  </div>
                  <div className="side-actions">
                    <button
                      className="secondary-button"
                      onClick={() => void browseTo(null, [ROOT_BREADCRUMB])}
                    >
                      根目录
                    </button>
                    <button
                      className="secondary-button"
                      disabled={!browser}
                      onClick={() => void pickAndDownloadFolder()}
                    >
                      下载当前文件夹
                    </button>
                  </div>
                </div>

                <div className="breadcrumb">
                  {breadcrumbs.map((entry, index) => (
                    <button
                      key={`${entry.name}-${index}`}
                      className="breadcrumb-node"
                      disabled={index === breadcrumbs.length - 1}
                      onClick={() =>
                        void browseTo(
                          entry.id,
                          breadcrumbs.slice(0, index + 1),
                        )
                      }
                    >
                      {entry.name}
                    </button>
                  ))}
                </div>

                {activeModule === 'music' ? (
                  <>
                    <button className="primary-button" onClick={() => void saveCurrentFolder()}>
                      设为音乐库
                    </button>
                    <div className="folder-list">
                      {browser?.folders.map((folder) => (
                        <button
                          key={folder.id}
                          className="folder-row"
                          onClick={() =>
                            void browseTo(folder.id, [
                              ...breadcrumbs,
                              { id: folder.id, name: folder.name },
                            ])
                          }
                        >
                          <span>{folder.name}</span>
                          <small>打开</small>
                        </button>
                      ))}
                    </div>
                    <div className="preview-list">
                      <p className="preview-title">当前目录音频</p>
                      {browser?.audioFiles.map((track) => (
                        <button
                          key={track.id}
                          className="preview-row"
                          onClick={() => void playTrack(track)}
                        >
                          <span>{track.name}</span>
                          <small>{formatBytes(track.sizeBytes)}</small>
                        </button>
                      ))}
                    </div>
                  </>
                ) : null}

                {activeModule === 'video' ? (
                  <>
                    <div className="folder-list">
                      {browser?.folders.map((folder) => (
                        <button
                          key={folder.id}
                          className="folder-row"
                          onClick={() =>
                            void browseTo(folder.id, [
                              ...breadcrumbs,
                              { id: folder.id, name: folder.name },
                            ])
                          }
                        >
                          <span>{folder.name}</span>
                          <small>打开</small>
                        </button>
                      ))}
                    </div>
                    <div className="preview-list">
                      <p className="preview-title">当前目录视频</p>
                      {browser?.videoFiles.map((track) => (
                        <button
                          key={track.id}
                          className="preview-row"
                          onClick={() => void openVideo(track)}
                        >
                          <span>{track.name}</span>
                          <small>系统播放</small>
                        </button>
                      ))}
                    </div>
                  </>
                ) : null}

                {activeModule === 'download' ? (
                  <>
                    <div className="folder-list">
                      {browser?.folders.map((folder) => (
                        <button
                          key={folder.id}
                          className="folder-row"
                          onClick={() =>
                            void browseTo(folder.id, [
                              ...breadcrumbs,
                              { id: folder.id, name: folder.name },
                            ])
                          }
                        >
                          <span>{folder.name}</span>
                          <small>打开</small>
                        </button>
                      ))}
                    </div>
                    <div className="preview-list">
                      <p className="preview-title">当前目录文件</p>
                      {downloadFiles.map((track) => (
                        <button
                          key={track.id}
                          className="preview-row"
                          onClick={() => void pickAndDownloadTrack(track)}
                        >
                          <span>{track.name}</span>
                          <small>下载</small>
                        </button>
                      ))}
                    </div>
                  </>
                ) : null}
              </div>
            </aside>

            <section className="main-panel">
              {activeModule === 'music' ? (
                <>
                  <div className="card player-card">
                    <div className="now-playing">
                      <div>
                        <p className="card-title">正在播放</p>
                        <h2>{currentTrack?.name ?? '还没有选择歌曲'}</h2>
                        <p className="track-path">
                          {currentTrack?.folderPath ?? '点播放键会随机起播。'}
                        </p>
                      </div>
                      <div className="player-controls">
                        <button className="secondary-button" onClick={() => void playAdjacent(-1)}>
                          上一首
                        </button>
                        <button className="primary-button main-play-button" onClick={() => void togglePlayback()}>
                          {isPlaying ? '暂停' : currentTrack ? '播放' : '随机播放'}
                        </button>
                        <button className="secondary-button" onClick={() => void playAdjacent(1)}>
                          下一首
                        </button>
                      </div>
                    </div>

                    <div className="progress-block">
                      <input
                        type="range"
                        min="0"
                        max={duration || 0}
                        value={Math.min(currentTime, duration || 0)}
                        onChange={(event) => {
                          const audio = audioRef.current
                          if (!audio) {
                            return
                          }
                          const nextTime = Number(event.target.value)
                          audio.currentTime = nextTime
                          setCurrentTime(nextTime)
                        }}
                      />
                      <div className="time-line">
                        <span>{formatClock(currentTime)}</span>
                        <span>{formatClock(duration)}</span>
                      </div>
                    </div>

                    <div className="queue-tools">
                      <button
                        className={`toggle-chip ${shuffle ? 'active' : ''}`}
                        onClick={() => setShuffle((value) => !value)}
                      >
                        随机播放
                      </button>
                      <button
                        className={`toggle-chip ${loopMode !== 'off' ? 'active' : ''}`}
                        onClick={() =>
                          setLoopMode((value) =>
                            value === 'off' ? 'all' : value === 'all' ? 'one' : 'off',
                          )
                        }
                      >
                        {loopMode === 'off' ? '不循环' : loopMode === 'all' ? '列表循环' : '单曲循环'}
                      </button>
                    </div>
                  </div>

                  <div className="card library-card">
                    <div className="card-header">
                      <div>
                        <p className="card-title">音乐列表</p>
                      </div>
                      <input
                        className="search-box"
                        type="search"
                        placeholder="搜索文件名或目录"
                        value={search}
                        onChange={(event) => setSearch(event.target.value)}
                      />
                    </div>

                    <div className="track-table">
                      {visibleTracks.map((track) => (
                        <button
                          key={track.id}
                          className={`track-row ${track.id === currentTrackId ? 'active' : ''}`}
                          onClick={() => void playTrack(track)}
                        >
                          <div className="track-text">
                            <strong>{track.name}</strong>
                            <span>{track.folderPath}</span>
                          </div>
                          <div className="track-meta">
                            <small>{formatBytes(track.sizeBytes)}</small>
                            <small>{loadingTrackId === track.id ? '缓存中...' : '播放'}</small>
                          </div>
                        </button>
                      ))}
                    </div>
                  </div>
                </>
              ) : null}

              {activeModule === 'video' ? (
                <div className="card library-card">
                  <div className="card-header">
                    <div>
                      <p className="card-title">视频</p>
                    </div>
                  </div>
                  <div className="track-table">
                    {browser?.videoFiles.map((track) => (
                      <button
                        key={track.id}
                        className="track-row"
                        onClick={() => void openVideo(track)}
                      >
                        <div className="track-text">
                          <strong>{track.name}</strong>
                          <span>{track.folderPath}</span>
                        </div>
                        <div className="track-meta">
                          <small>{formatBytes(track.sizeBytes)}</small>
                          <small>系统播放</small>
                        </div>
                      </button>
                    ))}
                    {browser && browser.videoFiles.length === 0 ? (
                      <p className="empty-state">当前目录没有视频文件。</p>
                    ) : null}
                  </div>
                </div>
              ) : null}

              {activeModule === 'download' ? (
                <>
                  <div className="card">
                    <div className="card-header">
                      <div>
                        <p className="card-title">传输任务</p>
                      </div>
                    </div>
                    <div className="preview-list">
                      {downloadTransfers.map((item) => (
                        <div key={item.id} className="transfer-row transfer-row-card">
                          <div className="track-text">
                            <strong>{item.label}</strong>
                            <span>{item.state}</span>
                            {formatPercent(item.transferredBytes, item.totalBytes) !== null ? (
                              <div className="transfer-progress">
                                <div
                                  className="transfer-progress-fill"
                                  style={{
                                    width: `${formatPercent(item.transferredBytes, item.totalBytes)}%`,
                                  }}
                                />
                              </div>
                            ) : null}
                          </div>
                          <div className="transfer-actions">
                            <span>{formatBytes(item.bytesPerSecond)}/s</span>
                            {formatPercent(item.transferredBytes, item.totalBytes) !== null ? (
                              <span>
                                {formatPercent(item.transferredBytes, item.totalBytes)!.toFixed(1)}%
                              </span>
                            ) : null}
                            {item.canPause ? (
                              <button className="secondary-button" onClick={() => void pauseTransfer(item.id)}>
                                暂停
                              </button>
                            ) : null}
                            {item.canResume ? (
                              <button className="secondary-button" onClick={() => void resumeTransfer(item.id)}>
                                继续
                              </button>
                            ) : null}
                            {item.canDelete ? (
                              <button className="secondary-button" onClick={() => void deleteTransfer(item.id)}>
                                删除
                              </button>
                            ) : null}
                          </div>
                        </div>
                      ))}
                      {!downloadTransfers.length ? (
                        <p className="empty-state">当前没有活动传输。</p>
                      ) : null}
                    </div>
                  </div>
                  <div className="card library-card">
                    <div className="card-header">
                      <div>
                        <p className="card-title">下载</p>
                      </div>
                    </div>
                    <div className="track-table">
                      {downloadFiles.map((track) => (
                        <button
                          key={track.id}
                          className="track-row"
                          onClick={() => void pickAndDownloadTrack(track)}
                        >
                          <div className="track-text">
                            <strong>{track.name}</strong>
                            <span>{track.folderPath}</span>
                          </div>
                          <div className="track-meta">
                            <small>{formatBytes(track.sizeBytes)}</small>
                            <small>下载</small>
                          </div>
                        </button>
                      ))}
                      {browser && downloadFiles.length === 0 ? (
                        <p className="empty-state">当前目录没有可下载文件。</p>
                      ) : null}
                    </div>
                  </div>
                </>
              ) : null}
            </section>
          </section>
        </>
      )}
    </main>
  )
}

export default App
