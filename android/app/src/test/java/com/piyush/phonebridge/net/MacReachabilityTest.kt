package com.piyush.phonebridge.net

import org.junit.Assert.assertEquals
import org.junit.Test

class MacReachabilityTest {

    @Test
    fun failedForegroundCheckReportsUnreachable() {
        val tracker = ReachabilityTracker()

        val check = tracker.beginCheck()
        tracker.completeCheck(check, reachedMac = false)

        assertEquals(false, tracker.reachable.value)
    }

    @Test
    fun verifiedTlsProbeReportsReachable() {
        val tracker = ReachabilityTracker()

        val check = tracker.beginCheck()
        tracker.completeCheck(check, reachedMac = true)

        assertEquals(true, tracker.reachable.value)
    }

    @Test
    fun successfulDeliveryCorrectsAnEarlierFailedCheck() {
        val tracker = ReachabilityTracker()
        tracker.completeCheck(tracker.beginCheck(), reachedMac = false)

        tracker.recordSuccess()

        assertEquals(true, tracker.reachable.value)
    }

    @Test
    fun inFlightFailedCheckCannotOverwriteNewerDeliverySuccess() {
        val tracker = ReachabilityTracker()
        val check = tracker.beginCheck()

        tracker.recordSuccess()
        tracker.completeCheck(check, reachedMac = false)

        assertEquals(true, tracker.reachable.value)
    }

    @Test
    fun staleCheckCannotOverwriteANewerCheck() {
        val tracker = ReachabilityTracker()
        val stale = tracker.beginCheck()
        val current = tracker.beginCheck()

        tracker.completeCheck(current, reachedMac = true)
        tracker.completeCheck(stale, reachedMac = false)

        assertEquals(true, tracker.reachable.value)
    }

    @Test
    fun resetInvalidatesAnInFlightCheck() {
        val tracker = ReachabilityTracker()
        val check = tracker.beginCheck()

        tracker.reset()
        tracker.completeCheck(check, reachedMac = true)

        assertEquals(null, tracker.reachable.value)
    }
}
