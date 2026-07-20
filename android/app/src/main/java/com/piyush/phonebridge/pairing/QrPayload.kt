package com.piyush.phonebridge.pairing

import org.json.JSONException
import org.json.JSONObject

data class QrPayload(
    val host: String,
    val port: Int,
    val token: String,
    val fingerprint: String,
) {
    companion object {
        // Base64url of a 32-byte token, no padding.
        private val TOKEN_REGEX = Regex("^[A-Za-z0-9_-]{16,128}$")
        // SHA-256 of the cert DER as lowercase hex.
        private val FINGERPRINT_REGEX = Regex("^[0-9a-f]{64}$")

        fun parse(json: String): QrPayload? {
            return try {
                val obj = JSONObject(json)
                if (obj.getInt("v") != 1) return null
                val host = obj.getString("host").trim()
                val port = obj.getInt("port")
                val token = obj.getString("token")
                val fingerprint = obj.getString("fp").lowercase()
                // Reject anything malformed rather than storing a bogus
                // pairing that only fails later at connect time.
                if (host.isEmpty() || host.length > 253) return null
                if (port !in 1..65535) return null
                if (!TOKEN_REGEX.matches(token)) return null
                if (!FINGERPRINT_REGEX.matches(fingerprint)) return null
                QrPayload(host = host, port = port, token = token, fingerprint = fingerprint)
            } catch (e: JSONException) {
                null
            }
        }
    }
}
