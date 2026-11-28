package com.gosu.cloudtune.core

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class ExportDownloadItem(
    val track: TrackSummary,
    val relativeSubpath: String
)

fun interface StagedFileExporter {
    suspend fun export(
        stagedFile: File,
        relativeSubpath: String,
        accountId: String,
        exportTreeUri: String?
    ): String

    suspend fun exportParts(
        partFiles: List<File>,
        expectedTotalBytes: Long,
        relativeSubpath: String,
        accountId: String,
        exportTreeUri: String?
    ): String {
        if (partFiles.isEmpty()) {
            throw CloudTuneException("待导出的本地暂存分片不存在")
        }
        if (partFiles.size == 1) {
            return export(partFiles[0], relativeSubpath, accountId, exportTreeUri)
        }
        val parent = partFiles[0].parentFile ?: File(System.getProperty("java.io.tmpdir"))
        val compatTmp = File(parent, ".compat-export-${UUID.randomUUID()}.tmp")
        return try {
            FileOutputStream(compatTmp).use { out ->
                val buf = ByteArray(262_144)
                for (part in partFiles) {
                    FileInputStream(part).use { input ->
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            if (n > 0) out.write(buf, 0, n)
                        }
                    }
                }
                out.fd.sync()
            }
            export(compatTmp, relativeSubpath, accountId, exportTreeUri)
        } finally {
            compatTmp.delete()
        }
    }
}

data class StagedDownloadManifest(
    val taskId: String,
    val accountHash: String,
    val trackId: String,
    val fileName: String,
    val relativeSubpath: String,
    val totalSize: Long,
    val partCount: Int,
    val state: String,
    val exportTreeUri: String? = null
)

