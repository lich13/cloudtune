package com.gosu.cloudtune.core

import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpCookie
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.util.UUID
import kotlin.random.Random
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class CloudHttpResponse(
    val statusCode: Int,
    val headers: Map<String, String>,
    val body: ByteArray,
    val finalUrl: String
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

    override suspend fun send(
        url: String,
        method: String,
        headers: Map<String, String>,
        formBody: List<Pair<String, String>>?
    ): CloudHttpResponse = withContext(Dispatchers.IO) {
        var currentUrl = url
        var currentMethod = method
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
                setRequestProperty("Connection", "close")
            }

            val cookieValue = synchronized(cookieLock) {
                cookieManager.cookieStore.get(uri)
                    .joinToString("; ") { "${it.name}=${it.value}" }
            }
            if (cookieValue.isNotEmpty()) {
                conn.setRequestProperty("Cookie", cookieValue)
            }
            for ((k, v) in headers) {
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
            synchronized(cookieLock) {
                val cookieHeaders = rawHeaders.filterKeys { it != null }.mapKeys { it.key!! }
                runCatching { cookieManager.put(uri, cookieHeaders) }
            }

            if (status in listOf(301, 302, 303, 307, 308)) {
                val location = conn.getHeaderField("Location")
                conn.disconnect()
                if (!location.isNullOrBlank()) {
                    currentUrl = URI(currentUrl).resolve(location).toString()
                    if (status == 301 || status == 302 || status == 303) {
                        currentMethod = "GET"
                        currentBody = null
                    }
                    redirects += 1
                    continue
                }
            }

            val bytes = runCatching {
                val stream = if (status in 200..399) conn.inputStream else (conn.errorStream ?: conn.inputStream)
                stream?.use { it.readBytes() } ?: ByteArray(0)
            }.getOrDefault(ByteArray(0))

            val flatHeaders = mutableMapOf<String, String>()
            for ((k, v) in rawHeaders) {
                if (k != null && !v.isNullOrEmpty()) {
                    flatHeaders[k.lowercase()] = v.last()
                }
            }
            conn.disconnect()
            return@withContext CloudHttpResponse(status, flatHeaders, bytes, currentUrl)
        }
        throw CloudTuneException("请求重定向次数过多")
    }

    override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {
        if (cookieHeader.isNullOrBlank()) return
        val uri = runCatching { URI(domainUrl) }.getOrNull() ?: return
        val host = uri.host ?: return
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
    @Volatile var activeSession: ActiveCloudSession? = null
        private set
    @Volatile var persistedCredential: PersistedRefreshCredential? = null
        private set
    private var pendingQr: PendingQrLogin? = null

    val isAuthenticated: Boolean get() = activeSession != null
    val accountName: String? get() = activeSession?.loginName ?: persistedCredential?.accountName

    suspend fun clearSession() = mutex.withLock {
        activeSession = null
        persistedCredential = null
        pendingQr = null
        transport.clearCookies()
    }

    fun importWebCookies(domainUrl: String, cookieHeader: String?) {
        transport.importCookieHeader(domainUrl, cookieHeader)
    }

    /** Cold-start restoration: only sets `activeSession` AFTER network exchange succeeds. */
    suspend fun restoreFromRefreshCredential(
        credential: PersistedRefreshCredential
    ): Cloud189Protocol.ParsedSessionPayload = mutex.withLock {
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
        Cloud189Protocol.extractApiErrorMessage(resp.text)?.let { throw CloudTuneException(it) }
        val json = runCatching { JSONObject(resp.text) }.getOrElse {
            throw CloudTuneException("刷新登录态失败 (HTTP ${resp.statusCode})")
        }
        val accessToken = Cloud189Protocol.optNonBlank(json, "accessToken")
            ?: throw CloudTuneException("刷新登录态失败，未拿到 accessToken")
        val nextRefresh = Cloud189Protocol.optNonBlank(json, "refreshToken") ?: credential.refreshToken

        val parsed = exchangeAccessTokenUnlocked(
            accessToken = accessToken,
            fallbackRefreshToken = nextRefresh,
            fallbackAccountName = credential.accountName
        )
        activeSession = parsed.activeSession
        persistedCredential = parsed.persistedCredential
        parsed
    }

    suspend fun startQrLogin(): QrLoginStart = mutex.withLock {
        val initResp = transport.send(
            url = Cloud189Protocol.webLoginEntryUrl(),
            method = "GET",
            headers = mapOf("Referer" to Cloud189Constants.REFERER)
        )
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
        val json = JSONObject(uuidResp.text)
        val uuid = Cloud189Protocol.optNonBlank(json, "uuid") ?: throw CloudTuneException("缺少二维码 uuid")
        val encryUuid = Cloud189Protocol.optNonBlank(json, "encryuuid") ?: throw CloudTuneException("缺少 encryuuid")

        pendingQr = PendingQrLogin(params.lt, params.paramId, params.reqId, uuid, encryUuid)
        QrLoginStart(qrContent = uuid, message = "请使用天翼云盘 App 扫码，并在手机端确认登录")
    }

    suspend fun pollQrLogin(): QrPollResponse = mutex.withLock {
        val pending = pendingQr ?: throw CloudTuneException("请先生成二维码，再轮询登录状态")
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
        val parsed = Cloud189Protocol.parseQrPollPayload(resp.text, resp.statusCode)
        when (parsed.state) {
            QrLoginState.AUTHENTICATED -> {
                val redirect = parsed.redirectUrl ?: throw CloudTuneException("缺少扫码跳转链接")
                val sessionResult = exchangeRedirectUnlocked(redirect)
                pendingQr = null
                parsed.copy(accountName = sessionResult.activeSession.loginName)
            }
            QrLoginState.EXPIRED -> {
                pendingQr = null
                parsed
            }
            QrLoginState.WAITING_SCAN, QrLoginState.WAITING_CONFIRM -> parsed
        }
    }

    suspend fun exchangeRedirectForSession(redirectUrl: String): Cloud189Protocol.ParsedSessionPayload =
        mutex.withLock { exchangeRedirectUnlocked(redirectUrl) }

    suspend fun listRemoteFolder(folderId: String?): FolderBrowsePayload {
        val isRoot = folderId == null || folderId == Cloud189Constants.ROOT_FOLDER_ID
        val targetId = folderId ?: Cloud189Constants.ROOT_FOLDER_ID
        val folderTitle = if (targetId == Cloud189Constants.ROOT_FOLDER_ID) Cloud189Constants.ROOT_FOLDER_NAME else "当前目录"

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
            val ao = json.optJSONObject("fileListAO") ?: break
            if (ao.optInt("count", 0) == 0) break
            val folderArr = ao.optJSONArray("folderList") ?: JSONArray()
            val fileArr = ao.optJSONArray("fileList") ?: JSONArray()
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
                    folderPath = folderTitle,
                    sizeBytes = o.optLong("size", 0L),
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
            currentFolderName = folderTitle,
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

    private suspend fun scanRecursive(folderId: String, folderName: String, audioOnly: Boolean): List<TrackSummary> {
        val queue = ArrayDeque<Pair<String, String>>()
        queue.addLast(folderId to folderName)
        val out = mutableListOf<TrackSummary>()

        while (queue.isNotEmpty()) {
            val (currId, currPath) = queue.removeFirst()
            val listing = listRemoteFolder(currId)
            for (f in listing.folders) {
                queue.addLast(f.id to "$currPath/${f.name}")
            }
            val files = if (audioOnly) listing.audioFiles else (listing.audioFiles + listing.videoFiles + listing.otherFiles)
            for (item in files) {
                out += item.copy(folderPath = currPath)
            }
        }
        return out.sortedBy { "${it.folderPath}/${it.name}".lowercase() }
    }

    private suspend fun exchangeRedirectUnlocked(redirectUrl: String): Cloud189Protocol.ParsedSessionPayload {
        val query = buildQuery(clientSuffix() + ("redirectURL" to redirectUrl))
        val resp = transport.send(
            url = "${Cloud189Constants.API_URL}/getSessionForPC.action?$query",
            method = "POST",
            headers = mapOf(
                "Accept" to "application/json;charset=UTF-8",
                "Referer" to Cloud189Constants.REFERER
            )
        )
        val parsed = Cloud189Protocol.parseSessionResponse(
            body = resp.text,
            statusCode = resp.statusCode,
            fallbackAccessToken = activeSession?.accessToken.orEmpty(),
            fallbackRefreshToken = persistedCredential?.refreshToken.orEmpty(),
            fallbackAccountName = activeSession?.loginName
        )
        activeSession = parsed.activeSession
        persistedCredential = parsed.persistedCredential
        return parsed
    }

    private suspend fun exchangeAccessTokenUnlocked(
        accessToken: String,
        fallbackRefreshToken: String,
        fallbackAccountName: String?
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
        return Cloud189Protocol.parseSessionResponse(
            body = resp.text,
            statusCode = resp.statusCode,
            fallbackAccessToken = accessToken,
            fallbackRefreshToken = fallbackRefreshToken,
            fallbackAccountName = fallbackAccountName
        )
    }

    private suspend fun signedGetJson(path: String, query: List<Pair<String, String>>): JSONObject {
        repeat(2) { attempt ->
            val session = activeSession ?: throw CloudTuneException("请先登录天翼云盘")
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
                    mutex.withLock {
                        val refreshed = exchangeAccessTokenUnlocked(
                            accessToken = session.accessToken,
                            fallbackRefreshToken = persistedCredential?.refreshToken.orEmpty(),
                            fallbackAccountName = session.loginName
                        )
                        activeSession = refreshed.activeSession
                        persistedCredential = refreshed.persistedCredential
                    }
                    return@repeat
                }
                throw CloudTuneException("天翼云盘会话已失效，请重新登录", isSessionExpired = true)
            }
            Cloud189Protocol.extractApiErrorMessage(body)?.let { throw CloudTuneException(it) }
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
}
