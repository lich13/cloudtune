package com.gosu.cloudtune.core

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

fun interface StagedFileExporter {
    suspend fun export(stagedFile: File, relativeSubpath: String, accountId: String): String
}

data class StagedDownloadManifest(
    val taskId: String,
    val accountId: String,
    val trackId: String,
    val fileName: String,
    val relativeSubpath: String,
    val totalSize: Long,
    val partCount: Int,
    val state: String
)

class TransferEngine(
    private val limiter: GlobalTransferLimiter,
    private val opener: UpstreamStreamOpener = HttpUrlConnectionStreamOpener(),
    private val urlResolver: suspend (String) -> String
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val statuses = ConcurrentHashMap<String, TransferStatus>()
    private val manifests = ConcurrentHashMap<String, StagedDownloadManifest>()
    private val jobs = ConcurrentHashMap<String, Job>()

    fun snapshot(): TransferSnapshotPayload {
        val list = statuses.values.sortedBy { it.id }
        val speed = list.filter { it.state == "running" || it.state == "streaming" }
            .sumOf { it.bytesPerSecond }
        return TransferSnapshotPayload(speed, list)
    }

    fun updateExternalTransferStatus(id: String, status: TransferStatus?) {
        if (status != null) {
            statuses[id] = status
        } else {
            statuses.remove(id)
        }
    }

    fun restorePersistedDownloads(accountId: String, stagingRootDir: File, manifestsFile: File) {
        if (!manifestsFile.isFile) return
        runCatching {
            val arr = JSONArray(manifestsFile.readText(Charsets.UTF_8))
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val itemAccountId = o.optString("accountId")
                if (itemAccountId.isNotEmpty() && itemAccountId != accountId) continue
                val rawState = o.optString("state", "paused")
                val restoredState = if (rawState == "running") "paused" else rawState
                val manifest = StagedDownloadManifest(
                    taskId = o.getString("taskId"),
                    accountId = accountId,
                    trackId = o.getString("trackId"),
                    fileName = o.getString("fileName"),
                    relativeSubpath = o.optString("relativeSubpath", o.getString("fileName")),
                    totalSize = o.optLong("totalSize", 0L),
                    partCount = o.optInt("partCount", 1).coerceAtLeast(1),
                    state = restoredState
                )
                manifests[manifest.taskId] = manifest
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

    fun cancelAll(accountId: String) {
        for ((id, m) in manifests) {
            if (m.accountId == accountId) {
                jobs.remove(id)?.cancel()
                statuses.remove(id)
                manifests.remove(id)
            }
        }
        for (key in statuses.keys().toList()) {
            if (key.startsWith("stream:") || key.startsWith("prefetch:") || key.startsWith("playback:")) {
                statuses.remove(key)
            }
        }
    }

    suspend fun downloadTrackToCache(
        track: TrackSummary,
        cacheManager: CacheManager,
        parallelThreads: Int,
        cacheLimitBytes: Long,
        kind: String = "playback"
    ): File {
        cacheManager.existingCachedFile(track.id)?.let { return it }
        val dest = cacheManager.cacheFile(track.id, track.name)
        val partsDir = File(dest.parentFile, "${dest.name}.parts")
        val mergedTmp = File(dest.parentFile, "${dest.name}.part")
        val taskId = "$kind:${track.id}"

        statuses[taskId] = TransferStatus(
            id = taskId,
            label = track.name,
            kind = kind,
            state = "running",
            totalBytes = track.sizeBytes.takeIf { it > 0L }
        )

        try {
            val remoteUrl = urlResolver(track.id)
            val probe = probeTarget(remoteUrl, track.sizeBytes)
            val totalSize = probe.first
            val supportsRange = probe.second
            val parts = if (supportsRange && totalSize >= 1_048_576L) parallelThreads.coerceIn(1, 8) else 1

            partsDir.mkdirs()
            downloadParts(taskId, track.id, remoteUrl, totalSize, parts, partsDir)
            mergeParts(partsDir, parts, mergedTmp, totalSize)
            dest.delete()
            if (!mergedTmp.renameTo(dest)) {
                mergedTmp.copyTo(dest, overwrite = true)
            }
            cacheManager.recordCompletedFile(
                trackId = track.id,
                file = dest,
                sizeBytes = if (totalSize > 0L) totalSize else dest.length(),
                limitBytes = cacheLimitBytes
            )
            return dest
        } finally {
            statuses.remove(taskId)
            partsDir.deleteRecursively()
            mergedTmp.delete()
        }
    }

    fun enqueueExportDownload(
        accountId: String,
        track: TrackSummary,
        relativeSubpath: String,
        parallelThreads: Int,
        stagingRootDir: File,
        manifestsFile: File,
        exporter: StagedFileExporter
    ): String {
        val taskId = "download:${UUID.randomUUID()}"
        val partCount = parallelThreads.coerceIn(1, 16)
        val manifest = StagedDownloadManifest(
            taskId = taskId,
            accountId = accountId,
            trackId = track.id,
            fileName = track.name,
            relativeSubpath = relativeSubpath,
            totalSize = track.sizeBytes,
            partCount = partCount,
            state = "running"
        )
        manifests[taskId] = manifest
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
        persistManifests(accountId, manifestsFile)
        spawnExportJob(manifest, stagingRootDir, manifestsFile, exporter)
        return taskId
    }

    fun pauseTransfer(id: String, manifestsFile: File) {
        jobs.remove(id)?.cancel()
        val m = manifests[id] ?: return
        manifests[id] = m.copy(state = "paused")
        statuses[id]?.let {
            statuses[id] = it.copy(state = "paused", canPause = false, canResume = true, bytesPerSecond = 0L)
        }
        persistManifests(m.accountId, manifestsFile)
    }

    fun resumeTransfer(
        id: String,
        stagingRootDir: File,
        manifestsFile: File,
        exporter: StagedFileExporter
    ) {
        val m = manifests[id]?.copy(state = "running") ?: return
        manifests[id] = m
        statuses[id]?.let {
            statuses[id] = it.copy(state = "running", canPause = true, canResume = false)
        }
        persistManifests(m.accountId, manifestsFile)
        spawnExportJob(m, stagingRootDir, manifestsFile, exporter)
    }

    fun deleteTransfer(id: String, stagingRootDir: File, manifestsFile: File) {
        jobs.remove(id)?.cancel()
        val accountId = manifests.remove(id)?.accountId
        statuses.remove(id)
        val safe = Cloud189Protocol.sanitizeFileName(id)
        File(stagingRootDir, "$safe.parts").deleteRecursively()
        File(stagingRootDir, "$safe.merged").delete()
        if (accountId != null) persistManifests(accountId, manifestsFile)
    }

    private fun spawnExportJob(
        manifest: StagedDownloadManifest,
        stagingRootDir: File,
        manifestsFile: File,
        exporter: StagedFileExporter
    ) {
        jobs.remove(manifest.taskId)?.cancel()
        jobs[manifest.taskId] = scope.launch {
            val id = manifest.taskId
            val safe = Cloud189Protocol.sanitizeFileName(id)
            val partsDir = File(stagingRootDir, "$safe.parts").apply { mkdirs() }
            val mergedFile = File(stagingRootDir, "$safe.merged")
            try {
                val remoteUrl = urlResolver(manifest.trackId)
                val (probedTotal, supportsRange) = probeTarget(remoteUrl, manifest.totalSize)
                val totalSize = maxOf(probedTotal, manifest.totalSize)
                val effectiveParts = if (supportsRange && totalSize >= 524_288L) manifest.partCount else 1

                val updatedManifest = manifest.copy(totalSize = totalSize, partCount = effectiveParts)
                manifests[id] = updatedManifest
                persistManifests(manifest.accountId, manifestsFile)
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
                val exportedDisplay = exporter.export(mergedFile, manifest.relativeSubpath, manifest.accountId)

                mergedFile.delete()
                partsDir.deleteRecursively()
                manifests.remove(id)
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
                persistManifests(manifest.accountId, manifestsFile)
            } catch (ce: CancellationException) {
                throw ce
            } catch (err: Exception) {
                manifests[id] = manifest.copy(state = "paused")
                persistManifests(manifest.accountId, manifestsFile)
                statuses[id]?.let {
                    statuses[id] = it.copy(
                        state = "failed: ${err.message ?: "导出失败"}",
                        canPause = false,
                        canResume = true,
                        bytesPerSecond = 0L
                    )
                }
            }
        }
    }

    private suspend fun probeTarget(url: String, fallbackSize: Long): Pair<Long, Boolean> =
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

    private suspend fun downloadParts(
        taskId: String,
        trackId: String,
        initialUrl: String,
        totalSize: Long,
        partCount: Int,
        partsDir: File
    ) = coroutineScope {
        if (partCount <= 1 || totalSize <= 0L) {
            downloadSingleRange(taskId, trackId, initialUrl, 0L, if (totalSize > 0L) totalSize - 1L else null, File(partsDir, "00.part"))
        } else {
            val ranges = RangeHeaderValidator.splitByteRanges(totalSize, partCount)
            ranges.mapIndexed { idx, (start, end) ->
                async {
                    downloadSingleRange(taskId, trackId, initialUrl, start, end, File(partsDir, "%02d.part".format(java.util.Locale.US, idx)))
                }
            }.awaitAll()
        }
    }

    private suspend fun downloadSingleRange(
        taskId: String,
        trackId: String,
        initialUrl: String,
        start: Long,
        end: Long?,
        partFile: File
    ) = coroutineScope {
        val expectedLen = end?.let { it - start + 1L }
        var written = if (partFile.isFile) {
            expectedLen?.let { minOf(partFile.length(), it) } ?: 0L
        } else 0L
        if (expectedLen != null && written >= expectedLen) return@coroutineScope

        var currentUrl = initialUrl
        var attempt = 0

        while (true) {
            ensureActive()
            if (expectedLen != null && written >= expectedLen) return@coroutineScope
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
                if (expectedLen == null || written >= expectedLen) return@coroutineScope
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

    private fun mergeParts(partsDir: File, partCount: Int, dest: File, expectedTotal: Long) {
        dest.delete()
        var mergedBytes = 0L
        FileOutputStream(dest).use { out ->
            val buf = ByteArray(262_144)
            for (idx in 0 until partCount.coerceAtLeast(1)) {
                val part = File(partsDir, "%02d.part".format(java.util.Locale.US, idx))
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
            val part = File(partsDir, "%02d.part".format(java.util.Locale.US, idx))
            if (part.isFile) {
                val raw = part.length().coerceAtLeast(0L)
                val clamped = ranges.getOrNull(idx)?.let { (start, end) -> minOf(raw, end - start + 1L) } ?: raw
                sum += clamped
            }
        }
        return if (manifest.totalSize > 0L) minOf(sum, manifest.totalSize) else sum
    }

    private fun persistManifests(accountId: String, manifestsFile: File) {
        val arr = JSONArray()
        manifests.values.filter { it.accountId == accountId }.sortedBy { it.taskId }.forEach { m ->
            arr.put(
                JSONObject()
                    .put("taskId", m.taskId)
                    .put("accountId", m.accountId)
                    .put("trackId", m.trackId)
                    .put("fileName", m.fileName)
                    .put("relativeSubpath", m.relativeSubpath)
                    .put("totalSize", m.totalSize)
                    .put("partCount", m.partCount)
                    .put("state", m.state)
            )
        }
        manifestsFile.parentFile?.mkdirs()
        manifestsFile.writeText(arr.toString(), Charsets.UTF_8)
    }
}
