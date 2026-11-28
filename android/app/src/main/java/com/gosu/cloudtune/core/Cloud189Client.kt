package com.gosu.cloudtune.core

import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpCookie
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.util.Collections
import java.util.Locale
import java.util.UUID
import kotlin.random.Random
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class CloudHttpResponse(
    val statusCode: Int,
    val headers: Map<String, String>,
    val body: ByteArray
) {
    val text: String get() = body.toString(Charsets.UTF_8)
}

interface CloudHttpTransport {
    suspend fun send(
        url: String,
        method: String = "GET",
        headers: Map<String, String> = emptyMap(),
        formBody: List<Pair<String, String>>? = null
    ): CloudHttpResponse

    fun importCookieHeader(domainUrl: String, cookieHeader: String?)
    fun clearCookies()
}

class HttpUrlConnectionTransport : CloudHttpTransport {
    private val cookieLock = Any()
    private var cookieManager = CookieManager(null, CookiePolicy.ACCEPT_ALL)

    internal fun cookieHeaderFor(uri: URI): String = synchronized(cookieLock) {
        cookieManager.cookieStore.get(uri)
            .joinToString("; ") { "${it.name}=${it.value}" }
    }

    override suspend fun send(
        url: String,
        method: String,
        headers: Map<String, String>,
        formBody: List<Pair<String, String>>?
    ): CloudHttpResponse = withContext(Dispatchers.IO) {
        val initialUri = URI(url)
        var currentUrl = url
        var currentMethod = method
        var currentHeaders = headers.toMap()
        var currentBody = formBody
        var redirects = 0

        while (redirects < 6) {
            val uri = URI(currentUrl)
            val conn = (URL(currentUrl).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                requestMethod = currentMethod
                connectTimeout = 20_000
                readTimeout = 30_000
                useCaches = false
                setRequestProperty("User-Agent", Cloud189Constants.USER_AGENT)
            }

            var keepAliveReusable = false
            try {
                val allowCookies = Cloud189Protocol.isSameOrigin(initialUri, uri) ||
                    Cloud189Protocol.isTrustedTianyiOrigin(uri)
                if (allowCookies) {
                    val cookieValue = cookieHeaderFor(uri)
                    if (cookieValue.isNotEmpty()) {
                        conn.setRequestProperty("Cookie", cookieValue)
                    }
                }
                for ((k, v) in currentHeaders) {
                    conn.setRequestProperty(k, v)
                }

                if (currentBody != null && currentMethod == "POST") {
                    conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
                    val encoded = currentBody.joinToString("&") { (k, v) ->
                        "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
                    }.toByteArray(Charsets.UTF_8)
                    conn.outputStream.use { it.write(encoded) }
                }

                val status = conn.responseCode
                val rawHeaders = conn.headerFields
                if (allowCookies) {
                    synchronized(cookieLock) {
                        val cookieHeaders = rawHeaders.filterKeys { it != null }.mapKeys { it.key!! }
                        runCatching { cookieManager.put(uri, cookieHeaders) }
                    }
                }

                if (status in listOf(301, 302, 303, 307, 308)) {
                    val location = conn.getHeaderField("Location")
                    if (!location.isNullOrBlank()) {
                        val nextUri = runCatching { uri.resolve(location) }.getOrNull()
                            ?: throw CloudTuneException("重定向地址无效")
                        val sameOrigin = Cloud189Protocol.isSameOrigin(initialUri, nextUri) &&
                            Cloud189Protocol.isSameOrigin(uri, nextUri)
                        if (!sameOrigin) {
                            if (!Cloud189Protocol.isTrustedTianyiOrigin(nextUri)) {
                                throw CloudTuneException("拒绝向非受信域名重定向鉴权请求")
                            }
                            if ((status == 307 || status == 308) && currentBody != null) {
                                throw CloudTuneException("拒绝跨源重定向转发鉴权表单请求")
                            }
                            currentHeaders = currentHeaders.filterKeys {
                                it.lowercase(Locale.US) !in SENSITIVE_REDIRECT_HEADERS
                            }
                        }
                        runCatching {
                            conn.inputStream?.use { it.readBytes() }
                            keepAliveReusable = true
                        }
                        currentUrl = nextUri.toString()
                        if (status == 301 || status == 302 || status == 303) {
                            currentMethod = "GET"
                            currentBody = null
                        }
                        redirects += 1
                        continue
                    }
                }

                val bytes = if (status in 200..299) {
                    val payloadBytes = conn.inputStream?.use { it.readBytes() } ?: ByteArray(0)
                    keepAliveReusable = true
                    payloadBytes
                } else if (status in 300..399) {
                    runCatching {
                        val payloadBytes = conn.inputStream?.use { it.readBytes() } ?: ByteArray(0)
                        keepAliveReusable = true
                        payloadBytes
                    }.getOrDefault(ByteArray(0))
                } else {
                    runCatching {
                        val errStream = conn.errorStream
                        val payloadBytes = errStream?.use { it.readBytes() } ?: ByteArray(0)
                        keepAliveReusable = true
                        payloadBytes
                    }.getOrDefault(ByteArray(0))
                }

                val flatHeaders = mutableMapOf<String, String>()
                for ((k, v) in rawHeaders) {
                    if (k != null && !v.isNullOrEmpty()) {
                        flatHeaders[k.lowercase(Locale.US)] = v.last()
                    }
                }
                return@withContext CloudHttpResponse(status, flatHeaders, bytes)
            } finally {
                if (!keepAliveReusable) {
                    runCatching { conn.disconnect() }
                }
            }
        }
        throw CloudTuneException("请求重定向次数过多")
    }