class TransferEngine(
    private val limiter: GlobalTransferLimiter,
    private val opener: UpstreamStreamOpener = HttpUrlConnectionStreamOpener(),
    private val onActivityChangeInitial: ((TransferSnapshotPayload, Boolean) -> Unit)? = null,
    private val nanoClock: () -> Long = { System.nanoTime() },
    private val urlResolver: suspend (String) -> String
) {
    private class InFlightCacheDownload(
        val workerId: UUID,
        val cacheKey: String,
        val statusId: String,
        val accountHash: String?,
        val waiterIds: MutableSet<UUID>,
        val deferred: Deferred<File>
    )

    private data class PendingExportWork(
        val taskId: String,
        val accountHash: String,
        val accountKey: String,
        val stagingRootDir: File,
        val manifestsFile: File,
        val exporter: StagedFileExporter
    )

    private class TaskSpeedCounter(initialBytes: Long, startNs: Long) {
        val transferredBytes = AtomicLong(initialBytes)
        val windowDeltaBytes = AtomicLong(0L)
        @Volatile var lastSampleNs: Long = startNs
        @Volatile var currentSpeedBps: Long = 0L

        fun addDelta(delta: Long, nowNs: Long): Pair<Long, Long> {
            val total = transferredBytes.addAndGet(delta)
            windowDeltaBytes.addAndGet(delta)
            sampleIfElapsed(nowNs, minWindowNs = SPEED_SAMPLE_WINDOW_NS, allowProvisional = true)
            return total to currentSpeedBps
        }

        fun sampleForSnapshot(nowNs: Long): Long {
            sampleIfElapsed(nowNs, minWindowNs = SPEED_SAMPLE_WINDOW_NS, allowProvisional = true)
            return currentSpeedBps
        }

        private fun sampleIfElapsed(nowNs: Long, minWindowNs: Long, allowProvisional: Boolean) {
            synchronized(this) {
                val elapsedNs = nowNs - lastSampleNs
                if (elapsedNs >= minWindowNs) {
                    val delta = windowDeltaBytes.getAndSet(0L)
                    lastSampleNs = nowNs
                    currentSpeedBps = (delta * 1_000_000_000L) / elapsedNs.coerceAtLeast(1L)
                } else if (allowProvisional && currentSpeedBps == 0L) {
                    val pending = windowDeltaBytes.get()
                    if (pending > 0L) {
                        val safeElapsed = elapsedNs.coerceAtLeast(10_000_000L)
                        currentSpeedBps = (pending * 1_000_000_000L) / safeElapsed
                    }
                }
            }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val persistLock = Any()
    private val cacheDownloadLock = Any()
    private val notifyLock = Any()
    private val statuses = ConcurrentHashMap<String, TransferStatus>()
    private val statusAccountHashes = ConcurrentHashMap<String, String>()
    private val manifests = ConcurrentHashMap<String, StagedDownloadManifest>()
    private val manifestAccountKeys = ConcurrentHashMap<String, String>()
    private val jobs = ConcurrentHashMap<String, Job>()
    private val speedCounters = ConcurrentHashMap<String, TaskSpeedCounter>()
    private val pendingExports = ConcurrentLinkedQueue<PendingExportWork>()
    private val exportTaskSemaphore = Semaphore(MAX_CONCURRENT_EXPORT_JOBS)
    private val exportPumpRunning = AtomicBoolean(false)
    private val inFlightCacheDownloads = HashMap<String, InFlightCacheDownload>()
    @Volatile private var onActivityChange: ((TransferSnapshotPayload, Boolean) -> Unit)? = onActivityChangeInitial
    private var lastNotifiedHasActive: Boolean = false
    internal var retryDelayBaseMs: Long = 250L

    fun setOnActivityChange(listener: ((TransferSnapshotPayload, Boolean) -> Unit)?) {
        val snap = snapshot()
        synchronized(notifyLock) {
            onActivityChange = listener
            lastNotifiedHasActive = snap.hasActiveItems
        }
    }

    fun hasActiveTransfers(): Boolean =
        statuses.values.any { it.state == "running" || it.state == "streaming" }

    private fun notifyActivityChanged(force: Boolean = false) {
        val listener = onActivityChange ?: return
        val snap = snapshot()
        val active = snap.hasActiveItems
        val shouldDispatch = synchronized(notifyLock) {
            val transitioned = active != lastNotifiedHasActive
            lastNotifiedHasActive = active
            force || transitioned
        }
        if (shouldDispatch) {
            listener.invoke(snap, active)
        }
    }

    fun snapshot(): TransferSnapshotPayload {
        val nowNs = nanoClock()
        for ((taskId, counter) in speedCounters.entries) {
            val sampledBps = counter.sampleForSnapshot(nowNs)
            val totalDone = counter.transferredBytes.get()
            statuses.computeIfPresent(taskId) { _, prev ->
                if (prev.state == "running") {
                    val clamped = prev.totalBytes?.let { minOf(totalDone, it) } ?: totalDone
                    prev.copy(transferredBytes = maxOf(prev.transferredBytes, clamped), bytesPerSecond = sampledBps)
                } else {
                    prev
                }
            }
        }
        val list = statuses.values.sortedBy { it.id }
        val speed = list.filter { it.state == "running" || it.state == "streaming" }
            .sumOf { it.bytesPerSecond }
        return TransferSnapshotPayload(speed, list)
    }

    fun updateExternalTransferStatus(id: String, status: TransferStatus?, accountHash: String? = null) {
        val prev = statuses[id]
        if (status != null) {
            statuses[id] = status
            if (accountHash != null) {
                statusAccountHashes[id] = accountHash
            }
            notifyActivityChanged(force = (prev == null || prev.state != status.state))
        } else {
            val removed = statuses.remove(id) != null
            statusAccountHashes.remove(id)
            if (removed) {
                notifyActivityChanged(force = true)
            }
        }
    }

    fun restorePersistedDownloads(accountId: String, stagingRootDir: File, manifestsFile: File) {
        val targetHash = Cloud189Protocol.accountBucketHash(accountId)
        val (fileExisted, rawText) = synchronized(persistLock) {
            if (!manifestsFile.isFile) {
                false to null
            } else {
                true to runCatching { manifestsFile.readText(Charsets.UTF_8) }.getOrNull()
            }
        }

        var canCleanOrphanedStaging = !fileExisted
        if (rawText != null) {
            val parsedArr = runCatching { JSONArray(rawText) }.getOrNull()
            if (parsedArr != null) {
                canCleanOrphanedStaging = true
                for (i in 0 until parsedArr.length()) {
                    runCatching {
                        val o = parsedArr.optJSONObject(i) ?: return@runCatching
                        val savedHash = o.optString("accountHash").trim()
                        val legacyAccountId = o.optString("accountId").trim()
                        if (savedHash.isNotEmpty() && savedHash != targetHash) return@runCatching
                        if (legacyAccountId.isNotEmpty() && Cloud189Protocol.accountBucketHash(legacyAccountId) != targetHash) return@runCatching

                        val taskId = Cloud189Protocol.optNonBlank(o, "taskId") ?: return@runCatching
                        val trackId = Cloud189Protocol.optNonBlank(o, "trackId") ?: return@runCatching
                        val fileName = Cloud189Protocol.optNonBlank(o, "fileName") ?: return@runCatching
                        val rawState = o.optString("state", "paused")
                        val restoredState = if (rawState == "running") "paused" else rawState
                        val manifest = StagedDownloadManifest(
                            taskId = taskId,
                            accountHash = targetHash,
                            trackId = trackId,
                            fileName = fileName,
                            relativeSubpath = o.optString("relativeSubpath", fileName).ifEmpty { fileName },
                            totalSize = o.optLong("totalSize", 0L).coerceAtLeast(0L),
                            partCount = o.optInt("partCount", 1).coerceAtLeast(1),
                            state = restoredState,
                            exportTreeUri = o.optString("exportTreeUri").takeIf { it.isNotEmpty() }
                        )
                        manifests[manifest.taskId] = manifest
                        manifestAccountKeys[manifest.taskId] = accountId
                        statusAccountHashes[manifest.taskId] = targetHash
                        val completed = completedBytesForManifest(manifest, stagingRootDir)
                        statuses[manifest.taskId] = TransferStatus(
                            id = manifest.taskId,
                            label = manifest.fileName,
                            kind = "download",
                            state = restoredState,
                            path = manifest.relativeSubpath,
                            canPause = false,
                            canResume = restoredState == "paused" || restoredState.startsWith("failed"),
                            canDelete = true,
                            bytesPerSecond = 0L,
                            transferredBytes = completed,
                            totalBytes = manifest.totalSize.takeIf { it > 0L }
                        )
                    }
                }
            }
        }

        // Clean unreferenced staging/ entries ONLY AFTER manifests are loaded!
        if (canCleanOrphanedStaging && stagingRootDir.isDirectory) {
            val referencedNames = manifests.values
                .filter { it.accountHash == targetHash }
                .mapTo(HashSet()) { "${Cloud189Protocol.sanitizeFileName(it.taskId)}.parts" }
            val children = stagingRootDir.listFiles()
            if (children != null) {
                for (child in children) {
                    if (child.name !in referencedNames) {
                        child.deleteRecursively()
                    }
                }
            }
        }

        if (fileExisted) {
            notifyActivityChanged(force = true)
        }
    }

    fun cancelAll(accountId: String) {
        val targetHash = Cloud189Protocol.accountBucketHash(accountId)
        pendingExports.removeIf { it.accountHash == targetHash }
        for ((id, m) in manifests.entries.toList()) {
            if (m.accountHash == targetHash) {
                jobs.remove(id)?.cancel()
                speedCounters.remove(id)
                statuses.remove(id)
                statusAccountHashes.remove(id)
                manifests.remove(id)
                manifestAccountKeys.remove(id)
            }
        }
        val cacheTasksToCancel = ArrayList<InFlightCacheDownload>()
        synchronized(cacheDownloadLock) {
            val iter = inFlightCacheDownloads.entries.iterator()
            while (iter.hasNext()) {
                val entry = iter.next().value
                if (entry.accountHash == null || entry.accountHash == targetHash) {
                    cacheTasksToCancel.add(entry)
                    iter.remove()
                }
            }
        }
        for (entry in cacheTasksToCancel) {
            entry.deferred.cancel()
            speedCounters.remove(entry.statusId)
            statuses.remove(entry.statusId)
            statusAccountHashes.remove(entry.statusId)
        }
        for ((id, ownerHash) in statusAccountHashes.entries.toList()) {
            if (ownerHash == targetHash) {
                jobs.remove(id)?.cancel()
                speedCounters.remove(id)
                statuses.remove(id)
                statusAccountHashes.remove(id)
            }
        }
        for (key in statuses.keys().toList()) {
            if (key.startsWith("stream:") || key.startsWith("prefetch:") || key.startsWith("playback:")) {
                val owner = statusAccountHashes[key]
                if (owner == null || owner == targetHash) {
                    speedCounters.remove(key)
                    statuses.remove(key)
                    statusAccountHashes.remove(key)
                }
            }
        }
        notifyActivityChanged(force = true)
    }

    fun hasInFlightCacheDownload(cacheFile: File): Boolean {
        val cacheKey = runCatching { cacheFile.canonicalPath }.getOrDefault(cacheFile.absolutePath)
        return synchronized(cacheDownloadLock) {
            inFlightCacheDownloads[cacheKey]?.deferred?.isActive == true
        }
    }

    suspend fun downloadTrackToCache(
        track: TrackSummary,
        cacheManager: CacheManager,
        parallelThreads: Int,
        cacheLimitBytes: Long,
        kind: String = "playback",
        accountHash: String? = null
    ): File = withContext(Dispatchers.IO) {
        cacheManager.existingCachedFile(track.id)?.let { return@withContext it }
        val dest = cacheManager.cacheFile(track.id, track.name)
        val cacheKey = runCatching { dest.canonicalPath }.getOrDefault(dest.absolutePath)
        val waiterId = UUID.randomUUID()

        val sharedDeferred: Deferred<File> = synchronized(cacheDownloadLock) {
            cacheManager.existingCachedFile(track.id)?.let { cached ->
                return@withContext cached
            }
            val existing = inFlightCacheDownloads[cacheKey]
            if (existing != null) {
                existing.waiterIds.add(waiterId)
                if (kind == "playback") {
                    statuses.computeIfPresent(existing.statusId) { _, prev -> prev.copy(kind = "playback") }
                }
                existing.deferred
            } else {
                val workerId = UUID.randomUUID()
                val statusId = "$kind:${track.id}:$workerId"
                statuses[statusId] = TransferStatus(
                    id = statusId,
                    label = track.name,
                    kind = kind,
                    state = "running",
                    totalBytes = track.sizeBytes.takeIf { it > 0L }
                )
                if (accountHash != null) {
                    statusAccountHashes[statusId] = accountHash
                }
                val created = scope.async(Dispatchers.IO) {
                    performCacheDownload(
                        workerId = workerId,
                        cacheKey = cacheKey,
                        statusId = statusId,
                        track = track,
                        dest = dest,
                        cacheManager = cacheManager,
                        parallelThreads = parallelThreads,
                        cacheLimitBytes = cacheLimitBytes
                    )
                }
                inFlightCacheDownloads[cacheKey] = InFlightCacheDownload(
                    workerId = workerId,
                    cacheKey = cacheKey,
                    statusId = statusId,
                    accountHash = accountHash,
                    waiterIds = mutableSetOf(waiterId),
                    deferred = created
                )
                created
            }
        }
        notifyActivityChanged(force = true)

        try {
            sharedDeferred.await()
        } catch (ce: CancellationException) {
            detachCacheDownloadWaiter(cacheKey, waiterId)
            throw ce
        }
    }

    private fun detachCacheDownloadWaiter(cacheKey: String, waiterId: UUID) {
        var toCancel: InFlightCacheDownload? = null
        synchronized(cacheDownloadLock) {
            val existing = inFlightCacheDownloads[cacheKey] ?: return
            existing.waiterIds.remove(waiterId)
            if (existing.waiterIds.isEmpty()) {
                inFlightCacheDownloads.remove(cacheKey)
                toCancel = existing
            }
        }
        toCancel?.let {
            speedCounters.remove(it.statusId)
            statuses.remove(it.statusId)
            statusAccountHashes.remove(it.statusId)
            it.deferred.cancel()
            notifyActivityChanged(force = true)
        }
    }

    private suspend fun performCacheDownload(
        workerId: UUID,
        cacheKey: String,
        statusId: String,
        track: TrackSummary,
        dest: File,
        cacheManager: CacheManager,
        parallelThreads: Int,
        cacheLimitBytes: Long
    ): File = withContext(Dispatchers.IO) {
        val partsDir = File(dest.parentFile, ".${dest.name}.$workerId.parts")
        val mergedTmp = File(dest.parentFile, ".${dest.name}.$workerId.merged.part")
        speedCounters[statusId] = TaskSpeedCounter(initialBytes = 0L, startNs = nanoClock())
        try {
            val remoteUrl = urlResolver(track.id)
            val probe = probeTarget(remoteUrl, track.sizeBytes)
            val totalSize = probe.first
            val supportsRange = probe.second
            val effectiveParts = if (supportsRange && totalSize >= 1_048_576L) parallelThreads.coerceIn(1, 8) else 1
            if (totalSize > 0L) {
                statuses.computeIfPresent(statusId) { _, prev -> prev.copy(totalBytes = totalSize) }
            }

            partsDir.deleteRecursively()
            partsDir.mkdirs()
            downloadParts(statusId, track.id, remoteUrl, totalSize, effectiveParts, partsDir)
            ensureActive()

            if (effectiveParts == 1) {
                val part0 = partFileForIndex(partsDir, 0)
                if (!part0.isFile || (totalSize > 0L && part0.length() != totalSize)) {
                    throw CloudTuneException("缓存分片长度不匹配：${part0.length()} != $totalSize")
                }
                AtomicFileIO.replaceAtomically(part0, dest)
            } else {
                mergeParts(partsDir, effectiveParts, mergedTmp, totalSize)
                AtomicFileIO.replaceAtomically(mergedTmp, dest)
            }

            cacheManager.recordCompletedFile(
                trackId = track.id,
                file = dest,
                sizeBytes = if (totalSize > 0L) totalSize else dest.length(),
                limitBytes = cacheLimitBytes
            )
            dest
        } finally {
            synchronized(cacheDownloadLock) {
                if (inFlightCacheDownloads[cacheKey]?.workerId == workerId) {
                    inFlightCacheDownloads.remove(cacheKey)
                }
            }
            speedCounters.remove(statusId)
            statuses.remove(statusId)
            statusAccountHashes.remove(statusId)
            partsDir.deleteRecursively()
            mergedTmp.delete()
            notifyActivityChanged(force = true)
        }
    }

    fun enqueueExportDownload(
        accountId: String,
        track: TrackSummary,
        relativeSubpath: String,
        parallelThreads: Int,
        stagingRootDir: File,
        manifestsFile: File,
        exportTreeUri: String? = null,
        exporter: StagedFileExporter
    ): String {
        return enqueueExportDownloads(
            accountId = accountId,
            items = listOf(ExportDownloadItem(track = track, relativeSubpath = relativeSubpath)),
            parallelThreads = parallelThreads,
            stagingRootDir = stagingRootDir,
            manifestsFile = manifestsFile,
            exportTreeUri = exportTreeUri,
            exporter = exporter
        ).first()
    }

    fun enqueueExportDownloads(
        accountId: String,
        items: List<ExportDownloadItem>,
        parallelThreads: Int,
        stagingRootDir: File,
        manifestsFile: File,
        exportTreeUri: String? = null,
        exporter: StagedFileExporter
    ): List<String> {
        if (items.isEmpty()) return emptyList()
        val partCount = parallelThreads.coerceIn(1, 16)
        val accountHash = Cloud189Protocol.accountBucketHash(accountId)
        val normalizedTreeUri = exportTreeUri?.takeIf { it.isNotBlank() }
        val taskIds = ArrayList<String>(items.size)
        val workBatch = ArrayList<PendingExportWork>(items.size)

        for (entry in items) {
            val taskId = "download:${UUID.randomUUID()}"
            val manifest = StagedDownloadManifest(
                taskId = taskId,
                accountHash = accountHash,
                trackId = entry.track.id,
                fileName = entry.track.name,
                relativeSubpath = entry.relativeSubpath,
                totalSize = entry.track.sizeBytes,
                partCount = partCount,
                state = "running",
                exportTreeUri = normalizedTreeUri
            )
            manifests[taskId] = manifest
            manifestAccountKeys[taskId] = accountId
            statusAccountHashes[taskId] = accountHash
            statuses[taskId] = TransferStatus(
                id = taskId,
                label = entry.track.name,
                kind = "download",
                state = "running",
                path = entry.relativeSubpath,
                canPause = true,
                canResume = false,
                canDelete = true,
                totalBytes = entry.track.sizeBytes.takeIf { it > 0L }
            )
            taskIds.add(taskId)
            workBatch.add(
                PendingExportWork(
                    taskId = taskId,
                    accountHash = accountHash,
                    accountKey = accountId,
                    stagingRootDir = stagingRootDir,
                    manifestsFile = manifestsFile,
                    exporter = exporter
                )
            )
        }

        persistManifests(accountHash, manifestsFile)
        notifyActivityChanged(force = true)
        pendingExports.addAll(workBatch)
        ensureExportPumpRunning()
        return taskIds
    }

    fun pauseTransfer(id: String, manifestsFile: File) {
        pendingExports.removeIf { it.taskId == id }
        jobs.remove(id)?.cancel()
        speedCounters.remove(id)
        val m = manifests[id] ?: return
        manifests[id] = m.copy(state = "paused")
        statusAccountHashes[id] = m.accountHash
        statuses[id]?.let {
            statuses[id] = it.copy(state = "paused", canPause = false, canResume = true, bytesPerSecond = 0L)
        }
        persistManifests(m.accountHash, manifestsFile)
        notifyActivityChanged(force = true)
    }

    fun resumeTransfer(
        id: String,
        stagingRootDir: File,
        manifestsFile: File,
        updatedExportTreeUri: String? = null,
        exporter: StagedFileExporter
    ) {
        val current = manifests[id] ?: return
        val nextTreeUri = updatedExportTreeUri?.takeIf { it.isNotBlank() } ?: current.exportTreeUri
        val m = current.copy(state = "running", exportTreeUri = nextTreeUri)
        val accountKey = manifestAccountKeys[id] ?: m.accountHash
        manifests[id] = m
        statusAccountHashes[id] = m.accountHash
        statuses[id]?.let {
            statuses[id] = it.copy(state = "running", canPause = true, canResume = false)
        }
        persistManifests(m.accountHash, manifestsFile)
        notifyActivityChanged(force = true)
        pendingExports.add(
            PendingExportWork(
                taskId = m.taskId,
                accountHash = m.accountHash,
                accountKey = accountKey,
                stagingRootDir = stagingRootDir,
                manifestsFile = manifestsFile,
                exporter = exporter
            )
        )
        ensureExportPumpRunning()
    }

    fun deleteTransfer(id: String, stagingRootDir: File, manifestsFile: File) {
        pendingExports.removeIf { it.taskId == id }
        jobs.remove(id)?.cancel()
        speedCounters.remove(id)
        val removedManifest = manifests.remove(id)
        manifestAccountKeys.remove(id)
        statuses.remove(id)
        statusAccountHashes.remove(id)
        val safe = Cloud189Protocol.sanitizeFileName(id)
        File(stagingRootDir, "$safe.parts").deleteRecursively()
        File(stagingRootDir, "$safe.merged").delete()
        if (removedManifest != null) {
            persistManifests(removedManifest.accountHash, manifestsFile)
        }
        notifyActivityChanged(force = true)
    }

    private fun ensureExportPumpRunning() {
        if (pendingExports.isEmpty()) return
        if (!exportPumpRunning.compareAndSet(false, true)) return
        scope.launch(Dispatchers.IO) {
            try {
                while (true) {
                    if (pendingExports.isEmpty()) break
                    exportTaskSemaphore.acquire()
                    val next = pendingExports.poll()
                    if (next == null) {
                        exportTaskSemaphore.release()
                        break
                    }
                    val activeManifest = manifests[next.taskId]
                    if (activeManifest == null || activeManifest.state != "running") {
                        exportTaskSemaphore.release()
                        continue
                    }
                    jobs.remove(next.taskId)?.cancel()
                    val permitReleased = java.util.concurrent.atomic.AtomicBoolean(false)
                    fun releaseExportPermitOnce() {
                        if (permitReleased.compareAndSet(false, true)) {
                            exportTaskSemaphore.release()
                            ensureExportPumpRunning()
                        }
                    }
                    var launchedRef: Job? = null
                    val taskJob = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                        runExportWorkflow(
                            manifest = activeManifest,
                            accountKey = next.accountKey,
                            stagingRootDir = next.stagingRootDir,
                            manifestsFile = next.manifestsFile,
                            exporter = next.exporter
                        )
                    }
                    launchedRef = taskJob
                    taskJob.invokeOnCompletion {
                        speedCounters.remove(next.taskId)
                        if (launchedRef != null) {
                            jobs.remove(next.taskId, launchedRef)
                        }
                        releaseExportPermitOnce()
                    }
                    jobs[next.taskId] = taskJob
                    val stillRunning = manifests[next.taskId]?.state == "running"
                    if (!stillRunning) {
                        jobs.remove(next.taskId, taskJob)
                        taskJob.cancel()
                        releaseExportPermitOnce()
                    } else if (!taskJob.start()) {
                        jobs.remove(next.taskId, taskJob)
                        releaseExportPermitOnce()
                    }
                }
            } finally {
                exportPumpRunning.set(false)
                if (pendingExports.isNotEmpty()) {
                    ensureExportPumpRunning()
                }
            }
        }
    }

    private suspend fun runExportWorkflow(
        manifest: StagedDownloadManifest,
        accountKey: String,
        stagingRootDir: File,
        manifestsFile: File,
        exporter: StagedFileExporter
    ) {
        val id = manifest.taskId
        val safe = Cloud189Protocol.sanitizeFileName(id)
        val partsDir = File(stagingRootDir, "$safe.parts").apply { mkdirs() }
        try {
            val remoteUrl = urlResolver(manifest.trackId)
            val (probedTotal, supportsRange) = probeTarget(remoteUrl, manifest.totalSize)
            val totalSize = maxOf(probedTotal, manifest.totalSize)
            val effectiveParts = if (supportsRange && totalSize >= 524_288L) manifest.partCount else 1

            if (!manifests.containsKey(id)) return
            val updatedManifest = manifest.copy(totalSize = totalSize, partCount = effectiveParts)
            manifests[id] = updatedManifest
            persistManifests(manifest.accountHash, manifestsFile)
            val resumedCompleted = completedBytesForManifest(updatedManifest, stagingRootDir)
            speedCounters[id] = TaskSpeedCounter(initialBytes = resumedCompleted, startNs = nanoClock())
            statuses.computeIfPresent(id) { _, prev ->
                prev.copy(
                    transferredBytes = resumedCompleted,
                    totalBytes = totalSize.takeIf { it > 0L }
                )
            }

            downloadParts(id, manifest.trackId, remoteUrl, totalSize, effectiveParts, partsDir)
            ensureActive()

            val orderedParts = (0 until effectiveParts.coerceAtLeast(1)).map { idx ->
                partFileForIndex(partsDir, idx)
            }
            var verifiedSum = 0L
            for (part in orderedParts) {
                if (!part.isFile) {
                    throw CloudTuneException("分片文件缺失：${part.name}")
                }
                verifiedSum += part.length()
            }
            if (totalSize > 0L && verifiedSum != totalSize) {
                throw CloudTuneException("分片总长度不匹配：$verifiedSum != $totalSize")
            }

            // Keep partsDir intact until export succeeds; stream ordered parts directly without staging .merged!
            val exportedDisplay = exporter.exportParts(
                partFiles = orderedParts,
                expectedTotalBytes = totalSize,
                relativeSubpath = updatedManifest.relativeSubpath,
                accountId = accountKey,
                exportTreeUri = updatedManifest.exportTreeUri
            )
            partsDir.deleteRecursively()

            if (!manifests.containsKey(id)) return
            manifests.remove(id)
            manifestAccountKeys.remove(id)
            speedCounters.remove(id)
            statusAccountHashes[id] = manifest.accountHash
            statuses[id] = TransferStatus(
                id = id,
                label = manifest.fileName,
                kind = "download",
                state = "completed",
                path = exportedDisplay,
                canPause = false,
                canResume = false,
                canDelete = true,
                bytesPerSecond = 0L,
                transferredBytes = totalSize,
                totalBytes = totalSize.takeIf { it > 0L }
            )
            persistManifests(manifest.accountHash, manifestsFile)
            notifyActivityChanged(force = true)
        } catch (ce: CancellationException) {
            throw ce
        } catch (err: Exception) {
            speedCounters.remove(id)
            if (manifests.containsKey(id)) {
                val latest = manifests[id] ?: manifest
                manifests[id] = latest.copy(state = "paused")
                persistManifests(manifest.accountHash, manifestsFile)
            }
            statusAccountHashes[id] = manifest.accountHash
            statuses[id]?.let {
                statuses[id] = it.copy(
                    state = "failed: ${err.message ?: "导出失败"}",
                    canPause = false,
                    canResume = true,
                    bytesPerSecond = 0L
                )
            }
            notifyActivityChanged(force = true)
        }
    }

    private suspend fun probeTarget(url: String, fallbackSize: Long): Pair<Long, Boolean> =
        withContext(Dispatchers.IO) {
            limiter.withPermit {
                val opened = opener.open(url, "bytes=0-0")
                try {
                    if (opened.statusCode != 200 && opened.statusCode != 206) {
                        throw CloudTuneException("探测媒体长度失败 (HTTP ${opened.statusCode})")
                    }
                    if (opened.statusCode == 206 && opened.headers["content-length"]?.trim() == "1") {
                        runCatching { while (opened.bodyStream.read() >= 0) { /* drain 1-byte probe for keep-alive */ } }
                    }
                    val total = RangeHeaderValidator.extractFullAssetLength(
                        statusCode = opened.statusCode,
                        requestHadRange = opened.statusCode == 206,
                        contentRangeHeader = opened.headers["content-range"],
                        contentLengthHeader = opened.headers["content-length"]
                    ) ?: fallbackSize
                    maxOf(total, fallbackSize) to (opened.statusCode == 206)
                } finally {
                    runCatching { opened.bodyStream.close(); opened.onClose() }
                }
            }
        }

    private suspend fun downloadParts(
        taskId: String,
        trackId: String,
        initialUrl: String,
        totalSize: Long,
        partCount: Int,
        partsDir: File
    ) = withContext(Dispatchers.IO) {
        coroutineScope {
            if (partCount <= 1 || totalSize <= 0L) {
                downloadPart(taskId, trackId, initialUrl, 0L, if (totalSize > 0L) totalSize - 1L else null, partFileForIndex(partsDir, 0))
            } else {
                val ranges = RangeHeaderValidator.splitByteRanges(totalSize, partCount)
                ranges.mapIndexed { idx, (start, endInclusive) ->
                    async(Dispatchers.IO) {
                        downloadPart(taskId, trackId, initialUrl, start, endInclusive, partFileForIndex(partsDir, idx))
                    }
                }.awaitAll()
            }
        }
    }

    private suspend fun downloadPart(
        taskId: String,
        trackId: String,
        initialUrl: String,
        start: Long,
        endInclusive: Long?,
        partFile: File
    ) = withContext(Dispatchers.IO) {
        val expectedLen = endInclusive?.let { it - start + 1L }
        var written = if (partFile.isFile) {
            expectedLen?.let { minOf(partFile.length(), it) } ?: 0L
        } else 0L
        if (expectedLen != null && written >= expectedLen) return@withContext

        var currentUrl = initialUrl
        var attempt = 0

        while (true) {
            ensureActive()
            if (expectedLen != null && written >= expectedLen) return@withContext
            val current = start + written
            val rangeSpec = if (current == 0L && endInclusive == null) null else ParsedByteRange(current, endInclusive).headerValue

            try {
                limiter.withPermit {
                    val opened = opener.open(currentUrl, rangeSpec)
                    try {
                        if (opened.statusCode in listOf(403, 404, 410)) {
                            currentUrl = urlResolver(trackId)
                            throw CloudTuneException("下载地址已刷新")
                        }
                        if (current > 0L) {
                            RangeHeaderValidator.validateResumeResponse(
                                expectedStartOffset = current,
                                statusCode = opened.statusCode,
                                contentRangeHeader = opened.headers["content-range"]
                            )
                        } else if (opened.statusCode != 200 && opened.statusCode != 206) {
                            throw CloudTuneException("分片请求失败 (HTTP ${opened.statusCode})")
                        }

                        RandomAccessFile(partFile, "rw").use { raf ->
                            raf.seek(written)
                            val buf = ByteArray(65_536)
                            while (true) {
                                ensureActive()
                                val n = opened.bodyStream.read(buf)
                                if (n < 0) break
                                if (n == 0) continue
                                val toWrite = if (expectedLen != null) {
                                    minOf(n.toLong(), expectedLen - written).toInt()
                                } else n
                                if (toWrite <= 0) break
                                raf.write(buf, 0, toWrite)
                                written += toWrite.toLong()
                                recordProgressDelta(taskId, toWrite.toLong())
                                // Only reset retry counter when > 0 bytes were actually read & written
                                attempt = 0
                                if (expectedLen != null && written >= expectedLen) {
                                    break
                                }
                            }
                            raf.fd.sync()
                        }
                    } finally {
                        runCatching { opened.bodyStream.close(); opened.onClose() }
                    }
                }
                if (expectedLen == null || written >= expectedLen) return@withContext
                // Premature EOF (-1) while current <= endInclusive: counts toward retry cap!
                throw IOException("上游分片提前 EOF (已读 $written / $expectedLen 字节)")
            } catch (ce: CancellationException) {
                throw ce
            } catch (err: Exception) {
                attempt += 1
                if (attempt > MAX_PART_RETRIES) throw err
                val backoff = retryDelayBaseMs.coerceAtLeast(0L) * attempt
                if (backoff > 0L) {
                    delay(backoff)
                }
            }
        }
    }

    private fun recordProgressDelta(taskId: String, delta: Long) {
        val nowNs = nanoClock()
        val counter = speedCounters[taskId]
        if (counter != null) {
            val (total, speed) = counter.addDelta(delta, nowNs)
            statuses.computeIfPresent(taskId) { _, prev ->
                val clamped = prev.totalBytes?.let { minOf(total, it) } ?: total
                prev.copy(transferredBytes = maxOf(prev.transferredBytes, clamped), bytesPerSecond = speed)
            }
        } else {
            statuses.computeIfPresent(taskId) { _, prev ->
                val nextTransferred = prev.totalBytes?.let { minOf(prev.transferredBytes + delta, it) }
                    ?: (prev.transferredBytes + delta)
                prev.copy(transferredBytes = nextTransferred)
            }
        }
    }

    private fun partFileForIndex(partsDir: File, idx: Int): File {
        val legacy = File(partsDir, String.format(Locale.US, "%02d.part", idx))
        if (legacy.isFile) return legacy
        return File(partsDir, String.format(Locale.US, "%04d.part", idx))
    }

    private suspend fun mergeParts(partsDir: File, partCount: Int, dest: File, expectedTotal: Long) =
        withContext(Dispatchers.IO) {
            dest.delete()
            var mergedBytes = 0L
            FileOutputStream(dest).use { out ->
                val buf = ByteArray(262_144)
                for (idx in 0 until partCount.coerceAtLeast(1)) {
                    val part = partFileForIndex(partsDir, idx)
                    FileInputStream(part).use { input ->
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            if (n > 0) {
                                out.write(buf, 0, n)
                                mergedBytes += n.toLong()
                            }
                        }
                    }
                }
                out.fd.sync()
            }
            if (expectedTotal > 0L && mergedBytes != expectedTotal) {
                throw CloudTuneException("分片合并长度不匹配：$mergedBytes != $expectedTotal")
            }
        }

    private fun completedBytesForManifest(manifest: StagedDownloadManifest, stagingRootDir: File): Long {
        val safe = Cloud189Protocol.sanitizeFileName(manifest.taskId)
        val partsDir = File(stagingRootDir, "$safe.parts")
        if (!partsDir.isDirectory) return 0L
        val ranges = if (manifest.partCount > 1 && manifest.totalSize > 0L) {
            RangeHeaderValidator.splitByteRanges(manifest.totalSize, manifest.partCount)
        } else {
            emptyList()
        }
        var sum = 0L
        for (idx in 0 until manifest.partCount.coerceAtLeast(1)) {
            val part = partFileForIndex(partsDir, idx)
            if (part.isFile) {
                val raw = part.length().coerceAtLeast(0L)
                val clamped = ranges.getOrNull(idx)?.let { (start, end) -> minOf(raw, end - start + 1L) } ?: raw
                sum += clamped
            }
        }
        return if (manifest.totalSize > 0L) minOf(sum, manifest.totalSize) else sum
    }

    private fun persistManifests(accountHash: String, manifestsFile: File) {
        synchronized(persistLock) {
            val arr = JSONArray()
            manifests.values.filter { it.accountHash == accountHash }.sortedBy { it.taskId }.forEach { m ->
                val obj = JSONObject()
                    .put("taskId", m.taskId)
                    .put("trackId", m.trackId)
                    .put("fileName", m.fileName)
                    .put("relativeSubpath", m.relativeSubpath)
                    .put("totalSize", m.totalSize)
                    .put("partCount", m.partCount)
                    .put("state", m.state)
                if (!m.exportTreeUri.isNullOrEmpty()) {
                    obj.put("exportTreeUri", m.exportTreeUri)
                }
                arr.put(obj)
            }
            AtomicFileIO.writeText(manifestsFile, arr.toString())
        }
    }

    companion object {
        const val MAX_PART_RETRIES = 4
        const val MAX_CONCURRENT_EXPORT_JOBS = 4
        private const val SPEED_SAMPLE_WINDOW_NS = 200_000_000L
    }
}
