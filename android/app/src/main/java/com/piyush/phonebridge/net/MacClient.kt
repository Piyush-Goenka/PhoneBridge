package com.piyush.phonebridge.net

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

class MacClient(private val token: String, fingerprintHex: String) {

    sealed interface SendResult {
        data class Ok(val needIcon: Boolean) : SendResult
        object AuthFailed : SendResult
        data class Failed(val reason: String) : SendResult
    }

    sealed interface WaitResult {
        data class Action(val action: String) : WaitResult
        data class Failed(val reason: String) : WaitResult
    }

    private val jsonType = "application/json".toMediaType()
    private val client: OkHttpClient

    init {
        val pin = fingerprintHex.lowercase()
        val trustManager = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
                throw CertificateException("client certificates not supported")
            }

            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val leaf = chain.firstOrNull()
                    ?: throw CertificateException("empty certificate chain")
                val fp = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
                    .joinToString("") { "%02x".format(it) }
                if (fp != pin) {
                    throw CertificateException("certificate fingerprint mismatch, re-pair needed")
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val sslContext = SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(trustManager), null)
        }
        client = OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustManager)
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(3, TimeUnit.SECONDS)
            .writeTimeout(3, TimeUnit.SECONDS)
            .build()
    }

    private val waitClient: OkHttpClient by lazy {
        client.newBuilder().readTimeout(55, TimeUnit.SECONDS).build()
    }

    fun postNotify(host: String, port: Int, json: String): SendResult =
        post(host, port, "/notify", json)

    fun postIcon(host: String, port: Int, json: String): SendResult =
        post(host, port, "/icon", json)

    fun postDismiss(host: String, port: Int, json: String): SendResult =
        post(host, port, "/dismiss", json)

    fun postCall(host: String, port: Int, json: String): SendResult =
        post(host, port, "/call", json)

    fun postCallWait(host: String, port: Int, json: String): WaitResult {
        val request = Request.Builder()
            .url("https://$host:$port/call/wait")
            .header("Authorization", "Bearer $token")
            .post(json.toRequestBody(jsonType))
            .build()
        return try {
            waitClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    WaitResult.Failed("HTTP ${response.code}")
                } else {
                    val body = response.body?.string() ?: ""
                    val action = try {
                        org.json.JSONObject(body).optString("action", "none")
                    } catch (e: org.json.JSONException) {
                        "none"
                    }
                    WaitResult.Action(action)
                }
            }
        } catch (e: Exception) {
            WaitResult.Failed(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun post(host: String, port: Int, path: String, json: String): SendResult {
        val request = Request.Builder()
            .url("https://$host:$port$path")
            .header("Authorization", "Bearer $token")
            .post(json.toRequestBody(jsonType))
            .build()
        return try {
            client.newCall(request).execute().use { response ->
                when {
                    response.code == 401 -> SendResult.AuthFailed
                    !response.isSuccessful -> SendResult.Failed("HTTP ${response.code}")
                    else -> {
                        val body = response.body?.string() ?: ""
                        SendResult.Ok(needIcon = body.contains("\"needIcon\":true"))
                    }
                }
            }
        } catch (e: Exception) {
            var cause: Throwable? = e
            while (cause != null) {
                if (cause is CertificateException) {
                    return SendResult.Failed("certificate fingerprint mismatch, re-pair needed")
                }
                cause = cause.cause
            }
            SendResult.Failed(e.message ?: e.javaClass.simpleName)
        }
    }
}