    override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {
        if (cookieHeader.isNullOrBlank()) return
        val uri = runCatching { URI(domainUrl) }.getOrNull() ?: return
        val host = uri.host?.lowercase(java.util.Locale.US)?.trimEnd('.') ?: return
        val isTianyi = host == "cloud.189.cn" ||
            host.endsWith(".cloud.189.cn") ||
            host == "e.189.cn" ||
            host.endsWith(".e.189.cn")
        val isLoopback = host == "127.0.0.1" || host == "localhost"
        if (!isTianyi && !isLoopback) return

        val targetUris = buildList {
            add(uri)
            if (host == "cloud.189.cn" || host.endsWith(".cloud.189.cn")) {
                runCatching { add(URI(Cloud189Constants.API_URL)) }
                runCatching { add(URI(Cloud189Constants.WEB_URL)) }
            }
        }
        synchronized(cookieLock) {
            for (part in cookieHeader.split(";")) {
                val eq = part.indexOf('=')
                if (eq <= 0) continue
                val name = part.substring(0, eq).trim()
                val value = part.substring(eq + 1).trim()
                if (name.isEmpty()) continue
                for (target in targetUris) {
                    val targetHost = target.host ?: continue
                    val cookie = HttpCookie(name, value).apply {
                        domain = targetHost
                        path = "/"
                    }
                    runCatching { cookieManager.cookieStore.add(target, cookie) }
                }
            }
        }
    }

    override fun clearCookies() {
        synchronized(cookieLock) {
            cookieManager = CookieManager(null, CookiePolicy.ACCEPT_ALL)
        }
    }

    companion object {
        private val SENSITIVE_REDIRECT_HEADERS = setOf(
            "sessionkey",
            "signature",
            "authorization",
            "cookie",
            "reqid",
            "lt"
        )
    }
}

