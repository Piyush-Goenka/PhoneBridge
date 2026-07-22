package com.piyush.phonebridge.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

class ClientIdentityMetadataTest {

    @Test
    fun fingerprintIsLowercaseSha256OfCertificateDer() {
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb924" +
                "27ae41e4649b934ca495991b7852b855",
            ClientIdentityMetadata.fingerprint(byteArrayOf()),
        )
    }

    @Test
    fun enrollmentOnlyMatchesTheCurrentCertificate() {
        val current = "ab".repeat(32)

        assertTrue(ClientIdentityMetadata.enrollmentMatches(current.uppercase(), current))
        assertFalse(ClientIdentityMetadata.enrollmentMatches(null, current))
        assertFalse(ClientIdentityMetadata.enrollmentMatches("cd".repeat(32), current))
    }

    @Test
    fun cachedClientChangesWhenClientIdentityRotates() {
        val old = MacClientCacheKey("token", "mac-pin", "old-client-pin")
        val repaired = MacClientCacheKey("token", "mac-pin", "new-client-pin")

        assertNotEquals(old, repaired)
    }

    @Test
    fun cachedClientAlsoChangesWithPairingCredentials() {
        val original = MacClientCacheKey("token", "mac-pin", "client-pin")

        assertNotEquals(original, original.copy(token = "rotated-token"))
        assertNotEquals(original, original.copy(macFingerprint = "new-mac-pin"))
    }

    @Test
    fun p256IdentityCompletesTheRawTlsSignatureProbe() {
        val pair = ecKeyPair("secp256r1")

        assertTrue(ClientIdentityMetadata.isP256(pair.publicKey))
        assertTrue(
            ClientIdentityMetadata.rawEcdsaRoundTrip(pair.privateKey, pair.publicKey))
    }

    @Test
    fun nonP256IdentityIsRejected() {
        assertFalse(ClientIdentityMetadata.isP256(ecKeyPair("secp384r1").publicKey))
    }

    @Test
    fun rawProbeRejectsMismatchedCertificateAndPrivateKey() {
        val first = ecKeyPair("secp256r1")
        val second = ecKeyPair("secp256r1")

        assertFalse(
            ClientIdentityMetadata.rawEcdsaRoundTrip(
                first.privateKey,
                second.publicKey,
            ),
        )
    }

    @Test
    fun onlyDeterministicIncompatibilityAllowsKeyReplacement() {
        assertTrue(ClientIdentityHealth.Incompatible.shouldReplace)
        assertFalse(ClientIdentityHealth.Usable.shouldReplace)
        assertFalse(ClientIdentityHealth.Unavailable.shouldReplace)
    }

    @Test
    fun enrollmentOnlyAcceptsSuccessOrExactHttp403() {
        assertTrue(
            Enrollment.confirmsCurrentIdentity(MacClient.SendResult.Ok(needIcon = false)))
        assertTrue(
            Enrollment.confirmsCurrentIdentity(MacClient.SendResult.Failed("HTTP 403")))
        assertFalse(
            Enrollment.confirmsCurrentIdentity(MacClient.SendResult.Failed("HTTP 1403")))
        assertFalse(Enrollment.confirmsCurrentIdentity(MacClient.SendResult.AuthFailed))
    }

    private data class EcKeyPair(
        val privateKey: PrivateKey,
        val publicKey: ECPublicKey,
    )

    private fun ecKeyPair(curve: String): EcKeyPair {
        val pair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec(curve))
        }.generateKeyPair()
        return EcKeyPair(
            privateKey = pair.private,
            publicKey = pair.public as ECPublicKey,
        )
    }
}
