package com.gosu.cloudtune.core

import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

class CloudTuneException(message: String, val isSessionExpired: Boolean = false) : Exception(message)

object Cloud189Constants {
    const val ROOT_FOLDER_ID = "-11"
    const val ROOT_FOLDER_NAME = "我的云盘"
    const val WEB_URL = "https://cloud.189.cn"
    const val AUTH_URL = "https://open.e.189.cn"
    const val API_URL = "https://api.cloud.189.cn"
    const val APP_ID = "8025431004"
    const val CLIENT_TYPE = "10020"
    const val RETURN_URL = "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html"
    const val PC_CLIENT = "TELEPC"
    const val VERSION = "6.2"
    const val CHANNEL_ID = "web_cloud.189.cn"
    const val USER_AGENT = "CloudTune/1.0.0"
    const val REFERER = "https://cloud.189.cn/"
}

object Cloud189Protocol {
    data class LoginPageParameters(val lt: String, val paramId: String, val reqId: String)

    data class ParsedSessionPayload(
        val activeSession: ActiveCloudSession,
        val persistedCredential: PersistedRefreshCredential?
    )

    private val httpDateFormatter = DateTimeFormatter
        .ofPattern("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US)
        .withZone(ZoneOffset.UTC)

    private val qrPollDateFormatter = DateTimeFormatter
        .ofPattern("yyyy-MM-ddHH:mm:ss.SSS", Locale.US)

    fun webLoginEntryUrl(timestampMillis: Long = System.currentTimeMillis()): String {
        val encodedReturn = URLEncoder.encode(Cloud189Constants.RETURN_URL, Charsets.UTF_8.name())
        return "${Cloud189Constants.WEB_URL}/api/portal/unifyLoginForPC.action" +
            "?appId=${Cloud189Constants.APP_ID}" +
            "&clientType=${Cloud189Constants.CLIENT_TYPE}" +
            "&returnURL=$encodedReturn" +
            "&timeStamp=$timestampMillis"
    }

    fun isInterceptableWebLoginCallback(rawUrl: String): Boolean {
        val uri = runCatching { URI(rawUrl) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase(Locale.US) ?: return false
        if (scheme != "https" && scheme != "http") return false
        val host = uri.host?.lowercase(Locale.US) ?: return false
        val path = uri.path.orEmpty()
        val query = uri.rawQuery.orEmpty()

        if (host == "m.cloud.189.cn" && path.contains("/loginErrorPc/") && query.isNotEmpty()) {
            return true
        }
        if (host == "cloud.189.cn") {
            if (path.contains("unifyLoginForPC.action")) return false
            if (path.contains("udb_login.jsp") || path.contains("callbackUnify.action")) {
                return query.isNotEmpty()
            }
            if (query.contains("paras=") || query.contains("ticket=")) {
                return true
            }
        }
        return false
    }

    fun formatHttpDate(instant: Instant = Instant.now()): String = httpDateFormatter.format(instant)

    fun formatQrPollDate(
        instant: Instant = Instant.now(),
        zoneId: ZoneId = ZoneId.systemDefault()
    ): String = qrPollDateFormatter.format(ZonedDateTime.ofInstant(instant, zoneId))

    fun computeSignature(
        sessionKey: String,
        sessionSecret: String,
        method: String,
        urlString: String,
        dateHeader: String
    ): Pair<String, String> {
        val uri = URI(urlString)
        val requestUri = uri.path?.takeIf { it.isNotEmpty() }
            ?: throw CloudTuneException("无效的请求地址")
        val payload = "SessionKey=$sessionKey&Operate=$method&RequestURI=$requestUri&Date=$dateHeader"
        val mac = Mac.getInstance("HmacSHA1")
        mac.init(SecretKeySpec(sessionSecret.toByteArray(Charsets.UTF_8), "HmacSHA1"))
        val bytes = mac.doFinal(payload.toByteArray(Charsets.UTF_8))
        val hex = bytes.joinToString("") { "%02X".format(Locale.US, it) }
        return requestUri to hex
    }

    /** Uses word boundaries (`\blt\b`) so HTML attributes like `alt="二维码登录成功"` never match `lt`. */
    fun extractLoginParameters(html: String): LoginPageParameters {
        fun extract(regex: Regex, label: String): String =
            regex.find(html)?.groupValues?.getOrNull(1)?.takeIf { it.isNotEmpty() }
                ?: throw CloudTuneException("登录页面中缺少 $label")

        val lt = extract(Regex("""\blt\s*=\s*["']([^"']+)["']"""), "lt")
        val paramId = extract(Regex("""\bparamId\s*=\s*["']([^"']+)["']"""), "paramId")
        val reqId = extract(Regex("""\breqId\s*=\s*["']([^"']+)["']"""), "reqId")
        return LoginPageParameters(lt = lt, paramId = paramId, reqId = reqId)
    }

    fun parseQrPollPayload(body: String, statusCode: Int): QrPollResponse {
        val cleaned = normalizeBody(body)
        if (cleaned.isEmpty()) {
            throw CloudTuneException("二维码轮询返回空响应，HTTP $statusCode")
        }
        val json = runCatching { JSONObject(cleaned) }.getOrElse {
            throw CloudTuneException("二维码轮询返回的不是可解析 JSON，HTTP $statusCode")
        }
        if (!json.has("status")) {
            throw CloudTuneException("二维码轮询缺少 status 字段")
        }
        return when (val status = json.getInt("status")) {
            0 -> {
                val redirect = optNonBlank(json, "redirectUrl")
                    ?: optNonBlank(json, "redirectURL")
                    ?: optNonBlank(json, "toUrl")
                    ?: throw CloudTuneException("二维码登录成功，但没有返回跳转链接")
                QrPollResponse(QrLoginState.AUTHENTICATED, "扫码登录成功", redirectUrl = redirect)
            }
            -106 -> QrPollResponse(QrLoginState.WAITING_SCAN, "二维码已生成，等待手机扫码")
            -11002 -> QrPollResponse(QrLoginState.WAITING_CONFIRM, "手机已扫码，等待你在 App 里确认登录")
            -11001 -> QrPollResponse(QrLoginState.EXPIRED, "二维码已过期，请重新生成")
            else -> throw CloudTuneException("二维码登录失败 (status=$status): ${optNonBlank(json, "msg") ?: "未知错误"}")
        }
    }

    fun parseSessionResponse(
        body: String,
        statusCode: Int,
        fallbackAccessToken: String = "",
        fallbackRefreshToken: String = "",
        fallbackAccountName: String? = null
    ): ParsedSessionPayload {
        val cleaned = normalizeBody(body)
        if (cleaned.isEmpty()) {
            throw CloudTuneException("会话接口返回空响应，HTTP $statusCode")
        }
        if (cleaned.startsWith("<")) {
            val loginName = extractXmlTag("loginName", cleaned) ?: fallbackAccountName
            val sessionKey = extractXmlTag("sessionKey", cleaned).orEmpty()
            val sessionSecret = extractXmlTag("sessionSecret", cleaned).orEmpty()
            val active = ActiveCloudSession.createOrNull(
                accessToken = fallbackAccessToken,
                sessionKey = sessionKey,
                sessionSecret = sessionSecret,
                loginName = loginName
            ) ?: throw CloudTuneException("189CloudPC XML 会话初始化失败，sessionKey 为空")
            val persisted = PersistedRefreshCredential.createOrNull(fallbackRefreshToken, active.loginName)
            return ParsedSessionPayload(active, persisted)
        }

        extractApiErrorMessage(cleaned)?.let { throw CloudTuneException(it) }
        val json = runCatching { JSONObject(cleaned) }.getOrElse {
            throw CloudTuneException("会话接口返回非预期响应，HTTP $statusCode")
        }
        val accessToken = optNonBlank(json, "accessToken") ?: fallbackAccessToken
        val refreshToken = optNonBlank(json, "refreshToken") ?: fallbackRefreshToken
        val loginName = optNonBlank(json, "loginName") ?: fallbackAccountName
        val sessionKey = optNonBlank(json, "sessionKey").orEmpty()
        val sessionSecret = optNonBlank(json, "sessionSecret").orEmpty()

        val active = ActiveCloudSession.createOrNull(
            accessToken = accessToken,
            sessionKey = sessionKey,
            sessionSecret = sessionSecret,
            loginName = loginName
        ) ?: throw CloudTuneException("189CloudPC 会话初始化失败，sessionKey 为空")
        val persisted = PersistedRefreshCredential.createOrNull(refreshToken, active.loginName)
        return ParsedSessionPayload(active, persisted)
    }

    fun extractApiErrorMessage(body: String): String? {
        val json = runCatching { JSONObject(normalizeBody(body)) }.getOrNull() ?: return null
        if (json.has("res_code") && !json.isNull("res_code")) {
            val raw = json.get("res_code").toString().trim()
            if (raw.isNotEmpty() && raw != "0") {
                return optNonBlank(json, "res_message")
                    ?: optNonBlank(json, "msg")
                    ?: optNonBlank(json, "message")
                    ?: "189Cloud error $raw"
            }
        }
        optNonBlank(json, "errorCode")?.let { code ->
            return optNonBlank(json, "errorMsg") ?: optNonBlank(json, "msg") ?: optNonBlank(json, "message") ?: code
        }
        optNonBlank(json, "code")?.let { code ->
            if (code != "SUCCESS") {
                return optNonBlank(json, "msg") ?: optNonBlank(json, "message") ?: code
            }
        }
        optNonBlank(json, "error")?.let { err ->
            return optNonBlank(json, "message") ?: optNonBlank(json, "msg") ?: err
        }
        return null
    }

    fun accountBucketHash(accountId: String): String {
        val normalized = accountId.trim().lowercase(Locale.ROOT)
        val digest = MessageDigest.getInstance("SHA-256").digest(normalized.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(Locale.US, it) }
    }

    fun sanitizeFileName(raw: String): String {
        val cleaned = buildString(raw.length) {
            for (ch in raw) {
                if (ch in "/\\:*?\"<>|" || ch.isISOControl()) append('_') else append(ch)
            }
        }.trim()
        return cleaned.ifEmpty { "track.bin" }
    }

    fun isAudioFile(name: String): Boolean {
        val lower = name.lowercase(Locale.ROOT)
        return listOf(".mp3", ".flac", ".wav", ".m4a", ".aac", ".ogg", ".opus", ".ape", ".wma", ".alac")
            .any { lower.endsWith(it) }
    }

    fun isVideoFile(name: String): Boolean {
        val lower = name.lowercase(Locale.ROOT)
        return listOf(".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".wmv", ".flv", ".mpeg", ".mpg")
            .any { lower.endsWith(it) }
    }

    internal fun optNonBlank(json: JSONObject, key: String): String? {
        if (!json.has(key) || json.isNull(key)) return null
        val text = json.opt(key)?.toString()?.trim().orEmpty()
        return text.takeIf { it.isNotEmpty() }
    }

    private fun normalizeBody(raw: String): String =
        raw.trim().removePrefix("\uFEFF").trim()

    private fun extractXmlTag(tag: String, xml: String): String? {
        val regex = Regex("<$tag>\\s*(?:<!\\[CDATA\\[([\\s\\S]*?)]]>|([^<]*))\\s*</$tag>")
        val match = regex.find(xml) ?: return null
        return (match.groupValues.getOrNull(1)?.takeIf { it.isNotEmpty() }
            ?: match.groupValues.getOrNull(2))?.trim()?.takeIf { it.isNotEmpty() }
    }
}
