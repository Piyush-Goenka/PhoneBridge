package com.piyush.phonebridge.net

import com.piyush.phonebridge.pairing.PairingStore
import org.json.JSONObject

// Registers this phone's client certificate with the Mac exactly once, so the
// Mac can switch to mutual TLS. Safe to call repeatedly and best-effort: a
// failure just leaves the pairing in open mode until the next attempt.
object Enrollment {

    internal fun confirmsCurrentIdentity(result: MacClient.SendResult): Boolean =
        result is MacClient.SendResult.Ok ||
            result is MacClient.SendResult.Failed && result.reason == "HTTP 403"

    fun ensure(store: PairingStore, client: MacClient, host: String, port: Int): Boolean {
        // Use the certificate captured by this client's TLS key managers. A
        // separate Keystore read could race a rotation and enroll a certificate
        // different from the one that authenticated this connection.
        val identity = client.clientIdentity ?: return false
        if (store.isClientEnrolled(identity.fingerprint)) return true
        val body = JSONObject()
            .put("v", 1)
            .put("cert", identity.certificateDerBase64)
            .toString()
        val result = client.postEnroll(host, port, body)
        // 403 means the server is already locked. Reaching /enroll at all
        // required a successful mutual-TLS handshake, which only the currently
        // enrolled certificate can complete.
        if (!confirmsCurrentIdentity(result)) return false
        store.markClientEnrolled(identity.fingerprint)
        return true
    }
}
