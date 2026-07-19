package com.piyush.phonebridge.relay

import com.piyush.phonebridge.relay.CallSessionDecider.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

class CallSessionDeciderTest {

    @Test
    fun startsSessionWhenRingingAndNothingActive() {
        assertEquals(
            Decision.Start,
            CallSessionDecider.decide(
                activeCaller = null, anySessionActive = false,
                answeredFromMac = false, isRinging = true, caller = "Manoj"))
    }

    @Test
    fun ignoresPostWhenNotRingingAndNothingActive() {
        // The ongoing-call notification of a call we never mirrored.
        assertEquals(
            Decision.Ignore,
            CallSessionDecider.decide(
                activeCaller = null, anySessionActive = false,
                answeredFromMac = false, isRinging = false, caller = "Manoj"))
    }

    @Test
    fun ignoresSecondIncomingCallWhileAnotherSessionActive() {
        assertEquals(
            Decision.Ignore,
            CallSessionDecider.decide(
                activeCaller = null, anySessionActive = true,
                answeredFromMac = false, isRinging = true, caller = "Someone Else"))
    }

    @Test
    fun ignoresRepostWithSameCaller() {
        assertEquals(
            Decision.Ignore,
            CallSessionDecider.decide(
                activeCaller = "Manoj", anySessionActive = true,
                answeredFromMac = false, isRinging = true, caller = "Manoj"))
    }

    @Test
    fun updatesCallerWhenContactNameResolvesMidRing() {
        // First post carried the carrier caller-ID name, the dialer then
        // re-posts with the saved contact name once its lookup finishes.
        assertEquals(
            Decision.UpdateCaller("Lattu Chacha"),
            CallSessionDecider.decide(
                activeCaller = "Manoj", anySessionActive = true,
                answeredFromMac = false, isRinging = true, caller = "Lattu Chacha"))
    }

    @Test
    fun neverDowngradesANameToUnknownCaller() {
        assertEquals(
            Decision.Ignore,
            CallSessionDecider.decide(
                activeCaller = "Manoj", anySessionActive = true,
                answeredFromMac = false, isRinging = true,
                caller = CallSessionDecider.UNKNOWN_CALLER))
    }

    @Test
    fun endsSessionWhenAnsweredOnThePhone() {
        // Dialer swapped the incoming-call notification to ongoing-call
        // (same key) and telephony left RINGING: the user picked up.
        assertEquals(
            Decision.End("Manoj"),
            CallSessionDecider.decide(
                activeCaller = "Manoj", anySessionActive = true,
                answeredFromMac = false, isRinging = false, caller = "Manoj"))
    }

    @Test
    fun endWinsOverANameChangeArrivingAtAnswerTime() {
        assertEquals(
            Decision.End("Manoj"),
            CallSessionDecider.decide(
                activeCaller = "Manoj", anySessionActive = true,
                answeredFromMac = false, isRinging = false, caller = "Lattu Chacha"))
    }

    @Test
    fun keepsCardWhenTheCallWasAnsweredFromTheMac() {
        // Answering from the Mac also takes the phone off-hook and makes the
        // dialer re-post its ongoing-call notification. That is not "the user
        // picked up on the phone": the Mac card must stay so End call works.
        assertEquals(
            Decision.Ignore,
            CallSessionDecider.decide(
                activeCaller = "Manoj", anySessionActive = true,
                answeredFromMac = true, isRinging = false, caller = "Manoj"))
    }

    @Test
    fun ignoresNameChangeOnAnAlreadyAnsweredCall() {
        assertEquals(
            Decision.Ignore,
            CallSessionDecider.decide(
                activeCaller = "Manoj", anySessionActive = true,
                answeredFromMac = true, isRinging = false, caller = "Lattu Chacha"))
    }
}
