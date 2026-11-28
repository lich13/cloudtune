package com.gosu.cloudtune.core

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
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
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

fun interface StagedFileExporter {
    suspend fun export(
        stagedFile: File,
        relativeSubpath: String,
        accountId: String,
        exportTreeUri: String?
    ): String
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

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val persistLock = Any()
    private val cacheDownloadLock = Any()
    private val notifyLock = Any()
    private val statuses = ConcurrentHashMap<String, TransferStatus>()
    private val statusAccountHashes = ConcurrentHashMap<String, String>()
    private val manifests = ConcurrentHashMap<String, StagedDownloadManifest>()
    private val manifestAccountKeys = ConcurrentHashMap<String, String>()
    private val jobs = ConcurrentHashMap<String, Job>()
    private val inFlightCacheDownloads = HashMap<String, InFlightCacheDownload>()
    @Volatile private var onActivityChange: ((TransferSnapshotPayload, Boolean) -> Unit)? = onActivityChangeInitial
    private var lastNotifiedHasActive: Boolean = false

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
        val rawText = synchronized(persistLock) {
            if (!manifestsFile.isFile) return
            runCatching { manifestsFile.readText(Charsets.UTF_8) }.getOrNull()
        } ?: return

        runCatching {
            val arr = JSONArray(rawText)
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val savedHash = o.optString("accountHash").trim()
                val legacyAccountId = o.optString("accountId").trim()
                if (savedHash.isNotEmpty() && savedHash != targetHash) continue
                if (legacyAccountId.isNotEmpty() && Cloud189Protocol.accountBucketHash(legacyAccountId) != targetHash) continue

                val rawState = o.optString("state", "paused")
                val restoredState = if (rawState == "running") "paused" else rawState
                val manifest = StagedDownloadManifest(
                    taskId = o.getString("taskId"),
                    accountHash = targetHash,
                    trackId = o.getString("trackId"),
                    fileName = o.getString("fileName"),
                    relativeSubpath = o.optString("relativeSubpath", o.getString("fileName")),
                    totalSize = o.optLong("totalSize", 0L),
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
        notifyActivityChanged(force = true)
    }

    fun cancelAll(accountId: String) {
        val targetHash = Cloud189Protocol.accountBucketHash(accountId)
        for ((id, m) in manifests.entries.toList()) {
            if (m.accountHash == targetHash) {
                jobs.remove(id)?.cancel()
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
            statuses.remove(entry.statusId)
            statusAccountHashes.remove(entry.statusId)
        }
        for ((id, ownerHash) in statusAccountHashes.entries.toList()) {
            if (ownerHash == targetHash) {
                jobs.remove(id)?.cancel()
                statuses.remove(id)
                statusAccountHashes.remove(id)
            }
        }
        for (key in statuses.keys().toList()) {
            if (key.startsWith("stream:") || key.startsWith("prefetch:") || key.startsWith("playback:")) {
                val owner = statusAccountHashes[key]
                if (owner == null || owner == targetHash) {
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
        try {
            val remoteUrl = urlResolver(track.id)
            val probe = probeTarget(remoteUrl, track.sizeBytes)
            val totalSize = probe.first
            val supportsRange = probe.second
            val parts = if (supportsRange && totalSize >= 1_048_576L) parallelThreads.coerceIn(1, 8) else 1

            partsDir.deleteRecursively()
            partsDir.mkdirs()
            downloadParts(statusId, track.id, remoteUrl, totalSize, parts, partsDir)
            ensureActive()
            mergeParts(partsDir, parts, mergedTmp, totalSize)
            moveOrCopyAtomically(mergedTmp, dest)
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
        val taskId = "download:${UUID.randomUUID()}"
        val partCount = parallelThreads.coerceIn(1, 16)
        val accountHash = Cloud189Protocol.accountBucketHash(accountId)
        val manifest = StagedDownloadManifest(
            taskId = taskId,
            accountHash = accountHash,
            trackId = track.id,
            fileName = track.name,
            relativeSubpath = relativeSubpath,
            totalSize = track.sizeBytes,
            partCount = partCount,
            state = "running",
            exportTreeUri = exportTreeUri?.takeIf { it.isNotBlank() }
        )
        manifests[taskId] = manifest
        manifestAccountKeys[taskId] = accountId
        statusAccountHashes[taskId] = accountHash
        statuses[taskId] = TransferStatus(
            id = taskId,
            label = track.name,
            kind = "download",
            state = "running",
            path = relativeSubpath,
            canPause = true,
            canResume = false,
            canDelete = true,
            totalBytes = track.sizeBytes.takeIf { it > 0L }
        )
        persistManifests(accountHash, manifestsFile)
        notifyActivityChanged(force = true)
        spawnExportJob(manifest, accountId, stagingRootDir, manifestsFile, exporter)
        return taskId
    }

    fun pauseTransfer(id: String, manifestsFile: File) {
        jobs.remove(id)?.cancel()
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
        exporter: StagedFileExporter
    ) {
        val m = manifests[id]?.copy(state = "running") ?: return
        val accountKey = manifestAccountKeys[id] ?: m.accountHash
        manifests[id] = m
        statusAccountHashes[id] = m.accountHash
        statuses[id]?.let {
            statuses[id] = it.copy(state = "running", canPause = true, canResume = false)
        }
        persistManifests(m.accountHash, manifestsFile)
        notifyActivityChanged(force = true)
        spawnExportJob(m, accountKey, stagingRootDir, manifestsFile, exporter)
    }

    fun deleteTransfer(id: String, stagingRootDir: File, manifestsFile: File) {
        jobs.remove(id)?.cancel()
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

    private fun spawnExportJob(
        manifest: StagedDownloadManifest,
        accountKey: String,
        stagingRootDir: File,
        manifestsFile: File,
        exporter: StagedFileExporter
    ) {
        jobs.remove(manifest.taskId)?.cancel()
        jobs[manifest.taskId] = scope.launch(Dispatchers.IO) {
            val id = manifest.taskId
            val safe = Cloud189Protocol.sanitizeFileName(id)
            val partsDir = File(stagingRootDir, "$safe.parts").apply { mkdirs() }
            val mergedFile = File(stagingRootDir, "$safe.merged")
            try {
                val remoteUrl = urlResolver(manifest.trackId)
                val (probedTotal, supportsRange) = probeTarget(remoteUrl, manifest.totalSize)
                val totalSize = maxOf(probedTotal, manifest.totalSize)
                val effectiveParts = if (supportsRange && totalSize >= 524_288L) manifest.partCount else 1

                if (!manifests.containsKey(id)) return@launch
                val updatedManifest = manifest.copy(totalSize = totalSize, partCount = effectiveParts)
                manifests[id] = updatedManifest
                persistManifests(manifest.accountHash, manifestsFile)
                val resumedCompleted = completedBytesForManifest(updatedManifest, stagingRootDir)
                statuses.computeIfPresent(id) { _, prev ->
                    prev.copy(
                        transferredBytes = resumedCompleted,
                        totalBytes = totalSize.takeIf { it > 0L }
                    )
                }

                downloadParts(id, manifest.trackId, remoteUrl, totalSize, effectiveParts, partsDir)
                ensureActive()
                mergeParts(partsDir, effectiveParts, mergedFile, totalSize)
                val exportedDisplay = exporter.export(
                    mergedFile,
                    updatedManifest.relativeSubpath,
                    accountKey,
                    updatedManifest.exportTreeUri
                )

                mergedFile.delete()
                partsDir.deleteRecursively()
                if (!manifests.containsKey(id)) return@launch
                manifests.remove(id)
                manifestAccountKeys.remove(id)
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
                    transferredBytes = totalSize,
                    totalBytes = totalSize.takeIf { it > 0L }
                )
                persistManifests(manifest.accountHash, manifestsFile)
                notifyActivityChanged(force = true)
            } catch (ce: CancellationException) {
                throw ce
            } catch (err: Exception) {
                if (manifests.containsKey(id)) {
                    manifests[id] = manifest.copy(state = "paused")
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
    }

    private suspend fun probeTarget(url: String, fallbackSize: Long): Pair<Long, Boolean> =
        withContext(Dispatchers.IO) {
            limiter.withPermit {
                val opened = opener.open(url, "bytes=0-0")
                try {
                    if (opened.statusCode != 200 && opened.statusCode != 206) {
                        throw CloudTuneException("探测媒体长度失败 (HTTP ${opened.statusCode})")
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
                downloadSingleRange(taskId, trackId, initialUrl, 0L, if (totalSize > 0L) totalSize - 1L else null, File(partsDir, "00.part"))
            } else {
                val ranges = RangeHeaderValidator.splitByteRanges(totalSize, partCount)
                ranges.mapIndexed { idx, (start, end) ->
                    async(Dispatchers.IO) {
                        downloadSingleRange(taskId, trackId, initialUrl, start, end, File(partsDir, "%02d.part".format(Locale.US, idx)))
                    }
                }.awaitAll()
            }
        }
    }

    private suspend fun downloadSingleRange(
        taskId: String,
        trackId: String,
        initialUrl: String,
        start: Long,
        end: Long?,
        partFile: File
    ) = withContext(Dispatchers.IO) {
        val expectedLen = end?.let { it - start + 1L }
        var written = if (partFile.isFile) {
            expectedLen?.let { minOf(partFile.length(), it) } ?: 0L
        } else 0L
        if (expectedLen != null && written >= expectedLen) return@withContext

        var currentUrl = initialUrl
        var attempt = 0

        while (true) {
            ensureActive()
            if (expectedLen != null && written >= expectedLen) return@withContext
            val reqStart = start + written
            val rangeSpec = if (reqStart == 0L && end == null) null else ParsedByteRange(reqStart, end).headerValue

            try {
                limiter.withPermit {
                    val opened = opener.open(currentUrl, rangeSpec)
                    try {
                        if (opened.statusCode in listOf(403, 404, 410)) {
                            currentUrl = urlResolver(trackId)
                            throw CloudTuneException("下载地址已刷新")
                        }
                        if (reqStart > 0L) {
                            RangeHeaderValidator.validateResumeResponse(
                                expectedStartOffset = reqStart,
                                statusCode = opened.statusCode,
                                contentRangeHeader = opened.headers["content-range"]
                            )
                        } else if (opened.statusCode != 200 && opened.statusCode != 206) {
                            throw CloudTuneException("分片请求失败 (HTTP ${opened.statusCode})")
                        }

                        RandomAccessFile(partFile, "rw").use { raf ->
                            raf.seek(written)
                            val buf = ByteArray(32_768)
                            var windowBytes = 0L
                            var windowStartNs = System.nanoTime()
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
                                windowBytes += toWrite.toLong()
                                val elapsedMs = (System.nanoTime() - windowStartNs) / 1_000_000L
                                if (elapsedMs >= 300L) {
                                    val speed = (windowBytes * 1000L) / elapsedMs.coerceAtLeast(1L)
                                    recordProgress(taskId, windowBytes, speed)
                                    windowBytes = 0L
                                    windowStartNs = System.nanoTime()
                                }
                            }
                            if (windowBytes > 0L) recordProgress(taskId, windowBytes, windowBytes)
                        }
                    } finally {
                        runCatching { opened.bodyStream.close(); opened.onClose() }
                    }
                }
                if (expectedLen == null || written >= expectedLen) return@withContext
            } catch (ce: CancellationException) {
                throw ce
            } catch (err: Exception) {
                attempt += 1
                if (attempt >= 5) throw err
                delay(250L * attempt)
            }
        }
    }

    private fun recordProgress(taskId: String, delta: Long, speed: Long) {
        statuses.computeIfPresent(taskId) { _, prev ->
            val nextTransferred = prev.totalBytes?.let { minOf(prev.transferredBytes + delta, it) }
                ?: (prev.transferredBytes + delta)
            prev.copy(transferredBytes = nextTransferred, bytesPerSecond = speed)
        }
    }

    private suspend fun mergeParts(partsDir: File, partCount: Int, dest: File, expectedTotal: Long) =
        withContext(Dispatchers.IO) {
            dest.delete()
            var mergedBytes = 0L
            FileOutputStream(dest).use { out ->
                val buf = ByteArray(262_144)
                for (idx in 0 until partCount.coerceAtLeast(1)) {
                    val part = File(partsDir, "%02d.part".format(Locale.US, idx))
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

    private fun moveOrCopyAtomically(source: File, destination: File) {
        try {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE
            )
        } catch (_: AtomicMoveNotSupportedException) {
            try {
                Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
            } catch (_: Exception) {
                source.copyTo(destination, overwrite = true)
                source.delete()
            }
        } catch (_: Exception) {
            source.copyTo(destination, overwrite = true)
            source.delete()
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
            val part = File(partsDir, "%02d.part".format(Locale.US, idx))
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
            val parent = manifestsFile.parentFile
            parent?.mkdirs()
            val bytes = arr.toString().toByteArray(Charsets.UTF_8)
            val tmpFile = File(parent ?: File("."), ".${manifestsFile.name}.${UUID.randomUUID()}.tmp")
            try {
                FileOutputStream(tmpFile).use { out ->
                    out.write(bytes)
                    out.fd.sync()
                }
                moveOrCopyAtomically(tmpFile, manifestsFile)
            } finally {
                if (tmpFile.exists()) {
                    tmpFile.delete()
                }
            }
        }
    }
}
