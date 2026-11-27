package com.gosu.cloudtune.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import androidx.documentfile.provider.DocumentFile
import com.gosu.cloudtune.core.AccountSettings
import com.gosu.cloudtune.core.Cloud189Protocol
import com.gosu.cloudtune.core.CloudTuneException
import com.gosu.cloudtune.core.FolderSelection
import com.gosu.cloudtune.core.PersistedRefreshCredential
import com.gosu.cloudtune.core.PlaybackMode
import com.gosu.cloudtune.core.TrackSummary
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

interface CredentialStore {
    fun loadCredential(): PersistedRefreshCredential?
    fun saveCredential(credential: PersistedRefreshCredential)
    fun clearCredential()
}

class EncryptedCredentialStore(context: Context) : CredentialStore {
    private val file = AtomicFile(File(context.applicationContext.noBackupFilesDir, "cloudtune-session.enc"))
    private val keyStore: KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val alias = "com.gosu.cloudtune.master_session_key"
    private val lock = Any()

    override fun loadCredential(): PersistedRefreshCredential? = synchronized(lock) {
        if (!file.baseFile.exists()) return null
        return runCatching {
            val secret = keyStore.getKey(alias, null) as? SecretKey ?: return null
            val obj = JSONObject(file.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
            val iv = Base64.decode(obj.getString("iv"), Base64.NO_WRAP)
            val ct = Base64.decode(obj.getString("ct"), Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, iv))
            val plain = JSONObject(cipher.doFinal(ct).toString(Charsets.UTF_8))
            PersistedRefreshCredential.createOrNull(
                refreshToken = plain.optString("refreshToken"),
                accountName = plain.optString("accountName"),
                accountKey = plain.optString("accountKey")
            )
        }.getOrNull()
    }

    override fun saveCredential(credential: PersistedRefreshCredential) {
        synchronized(lock) {
            val secret = getOrCreateKey()
            val plain = JSONObject()
                .put("refreshToken", credential.refreshToken)
                .put("accountName", credential.accountName.orEmpty())
                .put("accountKey", credential.accountKey.orEmpty())
                .toString()
                .toByteArray(Charsets.UTF_8)

            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secret)
            val encrypted = cipher.doFinal(plain)

            val envelope = JSONObject()
                .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .put("ct", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .toString()
                .toByteArray(Charsets.UTF_8)

            val stream = file.startWrite()
            try {
                stream.write(envelope)
                file.finishWrite(stream)
            } catch (e: Exception) {
                file.failWrite(stream)
                throw e
            }
        }
    }

    override fun clearCredential() {
        synchronized(lock) {
            runCatching { file.delete() }
        }
    }

    private fun getOrCreateKey(): SecretKey {
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
        }.generateKey()
    }
}

data class AccountPaths(
    val accountId: String,
    val bucketHash: String,
    val accountDir: File,
    val cacheDir: File,
    val stagingDir: File,
    val settingsFile: File,
    val libraryFile: File,
    val transfersFile: File
)

class AccountStore(val rootDir: File) {
    init {
        rootDir.mkdirs()
    }

    fun paths(accountId: String): AccountPaths {
        val hash = Cloud189Protocol.accountBucketHash(accountId)
        val dir = File(rootDir, "accounts/$hash")
        val cache = File(dir, "cache")
        val staging = File(dir, "staging")
        cache.mkdirs()
        staging.mkdirs()
        return AccountPaths(
            accountId = accountId.trim().lowercase(),
            bucketHash = hash,
            accountDir = dir,
            cacheDir = cache,
            stagingDir = staging,
            settingsFile = File(dir, "settings.json"),
            libraryFile = File(dir, "library.json"),
            transfersFile = File(dir, "transfers.json")
        )
    }

