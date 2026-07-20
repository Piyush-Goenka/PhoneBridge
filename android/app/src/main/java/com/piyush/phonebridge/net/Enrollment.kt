package com.piyush.phonebridge.net

import com.piyush.phonebridge.pairing.PairingStore
import org.json.JSONObject

// Registers this phone's client certificate with the Mac exactly once, so the
// Mac can switch to mutual TLS. Safe to call repeatedly and best-effort: a
// failure just leaves the pairing in open mode until the next attempt.
object Enrollment {

    fun ensure(store: PairingStore, client: MacClient, host: String, port: Int): Boolean {
        if (store.clientEnrolled) return true
        val certB64 = ClientIdentity.certificateDerBase64() ?: return false
        val body = JSONObject().put("v", 1).put("cert", certB64).toString()
        return when (val result = client.postEnroll(host, port, body)) {
            is MacClient.SendResult.Ok -> {
                store.clientEnrolled = true
                true
            }
            // 403 means the server is already locked. Reaching /enroll at all
            // required a successful mutual-TLS handshake, which only our
            // enrolled certificate can complete, so we are the enrolled phone.
            is MacClient.SendResult.Failed -> {
                if (result.reason.contains("403")) {
                    store.clientEnrolled = true
                    true
                } else {
                    false
                }
            }
            MacClient.SendResult.AuthFailed -> false
        }
    }
}
