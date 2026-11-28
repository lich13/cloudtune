package com.gosu.cloudtune.data

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import com.gosu.cloudtune.core.AccountSettings
import com.gosu.cloudtune.core.AppearanceMode
import com.gosu.cloudtune.core.AtomicFileIO
import com.gosu.cloudtune.core.Cloud189Constants
import com.gosu.cloudtune.core.Cloud189Protocol
import com.gosu.cloudtune.core.CloudTuneException
import com.gosu.cloudtune.core.FolderSelection
import com.gosu.cloudtune.core.PersistedRefreshCredential
import com.gosu.cloudtune.core.PlaybackMode
import com.gosu.cloudtune.core.TrackSummary
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import java.util.Locale
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
    private val ioLock = Any()
    @Volatile private var migrationChecked: Boolean = false

    init {
        rootDir.mkdirs()
        ensureMigratedV2()
    }

    internal fun ensureMigratedV2() {
        if (migrationChecked) return
        synchronized(ioLock) {
            if (migrationChecked) return
            val marker = File(rootDir, MIGRATED_V2_MARKER)
            if (marker.isFile) {
                migrationChecked = true
                return
            }
            val legacySettingsFile = File(rootDir, "settings.json")
            if (legacySettingsFile.isFile) {
                runCatching {
                    val json = JSONObject(legacySettingsFile.readText(Charsets.UTF_8))
                    val rawAcct = Cloud189Protocol.optNonBlank(json, "accountName")
                    val refreshToken = Cloud189Protocol.optNonBlank(json, "refreshToken").orEmpty()
                    val targetAccount = when {
                        rawAcct != null && rawAcct != Cloud189Constants.DEFAULT_ACCOUNT_DISPLAY_NAME -> rawAcct
                        refreshToken.isNotEmpty() -> Cloud189Protocol.deriveFallbackAccountKey(
                            refreshToken = refreshToken,
                            accessToken = null,
                            sessionKey = "legacy_account"
                        )
                        else -> null
                    }
                    if (targetAccount != null) {
                        val destPaths = pathsUnlocked(targetAccount)
                        if (!destPaths.settingsFile.isFile) {
                            val fid = Cloud189Protocol.optNonBlank(json, "musicFolderId")
                            val fname = Cloud189Protocol.optNonBlank(json, "musicFolderName")
                            val mf = if (fid != null && fname != null) FolderSelection(fid, fname) else null
                            val migrated = AccountSettings(
                                musicFolder = mf,
                                cacheLimitMb = json.optLong("cacheLimitMb", 1024L)
                                    .coerceAtLeast(AccountSettings.MIN_CACHE_LIMIT_MB),
                                downloadThreads = json.optInt("downloadThreads", 8)
                                    .coerceIn(1, AccountSettings.MAX_DOWNLOAD_THREADS),
                                cacheThreads = json.optInt("cacheThreads", 4)
                                    .coerceIn(1, AccountSettings.MAX_CACHE_THREADS),
                                playbackMode = PlaybackMode.fromWire(json.optString("playbackMode")),
                                appearanceMode = AppearanceMode.fromWire(json.optString("appearanceMode"))
                            )
                            AtomicFileIO.writeText(destPaths.settingsFile, serializeSettings(migrated).toString())
                        }
                        val legacyLibrary = File(rootDir, "library.json")
                        if (legacyLibrary.isFile && !destPaths.libraryFile.isFile) {
                            destPaths.libraryFile.parentFile?.mkdirs()
                            Files.copy(legacyLibrary.toPath(), destPaths.libraryFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
                        }
                    }
                }
            }
            runCatching { AtomicFileIO.writeText(marker, "ok") }
            migrationChecked = true
        }
    }

    fun paths(accountId: String): AccountPaths {
        ensureMigratedV2()
        return pathsUnlocked(accountId)
    }

    private fun pathsUnlocked(accountId: String): AccountPaths {
        val hash = Cloud189Protocol.accountBucketHash(accountId)
        val dir = File(rootDir, "accounts/$hash")
        val cache = File(dir, "cache")
        val staging = File(dir, "staging")
        cache.mkdirs()
        staging.mkdirs()
        return AccountPaths(
            accountId = accountId.trim().lowercase(Locale.ROOT),
            bucketHash = hash,
            accountDir = dir,
            cacheDir = cache,
            stagingDir = staging,
            settingsFile = File(dir, "settings.json"),
            libraryFile = File(dir, "library.json"),
            transfersFile = File(dir, "transfers.json")
        )
    }

    private fun readAtomicTextOrNull(target: File): String? = synchronized(ioLock) {
        if (!target.isFile) return null
        target.readText(Charsets.UTF_8)
    }

    private fun writeAtomicText(target: File, content: String) {
        synchronized(ioLock) {
            AtomicFileIO.writeText(target, content)
        }
    }

    fun loadSettingsOrNull(accountId: String): AccountSettings? {
        val raw = runCatching { readAtomicTextOrNull(paths(accountId).settingsFile) }.getOrNull()
            ?: return null
        return runCatching {
            val o = JSONObject(raw)
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
                exportFolderDisplayName = o.optString("exportFolderDisplayName").takeIf { it.isNotEmpty() },
                appearanceMode = AppearanceMode.fromWire(o.optString("appearanceMode")),
                dynamicColorEnabled = o.optBoolean("dynamicColorEnabled", false)
            )
        }.getOrNull()
    }

    private fun serializeSettings(settings: AccountSettings): JSONObject {
        val o = JSONObject()
            .put("cacheLimitMb", settings.cacheLimitMb)
            .put("downloadThreads", settings.downloadThreads)
            .put("cacheThreads", settings.cacheThreads)
            .put("playbackMode", settings.playbackMode.wireValue)
            .put("appearanceMode", settings.appearanceMode.wireValue)
            .put("dynamicColorEnabled", settings.dynamicColorEnabled)
        settings.musicFolder?.let {
            o.put("musicFolder", JSONObject().put("id", it.id).put("name", it.name))
        }
        settings.exportTreeUri?.let { o.put("exportTreeUri", it) }
        settings.exportFolderDisplayName?.let { o.put("exportFolderDisplayName", it) }
        return o
    }

    fun saveSettings(accountId: String, settings: AccountSettings) {
        val f = paths(accountId).settingsFile
        writeAtomicText(f, serializeSettings(settings).toString())
    }

    fun loadLibrary(accountId: String): List<TrackSummary> {
        val raw = runCatching { readAtomicTextOrNull(paths(accountId).libraryFile) }.getOrNull()
            ?: return emptyList()
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val out = ArrayList<TrackSummary>(arr.length())
        for (i in 0 until arr.length()) {
            val decoded = runCatching {
                val o = arr.optJSONObject(i) ?: return@runCatching null
                val id = Cloud189Protocol.optNonBlank(o, "id") ?: return@runCatching null
                val name = Cloud189Protocol.optNonBlank(o, "name") ?: return@runCatching null
                val modified = if (o.isNull("modifiedAt")) {
                    null
                } else {
                    o.optString("modifiedAt").trim().takeIf { it.isNotEmpty() }
                }
                TrackSummary(
                    id = id,
                    name = name,
                    folderPath = o.optString("folderPath"),
                    sizeBytes = o.optLong("sizeBytes", 0L).coerceAtLeast(0L),
                    modifiedAt = modified
                )
            }.getOrNull()
            if (decoded != null) {
                out.add(decoded)
            }
        }
        return out
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
        writeAtomicText(f, arr.toString())
    }

    companion object {
        const val MIGRATED_V2_MARKER = ".migrated-v2"
    }
}