class Cloud189Client(
    private val transport: CloudHttpTransport = HttpUrlConnectionTransport()
) {
    private data class PendingQrLogin(
        val lt: String,
        val paramId: String,
        val reqId: String,
        val uuid: String,
        val encryUuid: String
    )

    private val mutex = Mutex()
    private val sessionLock = Any()
    @Volatile var sessionEpoch: Int = 0
        private set
    @Volatile private var authCycleId: Long = 0L
    @Volatile var activeSession: ActiveCloudSession? = null
        private set
    @Volatile var persistedCredential: PersistedRefreshCredential? = null
        private set
    private var pendingQr: PendingQrLogin? = null

    val isAuthenticated: Boolean get() = activeSession != null
    val accountName: String? get() = activeSession?.loginName ?: persistedCredential?.accountName

    fun clearSessionImmediate(expectedEpoch: Int? = null) {
        synchronized(sessionLock) {
            if (expectedEpoch != null && expectedEpoch != sessionEpoch) {
                return
            }
            sessionEpoch += 1
            authCycleId += 1L
            activeSession = null
            persistedCredential = null
            pendingQr = null
            transport.clearCookies()
        }
    }

    fun importWebCookies(domainUrl: String, cookieHeader: String?) {
        transport.importCookieHeader(domainUrl, cookieHeader)
    }

    /** Cold-start restoration: only sets `activeSession` AFTER network exchange succeeds. */
    suspend fun restoreFromRefreshCredential(
        credential: PersistedRefreshCredential
    ): Cloud189Protocol.ParsedSessionPayload =
        restoreFromRefreshCredentialWithEpoch(credential).first

    internal suspend fun restoreFromRefreshCredentialWithEpoch(
        credential: PersistedRefreshCredential
    ): Pair<Cloud189Protocol.ParsedSessionPayload, Int> = mutex.withLock {
        val startEpoch = synchronized(sessionLock) { sessionEpoch }
        val resp = transport.send(
            url = "${Cloud189Constants.AUTH_URL}/api/oauth2/refreshToken.do",
            method = "POST",
            headers = mapOf(
                "Accept" to "application/json;charset=UTF-8",
                "Referer" to Cloud189Constants.REFERER
            ),
            formBody = listOf(
                "clientId" to Cloud189Constants.APP_ID,
                "refreshToken" to credential.refreshToken,
                "grantType" to "refresh_token",
                "format" to "json"
            )
        )
        if (synchronized(sessionLock) { sessionEpoch != startEpoch }) {
            throw CloudTuneException("登录会话已变更，请重试")
        }
        Cloud189Protocol.extractApiErrorMessage(resp.text)?.let { throw CloudTuneException(it) }
        if (resp.statusCode !in 200..299) {
            throw CloudTuneException("刷新登录态失败 (HTTP ${resp.statusCode})")
        }
        val json = runCatching { JSONObject(resp.text) }.getOrElse {
            throw CloudTuneException("刷新登录态失败 (HTTP ${resp.statusCode})")
        }
        val accessToken = Cloud189Protocol.optNonBlank(json, "accessToken")
            ?: throw CloudTuneException("刷新登录态失败，未拿到 accessToken")
        val nextRefresh = Cloud189Protocol.optNonBlank(json, "refreshToken") ?: credential.refreshToken

        val parsed = exchangeAccessTokenUnlocked(
            accessToken = accessToken,
            fallbackRefreshToken = nextRefresh,
            fallbackAccountName = credential.accountName,
            fallbackAccountKey = credential.accountKey
        )
        val committedEpoch = synchronized(sessionLock) {
            if (sessionEpoch != startEpoch) {
                throw CloudTuneException("登录会话已变更，请重试")
            }
            sessionEpoch += 1
            authCycleId += 1L
            activeSession = parsed.activeSession
            persistedCredential = parsed.persistedCredential
            sessionEpoch
        }
        parsed to committedEpoch
    }

    suspend fun startQrLogin(): QrLoginStart = mutex.withLock {
        val startEpoch = synchronized(sessionLock) { sessionEpoch }
        val initResp = transport.send(
            url = Cloud189Protocol.webLoginEntryUrl(),
            method = "GET",
            headers = mapOf("Referer" to Cloud189Constants.REFERER)
        )
        if (synchronized(sessionLock) { sessionEpoch != startEpoch }) {
            throw CloudTuneException("登录会话已变更")
        }
        if (initResp.statusCode !in 200..299) {
            throw CloudTuneException("获取扫码登录页失败 (HTTP ${initResp.statusCode})")
        }
        val params = Cloud189Protocol.extractLoginParameters(initResp.text)

        val uuidResp = transport.send(
            url = "${Cloud189Constants.AUTH_URL}/api/logbox/oauth2/getUUID.do",
            method = "POST",
            headers = mapOf(
                "Accept" to "application/json;charset=UTF-8",
                "Referer" to Cloud189Constants.AUTH_URL
            ),
            formBody = listOf("appId" to Cloud189Constants.APP_ID)
        )
        Cloud189Protocol.extractApiErrorMessage(uuidResp.text)?.let { throw CloudTuneException(it) }
        if (uuidResp.statusCode !in 200..299) {
            throw CloudTuneException("二维码初始化失败 (HTTP ${uuidResp.statusCode})")
        }
        val json = JSONObject(uuidResp.text)
        val uuid = Cloud189Protocol.optNonBlank(json, "uuid") ?: throw CloudTuneException("缺少二维码 uuid")
        val encryUuid = Cloud189Protocol.optNonBlank(json, "encryuuid") ?: throw CloudTuneException("缺少 encryuuid")

        synchronized(sessionLock) {
            if (sessionEpoch != startEpoch) {
                throw CloudTuneException("登录会话已变更")
            }
            pendingQr = PendingQrLogin(params.lt, params.paramId, params.reqId, uuid, encryUuid)
        }
        QrLoginStart(qrContent = uuid, message = "请使用天翼云盘 App 扫码，并在手机端确认登录")
    }

    suspend fun pollQrLogin(): QrPollResponse =
        pollQrLoginWithEpoch().first

    internal suspend fun pollQrLoginWithEpoch(): Pair<QrPollResponse, Int?> = mutex.withLock {
        val (pending, startEpoch) = synchronized(sessionLock) {
            (pendingQr ?: throw CloudTuneException("请先生成二维码，再轮询登录状态")) to sessionEpoch
        }
        val resp = transport.send(
            url = "${Cloud189Constants.AUTH_URL}/api/logbox/oauth2/qrcodeLoginState.do",
            method = "POST",
            headers = mapOf(
                "Accept" to "application/json;charset=UTF-8",
                "Referer" to Cloud189Constants.AUTH_URL,
                "Reqid" to pending.reqId,
                "lt" to pending.lt
            ),
            formBody = listOf(
                "appId" to Cloud189Constants.APP_ID,
                "clientType" to Cloud189Constants.CLIENT_TYPE,
                "returnUrl" to Cloud189Constants.RETURN_URL,
                "paramId" to pending.paramId,
                "uuid" to pending.uuid,
                "encryuuid" to pending.encryUuid,
                "date" to Cloud189Protocol.formatQrPollDate(),
                "timeStamp" to System.currentTimeMillis().toString()
            )
        )
        if (synchronized(sessionLock) { sessionEpoch != startEpoch }) {
            throw CloudTuneException("登录会话已变更")
        }
        if (resp.statusCode !in 200..299) {
            throw CloudTuneException("二维码轮询请求失败 (HTTP ${resp.statusCode})")
        }
        val parsed = Cloud189Protocol.parseQrPollPayload(resp.text, resp.statusCode)
        when (parsed.state) {
            QrLoginState.AUTHENTICATED -> {
                val redirect = parsed.redirectUrl ?: throw CloudTuneException("缺少扫码跳转链接")
                val (sessionResult, committedEpoch) = exchangeRedirectUnlocked(redirect, startEpoch)
                synchronized(sessionLock) {
                    if (pendingQr === pending) {
                        pendingQr = null
                    }
                }
                parsed.copy(accountName = sessionResult.activeSession.loginName) to committedEpoch
            }
            QrLoginState.EXPIRED -> {
                synchronized(sessionLock) {
                    if (pendingQr === pending) {
                        pendingQr = null
                    }
                }
                parsed to null
            }
            QrLoginState.WAITING_SCAN, QrLoginState.WAITING_CONFIRM -> parsed to null
        }
    }

    suspend fun exchangeRedirectForSession(redirectUrl: String): Cloud189Protocol.ParsedSessionPayload =
        exchangeRedirectForSessionWithEpoch(redirectUrl).first

    internal suspend fun exchangeRedirectForSessionWithEpoch(
        redirectUrl: String
    ): Pair<Cloud189Protocol.ParsedSessionPayload, Int> = mutex.withLock {
        val startEpoch = synchronized(sessionLock) { sessionEpoch }
        exchangeRedirectUnlocked(redirectUrl, startEpoch)
    }

    suspend fun listRemoteFolder(
        folderId: String?,
        folderName: String? = null,
        folderPath: String? = null
    ): FolderBrowsePayload {
        val isRoot = folderId == null || folderId == Cloud189Constants.ROOT_FOLDER_ID
        val targetId = folderId ?: Cloud189Constants.ROOT_FOLDER_ID
        val resolvedFolderName: String
        val resolvedFolderPath: String
        if (isRoot) {
            resolvedFolderName = Cloud189Constants.ROOT_FOLDER_NAME
            resolvedFolderPath = Cloud189Constants.ROOT_FOLDER_NAME
        } else {
            val trimmedName = folderName?.trim()?.takeIf { it.isNotEmpty() }
            val trimmedPath = folderPath?.trim()?.takeIf { it.isNotEmpty() }
            val leafFromPath = trimmedPath?.substringAfterLast('/')?.trim()?.takeIf { it.isNotEmpty() }
            resolvedFolderName = trimmedName ?: leafFromPath ?: targetId
            resolvedFolderPath = trimmedPath ?: resolvedFolderName
        }

        val folders = mutableListOf<RemoteFolder>()
        val audioFiles = mutableListOf<TrackSummary>()
        val videoFiles = mutableListOf<TrackSummary>()
        val otherFiles = mutableListOf<TrackSummary>()

        var pageNum = 1
        while (pageNum <= 200) {
            val json = signedGetJson(
                path = "/listFiles.action",
                query = listOf(
                    "folderId" to targetId,
                    "fileType" to "0",
                    "mediaAttr" to "0",
                    "iconOption" to "5",
                    "pageNum" to pageNum.toString(),
                    "pageSize" to "1000",
                    "recursive" to "0",
                    "orderBy" to "filename",
                    "descending" to "false"
                )
            )
            val ao = json.optJSONObject("fileListAO")
                ?: throw CloudTuneException("云盘目录响应缺少 fileListAO 字段")
            if (!ao.has("count") && !ao.has("folderList") && !ao.has("fileList")) {
                throw CloudTuneException("云盘目录 fileListAO 结构无效")
            }
            val folderArr = ao.optJSONArray("folderList") ?: JSONArray()
            val fileArr = ao.optJSONArray("fileList") ?: JSONArray()
            if (ao.optInt("count", 0) == 0 && folderArr.length() == 0 && fileArr.length() == 0) break
            if (folderArr.length() == 0 && fileArr.length() == 0) break

            for (i in 0 until folderArr.length()) {
                val o = folderArr.getJSONObject(i)
                val id = Cloud189Protocol.optNonBlank(o, "id") ?: continue
                val name = Cloud189Protocol.optNonBlank(o, "name") ?: continue
                folders += RemoteFolder(id, name, Cloud189Protocol.optNonBlank(o, "parentId"))
            }
            for (i in 0 until fileArr.length()) {
                val o = fileArr.getJSONObject(i)
                val id = Cloud189Protocol.optNonBlank(o, "id") ?: continue
                val name = Cloud189Protocol.optNonBlank(o, "name") ?: continue
                val track = TrackSummary(
                    id = id,
                    name = name,
                    folderPath = resolvedFolderPath,
                    sizeBytes = o.optLong("size", 0L).coerceAtLeast(0L),
                    modifiedAt = Cloud189Protocol.optNonBlank(o, "lastOpTime")
                )
                when {
                    Cloud189Protocol.isAudioFile(name) -> audioFiles += track
                    Cloud189Protocol.isVideoFile(name) -> videoFiles += track
                    else -> otherFiles += track
                }
            }
            if (folderArr.length() + fileArr.length() < 1000) break
            pageNum += 1
        }

        folders.sortBy { it.name.lowercase() }
        audioFiles.sortBy { it.name.lowercase() }
        videoFiles.sortBy { it.name.lowercase() }
        otherFiles.sortBy { it.name.lowercase() }

        return FolderBrowsePayload(
            currentFolderId = targetId,
            currentFolderName = resolvedFolderName,
            parentFolderId = null,
            isRoot = isRoot,
            folders = folders,
            audioFiles = audioFiles,
            videoFiles = videoFiles,
            otherFiles = otherFiles
        )
    }

    suspend fun scanMusicLibrary(folderId: String, folderName: String): List<TrackSummary> =
        scanRecursive(folderId, folderName, audioOnly = true)

    suspend fun scanAllFiles(folderId: String, folderName: String): List<TrackSummary> =
        scanRecursive(folderId, folderName, audioOnly = false)

    suspend fun resolveDownloadUrl(fileId: String): String {
        val json = signedGetJson(
            path = "/getFileDownloadUrl.action",
            query = listOf("fileId" to fileId, "dt" to "3", "flag" to "1")
        )
        val raw = Cloud189Protocol.optNonBlank(json, "fileDownloadUrl")
            ?: throw CloudTuneException("没有获取到文件下载地址")
        return raw.replace("&amp;", "&").let {
            if (it.startsWith("http://")) "https://" + it.removePrefix("http://") else it
        }
    }

    private suspend fun scanRecursive(
        folderId: String,
        folderName: String,
        audioOnly: Boolean
    ): List<TrackSummary> = coroutineScope {
        val scanSemaphore = Semaphore(MAX_SCAN_CONCURRENCY)
        val collected = Collections.synchronizedList(mutableListOf<TrackSummary>())

        suspend fun visitFolder(currId: String, currPath: String) {
            val leafName = currPath.substringAfterLast('/')
            val listing = scanSemaphore.withPermit {
                listRemoteFolder(folderId = currId, folderName = leafName, folderPath = currPath)
            }
            val files = if (audioOnly) {
                listing.audioFiles
            } else {
                listing.audioFiles + listing.videoFiles + listing.otherFiles
            }
            if (files.isNotEmpty()) {
                synchronized(collected) {
                    for (item in files) {
                        collected += item.copy(folderPath = currPath)
                    }
                }
            }
            if (listing.folders.isNotEmpty()) {
                coroutineScope {
                    listing.folders.map { sub ->
                        async {
                            visitFolder(sub.id, "$currPath/${sub.name}")
                        }
                    }.awaitAll()
                }
            }
        }

        visitFolder(folderId, folderName)
        collected.sortedWith(
            compareBy<TrackSummary> { "${it.folderPath}/${it.name}".lowercase(Locale.ROOT) }
                .thenBy { "${it.folderPath}/${it.name}" }
                .thenBy { it.id }
        )
    }

    private suspend fun exchangeRedirectUnlocked(
        redirectUrl: String,
        expectedEpoch: Int
    ): Pair<Cloud189Protocol.ParsedSessionPayload, Int> {
        val query = buildQuery(clientSuffix() + ("redirectURL" to redirectUrl))
        val resp = transport.send(
            url = "${Cloud189Constants.API_URL}/getSessionForPC.action?$query",
            method = "POST",
            headers = mapOf(
                "Accept" to "application/json;charset=UTF-8",
                "Referer" to Cloud189Constants.REFERER
            )
        )
        if (synchronized(sessionLock) { sessionEpoch != expectedEpoch }) {
            throw CloudTuneException("登录会话已变更，请重试")
        }
        if (resp.statusCode !in 200..299) {
            Cloud189Protocol.extractApiErrorMessage(resp.text)?.let { throw CloudTuneException(it) }
            throw CloudTuneException("会话兑换失败 (HTTP ${resp.statusCode})")
        }
        val parsed = Cloud189Protocol.parseSessionResponse(
            body = resp.text,
            statusCode = resp.statusCode
        )
        val committedEpoch = synchronized(sessionLock) {
            if (sessionEpoch != expectedEpoch) {
                throw CloudTuneException("登录会话已变更，请重试")
            }
            sessionEpoch += 1
            authCycleId += 1L
            activeSession = parsed.activeSession
            persistedCredential = parsed.persistedCredential
            sessionEpoch
        }
        return parsed to committedEpoch
    }

    private suspend fun exchangeAccessTokenUnlocked(
        accessToken: String,
        fallbackRefreshToken: String,
        fallbackAccountName: String?,
        fallbackAccountKey: String? = null
    ): Cloud189Protocol.ParsedSessionPayload {
        val query = buildQuery(
            clientSuffix() + listOf(
                "appId" to Cloud189Constants.APP_ID,
                "accessToken" to accessToken
            )
        )
        val resp = transport.send(
            url = "${Cloud189Constants.API_URL}/getSessionForPC.action?$query",
            method = "GET",
            headers = mapOf(
                "Accept" to "application/json;charset=UTF-8",
                "Referer" to Cloud189Constants.REFERER,
                "X-Request-ID" to UUID.randomUUID().toString()
            )
        )
        if (resp.statusCode !in 200..299) {
            Cloud189Protocol.extractApiErrorMessage(resp.text)?.let { throw CloudTuneException(it) }
            throw CloudTuneException("会话刷新失败 (HTTP ${resp.statusCode})")
        }
        return Cloud189Protocol.parseSessionResponse(
            body = resp.text,
            statusCode = resp.statusCode,
            fallbackAccessToken = accessToken,
            fallbackRefreshToken = fallbackRefreshToken,
            fallbackAccountName = fallbackAccountName,
            fallbackAccountKey = fallbackAccountKey
        )
    }

    private suspend fun signedGetJson(path: String, query: List<Pair<String, String>>): JSONObject {
        for (attempt in 0 until 2) {
            val (session, requestEpoch, requestAuthCycle) = synchronized(sessionLock) {
                val active = activeSession ?: throw CloudTuneException("请先登录天翼云盘")
                Triple(active, sessionEpoch, authCycleId)
            }
            val fullQuery = buildQuery(clientSuffix() + query)
            val fullUrl = "${Cloud189Constants.API_URL}$path?$fullQuery"
            val dateHeader = Cloud189Protocol.formatHttpDate()
            val (_, signature) = Cloud189Protocol.computeSignature(
                sessionKey = session.sessionKey,
                sessionSecret = session.sessionSecret,
                method = "GET",
                urlString = fullUrl,
                dateHeader = dateHeader
            )
            val resp = transport.send(
                url = fullUrl,
                method = "GET",
                headers = mapOf(
                    "Accept" to "application/json;charset=UTF-8",
                    "Referer" to Cloud189Constants.REFERER,
                    "Date" to dateHeader,
                    "SessionKey" to session.sessionKey,
                    "X-Request-ID" to UUID.randomUUID().toString(),
                    "Signature" to signature
                )
            )
            val body = resp.text
            if (body.contains("userSessionBO is null") || body.contains("InvalidSessionKey")) {
                if (attempt == 0 && session.accessToken.isNotEmpty()) {
                    var shouldRetry = false
                    mutex.withLock {
                        var currentEpoch = 0
                        var currentAuthCycle = 0L
                        var currentActive: ActiveCloudSession? = null
                        var fallbackCred: PersistedRefreshCredential? = null
                        synchronized(sessionLock) {
                            currentEpoch = sessionEpoch
                            currentAuthCycle = authCycleId
                            currentActive = activeSession
                            fallbackCred = persistedCredential
                        }
                        if (currentAuthCycle != requestAuthCycle || currentActive == null) {
                            shouldRetry = false
                        } else if (currentEpoch != requestEpoch) {
                            shouldRetry = true
                        } else {
                            val refreshed = exchangeAccessTokenUnlocked(
                                accessToken = session.accessToken,
                                fallbackRefreshToken = fallbackCred?.refreshToken.orEmpty(),
                                fallbackAccountName = session.loginName,
                                fallbackAccountKey = fallbackCred?.accountKey
                            )
                            synchronized(sessionLock) {
                                if (sessionEpoch != requestEpoch || authCycleId != requestAuthCycle) {
                                    throw CloudTuneException("天翼云盘会话已失效，请重新登录", isSessionExpired = true)
                                }
                                sessionEpoch += 1
                                activeSession = refreshed.activeSession
                                persistedCredential = refreshed.persistedCredential
                            }
                            shouldRetry = true
                        }
                    }
                    if (shouldRetry) {
                        continue
                    }
                }
                throw CloudTuneException("天翼云盘会话已失效，请重新登录", isSessionExpired = true)
            }
            Cloud189Protocol.extractApiErrorMessage(body)?.let { throw CloudTuneException(it) }
            if (resp.statusCode !in 200..299) {
                throw CloudTuneException("读取天翼云盘接口失败 (HTTP ${resp.statusCode})")
            }
            return runCatching { JSONObject(body) }.getOrElse {
                throw CloudTuneException("读取天翼云盘接口失败 (HTTP ${resp.statusCode})")
            }
        }
        throw CloudTuneException("天翼云盘会话已失效，请重新登录", isSessionExpired = true)
    }

    private fun clientSuffix(): List<Pair<String, String>> = listOf(
        "clientType" to Cloud189Constants.PC_CLIENT,
        "version" to Cloud189Constants.VERSION,
        "channelId" to Cloud189Constants.CHANNEL_ID,
        "rand" to "${Random.nextInt(0, 100_000)}_${Random.nextLong(0L, 10_000_000_000L)}"
    )

    private fun buildQuery(pairs: List<Pair<String, String>>): String =
        pairs.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }

    companion object {
        private const val MAX_SCAN_CONCURRENCY = 4
    }
}
