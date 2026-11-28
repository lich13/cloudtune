package com.gosu.cloudtune.core

import java.io.File
import org.json.JSONObject

data class CacheEntry(
    val fileName: String,
    val sizeBytes: Long,
    val lastAccessedMs: Long
)

class CacheManager(
    val cacheDir: File,
    val indexFile: File = File(cacheDir, "index.json"),
    private val clockMs: () -> Long = { System.currentTimeMillis() }
) {
    private val lock = Any()
    private val entries = mutableMapOf<String, CacheEntry>()
    private val protectedTrackIds = mutableSetOf<String>()
    private val activeWriters = mutableSetOf<String>()
    private var totalBytes: Long = 0L
    private var indexDirty: Boolean = false
    private var dirtyHits: Int = 0
    private var lastFlushMs: Long = clockMs()
    private var rebuiltFromCorruptIndex: Boolean = false

    init {
        cacheDir.mkdirs()
        synchronized(lock) {
            if (indexFile.isFile) {
                var hadMissingOrStale = false
                val parsedOk = runCatching {
                    val root = JSONObject(indexFile.readText(Charsets.UTF_8))
                    for (key in root.keys()) {
                        val obj = root.getJSONObject(key)
                        val fileName = obj.getString("fileName")
                        val file = File(cacheDir, fileName)
                        val actualSize = if (file.isFile) file.length() else 0L
                        if (actualSize > 0L) {
                            val recordedSize = obj.getLong("sizeBytes")
                            if (recordedSize != actualSize) hadMissingOrStale = true
                            entries[key] = CacheEntry(
                                fileName = fileName,
                                sizeBytes = actualSize,
                                lastAccessedMs = obj.getLong("lastAccessedMs")
                            )
                        } else {
                            hadMissingOrStale = true
                        }
                    }
                    true
                }.getOrDefault(false)

                if (!parsedOk) {
                    entries.clear()
                    rebuildEntriesFromDiskLocked()
                    rebuiltFromCorruptIndex = true
                    cleanupOrphanedFiles()
                    recomputeTotalBytesLocked()
                    persistIndexLocked()
                } else {
                    cleanupOrphanedFiles()
                    recomputeTotalBytesLocked()
                    if (hadMissingOrStale) {
                        persistIndexLocked()
                    }
                }
            } else {
                cleanupOrphanedFiles()
                recomputeTotalBytesLocked()
            }
        }
    }

    fun beginWriteThroughIfIdle(trackId: String): Boolean = synchronized(lock) {
        if (activeWriters.contains(trackId)) return false
        activeWriters.add(trackId)
        true
    }

    fun finishWriteThrough(trackId: String) {
        synchronized(lock) {
            activeWriters.remove(trackId)
            Unit
        }
    }

    fun setProtectedTrackIds(ids: Set<String>) {
        synchronized(lock) {
            protectedTrackIds.clear()
            protectedTrackIds.addAll(ids)
            Unit
        }
    }

    fun cacheFile(trackId: String, originalFileName: String): File =
        File(cacheDir, "$trackId-${Cloud189Protocol.sanitizeFileName(originalFileName)}")

    fun existingCachedFile(trackId: String): File? = synchronized(lock) {
        var resolvedKey = trackId
        var entry = entries[trackId]
        if (entry == null && rebuiltFromCorruptIndex) {
            val prefix = "$trackId-"
            val match = entries.entries.firstOrNull { (_, v) -> v.fileName.startsWith(prefix) }
            if (match != null) {
                resolvedKey = match.key
                entry = match.value
            }
        }
        val found = entry ?: return null
        val file = File(cacheDir, found.fileName)
        val actualLen = if (file.isFile) file.length() else 0L
        if (actualLen <= 0L) {
            val removed = entries.remove(resolvedKey)
            if (removed != null) {
                totalBytes = (totalBytes - removed.sizeBytes).coerceAtLeast(0L)
            }
            persistIndexLocked()
            return null
        }
        val now = clockMs()
        if (resolvedKey != trackId) {
            entries.remove(resolvedKey)
        }
        if (actualLen != found.sizeBytes) {
            totalBytes = (totalBytes - found.sizeBytes + actualLen).coerceAtLeast(0L)
        }
        entries[trackId] = found.copy(
            sizeBytes = actualLen,
            lastAccessedMs = now
        )
        indexDirty = true
        dirtyHits += 1
        if (dirtyHits >= DIRTY_FLUSH_HITS || (now - lastFlushMs) >= DIRTY_FLUSH_INTERVAL_MS) {
            persistIndexLocked(now)
        }
        file
    }

    fun recordCompletedFile(
        trackId: String,
        file: File,
        sizeBytes: Long,
        limitBytes: Long
    ): Long = synchronized(lock) {
        val effectiveSize = if (sizeBytes > 0L) sizeBytes else file.takeIf(File::isFile)?.length()?.coerceAtLeast(0L) ?: 0L
        val prev = entries.put(
            trackId,
            CacheEntry(
                fileName = file.name,
                sizeBytes = effectiveSize,
                lastAccessedMs = clockMs()
            )
        )
        if (prev != null) {
            totalBytes = (totalBytes - prev.sizeBytes).coerceAtLeast(0L)
            if (prev.fileName != file.name) {
                File(cacheDir, prev.fileName).delete()
            }
        }
        totalBytes += effectiveSize
        val usage = evictIfNeededLocked(limitBytes, setOf(trackId))
        persistIndexLocked()
        usage
    }

    fun usageBytes(): Long = synchronized(lock) {
        totalBytes
    }

    fun pruneToLimit(limitBytes: Long, extraProtected: Set<String> = emptySet()): Long = synchronized(lock) {
        val usage = evictIfNeededLocked(limitBytes, extraProtected)
        persistIndexLocked()
        usage
    }

    fun evictIfNeeded(limitBytes: Long, extraProtected: Set<String> = emptySet()): Long =
        pruneToLimit(limitBytes, extraProtected)

    fun clearAll() {
        synchronized(lock) {
            for ((trackId, entry) in entries.entries.toList()) {
                if (trackId in activeWriters) continue
                File(cacheDir, entry.fileName).delete()
                entries.remove(trackId)
            }
            recomputeTotalBytesLocked()
            cleanupOrphanedFiles()
            persistIndexLocked()
        }
    }

    fun flushIndexIfDirty() {
        synchronized(lock) {
            if (indexDirty) {
                persistIndexLocked()
            }
        }
    }

    private fun evictIfNeededLocked(limitBytes: Long, extraProtected: Set<String>): Long {
        if (totalBytes <= limitBytes) return totalBytes
        val protectedAll = protectedTrackIds + extraProtected
        val sorted = entries.entries.sortedBy { it.value.lastAccessedMs }
        for ((trackId, entry) in sorted) {
            if (totalBytes <= limitBytes) break
            if (trackId in protectedAll || trackId in activeWriters) continue
            File(cacheDir, entry.fileName).delete()
            if (entries.remove(trackId) != null) {
                totalBytes = (totalBytes - entry.sizeBytes).coerceAtLeast(0L)
            }
        }
        return totalBytes
    }

    private fun rebuildEntriesFromDiskLocked() {
        val children = cacheDir.listFiles()?.sortedBy { it.name } ?: return
        for (child in children) {
            val name = child.name
            if (!child.isFile || name == indexFile.name || name.startsWith(".")) continue
            if (name.endsWith(".part") || name.endsWith(".parts") || name.endsWith(".tmp")) continue
            val len = child.length()
            if (len <= 0L) continue
            var dash = name.indexOf('-')
            if (dash <= 0 || dash >= name.lastIndex) continue
            var inferredId = name.substring(0, dash)
            while (entries.containsKey(inferredId)) {
                val nextDash = name.indexOf('-', dash + 1)
                if (nextDash <= 0 || nextDash >= name.lastIndex) {
                    inferredId = "$inferredId#${entries.size}"
                    break
                }
                dash = nextDash
                inferredId = name.substring(0, dash)
            }
            entries[inferredId] = CacheEntry(
                fileName = name,
                sizeBytes = len,
                lastAccessedMs = child.lastModified().coerceAtLeast(0L)
            )
        }
    }

    private fun recomputeTotalBytesLocked() {
        var sum = 0L
        for (entry in entries.values) {
            sum += entry.sizeBytes.coerceAtLeast(0L)
        }
        totalBytes = sum
    }

    private fun cleanupOrphanedFiles() {
        val valid = entries.values.map { it.fileName }.toSet()
        val children = cacheDir.listFiles() ?: return
        for (child in children) {
            if (child.name == indexFile.name || child.name in valid) continue
            if (child.name.endsWith(".part") || child.name.endsWith(".parts") || child.name.endsWith(".tmp")) {
                child.deleteRecursively()
            }
        }
    }

    private fun persistIndexLocked(nowMs: Long = clockMs()) {
        val root = JSONObject()
        for ((k, v) in entries) {
            root.put(
                k,
                JSONObject()
                    .put("fileName", v.fileName)
                    .put("sizeBytes", v.sizeBytes)
                    .put("lastAccessedMs", v.lastAccessedMs)
            )
        }
        AtomicFileIO.writeText(indexFile, root.toString())
        indexDirty = false
        dirtyHits = 0
        lastFlushMs = nowMs
    }

    companion object {
        const val DIRTY_FLUSH_HITS = 16
        const val DIRTY_FLUSH_INTERVAL_MS = 5_000L
    }
}
