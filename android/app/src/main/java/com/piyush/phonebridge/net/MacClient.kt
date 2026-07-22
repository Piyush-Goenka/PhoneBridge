package com.piyush.phonebridge.net

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.cert.CertificateException
import java.util.concurrent.TimeUnit

class MacClient(
    private val token: String,
    fingerprintHex: String,
    internal val clientIdentity: ClientIdentity.TlsMaterial? = ClientIdentity.tlsMaterial(),
) {

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
        val trustManager = PinnedTls.trustManager(fingerprintHex)
        client = OkHttpClient.Builder()
            .sslSocketFactory(
                PinnedTls.socketFactory(trustManager, clientIdentity?.keyManagers),
                trustManager)
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(3, TimeUnit.SECONDS)
            .writeTimeout(3, TimeUnit.SECONDS)
            .build()
    }

    private val waitClient: OkHttpClient by lazy {
        client.newBuilder().readTimeout(55, TimeUnit.SECONDS).build()
    }

    // A cached client owns pooled TLS sessions and possibly a live long-poll.
    // Credential rotation must close both, not merely drop this Kotlin object.
    fun close() {
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
    }

    fun postNotify(host: String, port: Int, json: String): SendResult =
        post(host, port, "/notify", json)

    fun postIcon(host: String, port: Int, json: String): SendResult =
        post(host, port, "/icon", json)

    fun postDismiss(host: String, port: Int, json: String): SendResult =
        post(host, port, "/dismiss", json)

    fun postCall(host: String, port: Int, json: String): SendResult =
        post(host, port, "/call", json)

    fun postEnroll(host: String, port: Int, json: String): SendResult =
        post(host, port, "/enroll", json)

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
