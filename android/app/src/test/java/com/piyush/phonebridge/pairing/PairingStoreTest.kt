package com.piyush.phonebridge.pairing

import org.junit.Assert.assertEquals
import org.junit.Test

class PairingStoreTest {

    @Test
    fun migrationRestoresPairingSelectionsAndToggles() {
        val legacy = setOf(
            "token", "fingerprint", "host", "port", "allowlist",
            "mirroring", "mirrorCalls",
        )

        assertEquals(legacy, PairingStore.keysToMigrate(legacy, emptySet()))
    }

    @Test
    fun migrationDoesNotOverwriteSecureValuesOrCopyUnknownKeys() {
        val keys = PairingStore.keysToMigrate(
            legacyKeys = setOf("token", "host", "allowlist", "unknown"),
            secureKeys = setOf("token", "host"),
        )

        assertEquals(setOf("allowlist"), keys)
    }

    @Test
    fun completedMigrationNeverRunsAgain() {
        val keys = PairingStore.keysToMigrate(
            legacyKeys = setOf("token", "allowlist"),
            secureKeys = setOf("legacyMigrationComplete"),
        )

        assertEquals(emptySet<String>(), keys)
    }
}