object SafExporter {
    private data class ChildDocEntry(
        val documentId: String,
        val displayName: String,
        val mimeType: String
    ) {
        val isDirectory: Boolean
            get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
    }

    private val CHILD_PROJECTION = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE
    )

    fun persistTreePermission(context: Context, treeUri: Uri): String {
        val resolver = context.contentResolver
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        resolver.takePersistableUriPermission(treeUri, flags)
        val queriedName = runCatching {
            val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
            resolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) {
                    cursor.getString(0)?.trim()?.takeIf { it.isNotEmpty() }
                } else null
            }
        }.getOrNull()
        return queriedName
            ?: runCatching { DocumentsContract.getTreeDocumentId(treeUri).substringAfterLast(':').substringAfterLast('/') }
                .getOrNull()?.takeIf { it.isNotEmpty() }
            ?: treeUri.lastPathSegment
            ?: "已选文件夹"
    }

    fun exportToSafTree(
        context: Context,
        treeUriString: String?,
        stagedFile: File,
        relativeSubpath: String,
        mimeType: String,
        openOutputStreamOverride: ((Uri) -> OutputStream?)? = null
    ): String {
        if (!stagedFile.isFile) {
            throw CloudTuneException("待导出的本地暂存文件不存在")
        }
        return exportPartsToSafTree(
            context = context,
            treeUriString = treeUriString,
            partFiles = listOf(stagedFile),
            expectedTotalBytes = stagedFile.length(),
            relativeSubpath = relativeSubpath,
            mimeType = mimeType,
            openOutputStreamOverride = openOutputStreamOverride
        )
    }

    fun exportPartsToSafTree(
        context: Context,
        treeUriString: String?,
        partFiles: List<File>,
        expectedTotalBytes: Long,
        relativeSubpath: String,
        mimeType: String,
        openOutputStreamOverride: ((Uri) -> OutputStream?)? = null
    ): String {
        if (treeUriString.isNullOrBlank()) {
            throw CloudTuneException("尚未选择导出目录，请先授权下载文件夹。")
        }
        if (partFiles.isEmpty() || partFiles.any { !it.isFile }) {
            throw CloudTuneException("待导出的本地暂存文件不存在")
        }
        val summedPartBytes = partFiles.sumOf { it.length().coerceAtLeast(0L) }
        val expectedBytes = if (expectedTotalBytes > 0L) expectedTotalBytes else summedPartBytes
        if (expectedTotalBytes > 0L && summedPartBytes != expectedTotalBytes) {
            throw CloudTuneException("待导出分片长度不完整：$summedPartBytes != $expectedTotalBytes")
        }

        val resolver = context.contentResolver
        val treeUri = Uri.parse(treeUriString)
        val treeDocId = runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull()
            ?.takeIf { it.isNotEmpty() }
            ?: throw CloudTuneException("导出目录 URI 无效，请重新选择下载文件夹。")

        val rootDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
        val rootWritableDir = runCatching {
            resolver.query(
                rootDocUri,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_MIME_TYPE),
                null,
                null,
                null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) {
                    false
                } else {
                    val mimeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    val rootMime = if (mimeIdx >= 0 && !cursor.isNull(mimeIdx)) cursor.getString(mimeIdx) else null
                    rootMime == null || rootMime == DocumentsContract.Document.MIME_TYPE_DIR
                }
            } ?: false
        }.getOrDefault(false)
        if (!rootWritableDir) {
            throw CloudTuneException("导出目录授权已失效，请重新选择下载文件夹。")
        }

        val segments = relativeSubpath
            .split('/')
            .map { Cloud189Protocol.sanitizeFileName(it) }
            .filter { it.isNotEmpty() && it != "." && it != ".." }
        if (segments.isEmpty()) {
            throw CloudTuneException("导出文件名为空")
        }

        var currentDirDocId = treeDocId
        for (dirSegment in segments.dropLast(1)) {
            val existing = findChildByName(resolver, treeUri, currentDirDocId, dirSegment)
            if (existing != null) {
                if (!existing.isDirectory) {
                    throw CloudTuneException("导出路径已存在同名文件：$dirSegment")
                }
                currentDirDocId = existing.documentId
            } else {
                val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, currentDirDocId)
                val createdDirUri = runCatching {
                    DocumentsContract.createDocument(
                        resolver,
                        parentUri,
                        DocumentsContract.Document.MIME_TYPE_DIR,
                        dirSegment
                    )
                }.getOrNull() ?: throw CloudTuneException("无法在导出目录创建子文件夹 $dirSegment")
                currentDirDocId = DocumentsContract.getDocumentId(createdDirUri)
            }
        }

        val targetName = segments.last()
        val openStream: (Uri) -> OutputStream? = openOutputStreamOverride
            ?: { docUri -> resolver.openOutputStream(docUri, "wt") ?: resolver.openOutputStream(docUri) }

        return writePartsWithSiblingRollback(
            resolver = resolver,
            treeUri = treeUri,
            parentDirDocId = currentDirDocId,
            targetName = targetName,
            partFiles = partFiles,
            expectedBytes = expectedBytes,
            mimeType = mimeType,
            openOutputStream = openStream
        )
    }

    private fun findChildByName(
        resolver: ContentResolver,
        treeUri: Uri,
        parentDocId: String,
        targetName: String
    ): ChildDocEntry? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val cursor = try {
            resolver.query(childrenUri, CHILD_PROJECTION, null, null, null)
        } catch (e: Exception) {
            throw CloudTuneException("无法访问导出目录：${e.message ?: "权限不可用"}")
        } ?: throw CloudTuneException("导出目录授权已失效，请重新选择下载文件夹。")

        cursor.use { c ->
            val idIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            if (idIdx < 0 || nameIdx < 0) return null
            while (c.moveToNext()) {
                val name = if (c.isNull(nameIdx)) null else c.getString(nameIdx)
                if (name == targetName) {
                    val docId = c.getString(idIdx) ?: continue
                    val mime = if (mimeIdx >= 0 && !c.isNull(mimeIdx)) c.getString(mimeIdx).orEmpty() else ""
                    return ChildDocEntry(documentId = docId, displayName = name, mimeType = mime)
                }
            }
        }
        return null
    }

    private fun writePartsWithSiblingRollback(
        resolver: ContentResolver,
        treeUri: Uri,
        parentDirDocId: String,
        targetName: String,
        partFiles: List<File>,
        expectedBytes: Long,
        mimeType: String,
        openOutputStream: (Uri) -> OutputStream?
    ): String {
        val initialExisting = findChildByName(resolver, treeUri, parentDirDocId, targetName)
        if (initialExisting != null && initialExisting.isDirectory) {
            throw CloudTuneException("导出目标路径已存在同名文件夹：$targetName")
        }

        val parentDirUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentDirDocId)
        val tempName = ".cloudtune-tmp-${UUID.randomUUID()}"
        val createdTempUri = runCatching {
            DocumentsContract.createDocument(resolver, parentDirUri, "application/octet-stream", tempName)
        }.getOrNull() ?: runCatching {
            DocumentsContract.createDocument(resolver, parentDirUri, mimeType, tempName)
        }.getOrNull() ?: throw CloudTuneException("无法创建导出临时文件 $targetName")

        val tempDocId = DocumentsContract.getDocumentId(createdTempUri)
        val tempDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, tempDocId)

        var tempPromoted = false
        try {
            val writtenBytes = streamPartsToUri(partFiles, tempDocUri, openOutputStream)
            if (writtenBytes != expectedBytes) {
                throw CloudTuneException("导出文件写入长度不完整：$writtenBytes != $expectedBytes")
            }

            // Only AFTER temp sibling is 100% written & verified, replace any pre-existing target document
            // WITHOUT deleting the existing document before its replacement (or a verified backup) is in place.
            val currentExisting = findChildByName(resolver, treeUri, parentDirDocId, targetName)
            if (currentExisting == null || currentExisting.documentId == tempDocId) {
                return promoteTempToVacantTarget(
                    resolver = resolver,
                    treeUri = treeUri,
                    parentDirUri = parentDirUri,
                    tempDocId = tempDocId,
                    tempDocUri = tempDocUri,
                    targetName = targetName,
                    mimeType = mimeType,
                    partFiles = partFiles,
                    expectedBytes = expectedBytes,
                    openOutputStream = openOutputStream,
                    onTempPromoted = { tempPromoted = true }
                )
            }

            if (currentExisting.isDirectory) {
                throw CloudTuneException("导出目标路径已存在同名文件夹：$targetName")
            }
            val existingDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, currentExisting.documentId)
            val backupName = ".cloudtune-bak-${UUID.randomUUID()}"
            val backupRenamedUri = runCatching {
                DocumentsContract.renameDocument(resolver, existingDocUri, backupName)
            }.getOrNull()

            if (backupRenamedUri != null) {
                val backupDocId = runCatching { DocumentsContract.getDocumentId(backupRenamedUri) }.getOrNull()
                val backupDocUri = if (backupDocId != null) {
                    DocumentsContract.buildDocumentUriUsingTree(treeUri, backupDocId)
                } else {
                    backupRenamedUri
                }
                try {
                    val promotedUri = promoteTempToVacantTarget(
                        resolver = resolver,
                        treeUri = treeUri,
                        parentDirUri = parentDirUri,
                        tempDocId = tempDocId,
                        tempDocUri = tempDocUri,
                        targetName = targetName,
                        mimeType = mimeType,
                        partFiles = partFiles,
                        expectedBytes = expectedBytes,
                        openOutputStream = openOutputStream,
                        onTempPromoted = { tempPromoted = true }
                    )
                    runCatching { DocumentsContract.deleteDocument(resolver, backupDocUri) }
                    return promotedUri
                } catch (e: Exception) {
                    runCatching { DocumentsContract.renameDocument(resolver, backupDocUri, targetName) }
                    throw e
                }
            }

            // Provider does not support renameDocument: stage a verified backup copy BEFORE overwriting existingDocUri in-place
            val rawBackupCopyUri = runCatching {
                DocumentsContract.createDocument(resolver, parentDirUri, "application/octet-stream", backupName)
            }.getOrNull() ?: runCatching {
                DocumentsContract.createDocument(resolver, parentDirUri, mimeType, backupName)
            }.getOrNull() ?: throw CloudTuneException("无法创建导出备份文件 $targetName")
            val backupCopyDocUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getDocumentId(rawBackupCopyUri)
            )
            try {
                copyUriBytesChecked(resolver, existingDocUri, backupCopyDocUri, openOutputStream)
            } catch (e: Exception) {
                runCatching { DocumentsContract.deleteDocument(resolver, backupCopyDocUri) }
                throw CloudTuneException("无法备份已有导出文件 $targetName：${e.message ?: "IO 错误"}")
            }

            try {
                val overwrittenBytes = streamPartsToUri(partFiles, existingDocUri, openOutputStream)
                if (overwrittenBytes != expectedBytes) {
                    throw CloudTuneException("导出文件写入长度不完整：$overwrittenBytes != $expectedBytes")
                }
                runCatching { DocumentsContract.deleteDocument(resolver, backupCopyDocUri) }
                return existingDocUri.toString()
            } catch (e: Exception) {
                runCatching { copyUriBytesChecked(resolver, backupCopyDocUri, existingDocUri, openOutputStream) }
                runCatching { DocumentsContract.deleteDocument(resolver, backupCopyDocUri) }
                throw e
            }
        } finally {
            if (!tempPromoted) {
                runCatching { DocumentsContract.deleteDocument(resolver, tempDocUri) }
            }
        }
    }

    private fun promoteTempToVacantTarget(
        resolver: ContentResolver,
        treeUri: Uri,
        parentDirUri: Uri,
        tempDocId: String,
        tempDocUri: Uri,
        targetName: String,
        mimeType: String,
        partFiles: List<File>,
        expectedBytes: Long,
        openOutputStream: (Uri) -> OutputStream?,
        onTempPromoted: () -> Unit
    ): String {
        val renamedUri = runCatching {
            DocumentsContract.renameDocument(resolver, tempDocUri, targetName)
        }.getOrNull()
        if (renamedUri != null) {
            onTempPromoted()
            val finalDocId = runCatching { DocumentsContract.getDocumentId(renamedUri) }.getOrDefault(tempDocId)
            return DocumentsContract.buildDocumentUriUsingTree(treeUri, finalDocId).toString()
        }

        val rawFallbackUri = runCatching {
            DocumentsContract.createDocument(resolver, parentDirUri, mimeType, targetName)
        }.getOrNull() ?: throw CloudTuneException("无法创建导出文件 $targetName")
        val fallbackDocUri = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(rawFallbackUri)
        )
        try {
            val fallbackWritten = streamPartsToUri(partFiles, fallbackDocUri, openOutputStream)
            if (fallbackWritten != expectedBytes) {
                throw CloudTuneException("导出文件写入长度不完整：$fallbackWritten != $expectedBytes")
            }
            return fallbackDocUri.toString()
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, fallbackDocUri) }
            throw e
        }
    }

    private fun copyUriBytesChecked(
        resolver: ContentResolver,
        sourceUri: Uri,
        destUri: Uri,
        openOutputStream: (Uri) -> OutputStream?
    ) {
        val input = resolver.openInputStream(sourceUri)
            ?: throw IOException("无法读取原导出文件")
        input.use { src ->
            val output = openOutputStream(destUri)
                ?: throw IOException("无法打开导出流")
            output.use { dst ->
                val buf = ByteArray(131_072)
                while (true) {
                    val n = src.read(buf)
                    if (n < 0) break
                    if (n > 0) dst.write(buf, 0, n)
                }
                dst.flush()
            }
        }
    }

    private fun streamPartsToUri(
        partFiles: List<File>,
        targetUri: Uri,
        openOutputStream: (Uri) -> OutputStream?
    ): Long {
        val stream = try {
            openOutputStream(targetUri)
        } catch (e: Exception) {
            throw CloudTuneException("无法写入导出文件流：${e.message ?: "IO 错误"}")
        } ?: throw CloudTuneException("无法写入导出文件流")

        return try {
            var written = 0L
            stream.use { out ->
                val buf = ByteArray(262_144)
                for (part in partFiles) {
                    FileInputStream(part).use { input ->
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            if (n > 0) {
                                out.write(buf, 0, n)
                                written += n.toLong()
                            }
                        }
                    }
                }
                out.flush()
            }
            written
        } catch (ce: CloudTuneException) {
            throw ce
        } catch (e: Exception) {
            throw CloudTuneException("导出文件写入中断：${e.message ?: "IO 错误"}")
        }
    }
}