    fun loadSettings(accountId: String): AccountSettings {
        val f = paths(accountId).settingsFile
        if (!f.isFile) return AccountSettings()
        return runCatching {
            val o = JSONObject(f.readText(Charsets.UTF_8))
            val mf = o.optJSONObject("musicFolder")?.let {
                FolderSelection(it.getString("id"), it.getString("name"))
            }
            AccountSettings(
                musicFolder = mf,
                cacheLimitMb = o.optLong("cacheLimitMb", 1024L).coerceAtLeast(AccountSettings.MIN_CACHE_LIMIT_MB),
                downloadThreads = o.optInt("downloadThreads", 8).coerceIn(1, AccountSettings.MAX_DOWNLOAD_THREADS),
                cacheThreads = o.optInt("cacheThreads", 4).coerceIn(1, AccountSettings.MAX_CACHE_THREADS),
                playbackMode = PlaybackMode.fromWire(o.optString("playbackMode")),
                exportTreeUri = o.optString("exportTreeUri").takeIf { it.isNotEmpty() },
                exportFolderDisplayName = o.optString("exportFolderDisplayName").takeIf { it.isNotEmpty() }
            )
        }.getOrDefault(AccountSettings())
    }

    fun saveSettings(accountId: String, settings: AccountSettings) {
        val f = paths(accountId).settingsFile
        val o = JSONObject()
            .put("cacheLimitMb", settings.cacheLimitMb)
            .put("downloadThreads", settings.downloadThreads)
            .put("cacheThreads", settings.cacheThreads)
            .put("playbackMode", settings.playbackMode.wireValue)
        settings.musicFolder?.let {
            o.put("musicFolder", JSONObject().put("id", it.id).put("name", it.name))
        }
        settings.exportTreeUri?.let { o.put("exportTreeUri", it) }
        settings.exportFolderDisplayName?.let { o.put("exportFolderDisplayName", it) }
        f.writeText(o.toString(), Charsets.UTF_8)
    }

    fun loadLibrary(accountId: String): List<TrackSummary> {
        val f = paths(accountId).libraryFile
        if (!f.isFile) return emptyList()
        return runCatching {
            val arr = JSONArray(f.readText(Charsets.UTF_8))
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                TrackSummary(
                    id = o.getString("id"),
                    name = o.getString("name"),
                    folderPath = o.optString("folderPath"),
                    sizeBytes = o.optLong("sizeBytes", 0L),
                    modifiedAt = o.optString("modifiedAt").takeIf { it.isNotEmpty() }
                )
            }
        }.getOrDefault(emptyList())
    }

    fun saveLibrary(accountId: String, tracks: List<TrackSummary>) {
        val f = paths(accountId).libraryFile
        val arr = JSONArray()
        for (t in tracks) {
            arr.put(
                JSONObject()
                    .put("id", t.id)
                    .put("name", t.name)
                    .put("folderPath", t.folderPath)
                    .put("sizeBytes", t.sizeBytes)
                    .put("modifiedAt", t.modifiedAt ?: JSONObject.NULL)
            )
        }
        f.writeText(arr.toString(), Charsets.UTF_8)
    }
}

object SafExporter {
    fun persistTreePermission(context: Context, treeUri: Uri): String {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        context.contentResolver.takePersistableUriPermission(treeUri, flags)
        val doc = DocumentFile.fromTreeUri(context, treeUri)
        return doc?.name ?: treeUri.lastPathSegment ?: "已选文件夹"
    }

