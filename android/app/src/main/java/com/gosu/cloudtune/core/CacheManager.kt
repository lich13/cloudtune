package com.gosu.cloudtune.core

import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import org.json.JSONObject

data class CacheEntry(
    val fileName: String,
    val sizeBytes: Long,
    val lastAccessedMs: Long
)

class CacheManager(
    val cacheDir: File,
    val indexFile: File = File(cacheDir, "index.json")
) {
    private val lock = Any()
    private val entries = mutableMapOf<String, CacheEntry>()
    private val protectedTrackIds = mutableSetOf<String>()
    private val activeWriters = mutableSetOf<String>()

    init {
        cacheDir.mkdirs()
        if (indexFile.isFile) {
            runCatching {
                val root = JSONObject(indexFile.readText(Charsets.UTF_8))
                for (key in root.keys()) {
                    val obj = root.getJSONObject(key)
                    entries[key] = CacheEntry(
                        fileName = obj.getString("fileName"),
                        sizeBytes = obj.getLong("sizeBytes"),
                        lastAccessedMs = obj.getLong("lastAccessedMs")
                    )
                }
            }
        }
        cleanupOrphanedFiles()
    }

    fun beginWriteThroughIfIdle(trackId: String): Boolean = synchronized(lock) {
        if (activeWriters.contains(trackId)) return false
        activeWriters.add(trackId)
        true
    }

    fun finishWriteThrough(trackId: String) = synchronized(lock) {
        activeWriters.remove(trackId)
    }

    fun setProtectedTrackIds(ids: Set<String>) = synchronized(lock) {
        protectedTrackIds.clear()
        protectedTrackIds.addAll(ids)
    }

    fun cacheFile(trackId: String, originalFileName: String): File =
        File(cacheDir, "$trackId-${Cloud189Protocol.sanitizeFileName(originalFileName)}")

    fun existingCachedFile(trackId: String): File? = synchronized(lock) {
        val entry = entries[trackId] ?: return null
        val file = File(cacheDir, entry.fileName)
        if (!file.isFile || file.length() <= 0L) {
            entries.remove(trackId)
            persistIndexLocked()
            return null
        }
        entries[trackId] = entry.copy(
            sizeBytes = file.length(),
            lastAccessedMs = System.currentTimeMillis()
        )
        persistIndexLocked()
        file
    }

    fun recordCompletedFile(
        trackId: String,
        file: File,
        sizeBytes: Long,
        limitBytes: Long
    ): Long = synchronized(lock) {
        entries[trackId] = CacheEntry(
            fileName = file.name,
            sizeBytes = sizeBytes,
            lastAccessedMs = System.currentTimeMillis()
        )
        val usage = pruneToLimitLocked(limitBytes, setOf(trackId))
        persistIndexLocked()
        usage
    }

    fun usageBytes(): Long = synchronized(lock) {
        entries.values.sumOf { entry ->
            val f = File(cacheDir, entry.fileName)
            if (f.isFile) f.length() else 0L
        }
    }

    fun pruneToLimit(limitBytes: Long, extraProtected: Set<String> = emptySet()): Long = synchronized(lock) {
        val usage = pruneToLimitLocked(limitBytes, extraProtected)
        persistIndexLocked()
        usage
    }

    private fun pruneToLimitLocked(limitBytes: Long, extraProtected: Set<String>): Long {
        val protectedAll = protectedTrackIds + extraProtected
        var current = entries.values.sumOf { File(cacheDir, it.fileName).takeIf(File::isFile)?.length() ?: 0L }
        if (current <= limitBytes) return current

        val sorted = entries.entries.sortedBy { it.value.lastAccessedMs }
        for ((trackId, entry) in sorted) {
            if (current <= limitBytes) break
            if (trackId in protectedAll || trackId in activeWriters) continue
            File(cacheDir, entry.fileName).delete()
            entries.remove(trackId)
            current = (current - entry.sizeBytes).coerceAtLeast(0L)
        }
        return entries.values.sumOf { File(cacheDir, it.fileName).takeIf(File::isFile)?.length() ?: 0L }
    }

    private fun cleanupOrphanedFiles() {
        val valid = entries.values.map { it.fileName }.toSet()
        val children = cacheDir.listFiles() ?: return
        for (child in children) {
            if (child.name == "index.json" || child.name in valid) continue
            if (child.name.endsWith(".part") || child.name.endsWith(".parts")) {
                child.deleteRecursively()
            }
        }
    }

    private fun persistIndexLocked() {
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
        val tmp = File(indexFile.parentFile, ".${indexFile.name}.tmp")
        tmp.writeText(root.toString(), Charsets.UTF_8)
        try {
            Files.move(tmp.toPath(), indexFile.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (_: AtomicMoveNotSupportedException) {
            runCatching {
                Files.move(tmp.toPath(), indexFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }.onFailure {
                tmp.copyTo(indexFile, overwrite = true)
                tmp.delete()
            }
        } catch (_: Exception) {
            tmp.copyTo(indexFile, overwrite = true)
            tmp.delete()
        }
    }
}