    fun exportToSafTree(
        context: Context,
        treeUriString: String?,
        stagedFile: File,
        relativeSubpath: String,
        mimeType: String
    ): String {
        if (treeUriString.isNullOrBlank()) {
            throw CloudTuneException("尚未选择导出目录，请先授权下载文件夹。")
        }
        if (!stagedFile.isFile) {
            throw CloudTuneException("待导出的本地暂存文件不存在")
        }
        val treeUri = Uri.parse(treeUriString)
        var currentDir = DocumentFile.fromTreeUri(context, treeUri)
            ?.takeIf { it.canWrite() }
            ?: throw CloudTuneException("导出目录授权已失效，请重新选择下载文件夹。")

        val parts = relativeSubpath
            .split('/')
            .map { Cloud189Protocol.sanitizeFileName(it) }
            .filter { it.isNotEmpty() && it != "." && it != ".." }
        if (parts.isEmpty()) throw CloudTuneException("导出文件名为空")

        for (dirSegment in parts.dropLast(1)) {
            val existingSegment = currentDir.findFile(dirSegment)
            if (existingSegment != null && !existingSegment.isDirectory) {
                throw CloudTuneException("导出路径已存在同名文件：$dirSegment")
            }
            currentDir = existingSegment
                ?: currentDir.createDirectory(dirSegment)
                ?: throw CloudTuneException("无法在导出目录创建子文件夹 $dirSegment")
        }

        val targetName = parts.last()
        return exportToDocumentDirectory(
            dir = currentDir,
            targetName = targetName,
            stagedFile = stagedFile,
            mimeType = mimeType,
            openOutputStream = { doc -> context.contentResolver.openOutputStream(doc.uri) }
        )
    }

    internal fun exportToDocumentDirectory(
        dir: DocumentFile,
        targetName: String,
        stagedFile: File,
        mimeType: String,
        openOutputStream: (DocumentFile) -> OutputStream?
    ): String {
        if (!stagedFile.isFile) {
            throw CloudTuneException("待导出的本地暂存文件不存在")
        }
        val initialExisting = dir.findFile(targetName)
        if (initialExisting != null && initialExisting.isDirectory) {
            throw CloudTuneException("导出目标路径已存在同名文件夹：$targetName")
        }

        val tempName = "${targetName}.cloudtune-${UUID.randomUUID()}.tmp"
        val tempDoc = (dir.createFile("application/octet-stream", tempName) ?: dir.createFile(mimeType, tempName))
            ?: throw CloudTuneException("无法创建导出临时文件 $targetName")

        var tempPromoted = false
        try {
            val expectedBytes = stagedFile.length()
            var writtenBytes = 0L
            openOutputStream(tempDoc)?.use { out ->
                FileInputStream(stagedFile).use { input ->
                    writtenBytes = input.copyTo(out, bufferSize = 262_144)
                }
            } ?: throw CloudTuneException("无法写入导出文件流")

            if (expectedBytes > 0L && writtenBytes != expectedBytes) {
                throw CloudTuneException("导出文件写入长度不完整：$writtenBytes != $expectedBytes")
            }

            val currentExisting = dir.findFile(targetName)
            if (currentExisting != null && currentExisting.uri != tempDoc.uri) {
                if (currentExisting.isDirectory) {
                    throw CloudTuneException("导出目标路径已存在同名文件夹：$targetName")
                }
                if (!currentExisting.delete()) {
                    throw CloudTuneException("无法替换已有导出文件 $targetName")
                }
            }

            if (tempDoc.renameTo(targetName)) {
                tempPromoted = true
                return (dir.findFile(targetName) ?: tempDoc).uri.toString()
            }

            val fallbackDest = dir.createFile(mimeType, targetName)
                ?: throw CloudTuneException("无法创建导出文件 $targetName")
            try {
                var fallbackWritten = 0L
                openOutputStream(fallbackDest)?.use { out ->
                    FileInputStream(stagedFile).use { input ->
                        fallbackWritten = input.copyTo(out, bufferSize = 262_144)
                    }
                } ?: throw CloudTuneException("无法写入导出文件流")
                if (expectedBytes > 0L && fallbackWritten != expectedBytes) {
                    throw CloudTuneException("导出文件写入长度不完整：$fallbackWritten != $expectedBytes")
                }
                return fallbackDest.uri.toString()
            } catch (e: Exception) {
                runCatching { fallbackDest.delete() }
                throw e
            }
        } finally {
            if (!tempPromoted) {
                runCatching { tempDoc.delete() }
            }
        }
    }
}
