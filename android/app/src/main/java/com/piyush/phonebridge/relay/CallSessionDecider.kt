package com.piyush.phonebridge.relay

// Pure decision table for the incoming-call session: given what the dialer
// just posted and what the session already knows, what happens next. The
// dialer updates one notification key in place, so re-posts carry two
// distinct signals: a caller-name correction (contact lookup finished after
// the first post) while still ringing, or the switch to the ongoing-call
// notification the moment the user answers. No Android imports, so this
// runs under plain JVM tests.
object CallSessionDecider {

    const val UNKNOWN_CALLER = "Unknown caller"

    sealed interface Decision {
        data object Start : Decision
        data class UpdateCaller(val caller: String) : Decision
        data class End(val caller: String) : Decision
        data object Ignore : Decision
    }

    fun decide(
        activeCaller: String?,
        anySessionActive: Boolean,
        answeredFromMac: Boolean,
        isRinging: Boolean,
        caller: String,
    ): Decision = when {
        // Answering from the Mac takes the phone off-hook too, so a
        // not-ringing re-post means "the call is running", not "the user
        // picked up here". The card stays and End call keeps working.
        activeCaller != null && answeredFromMac -> Decision.Ignore
        activeCaller != null && !isRinging -> Decision.End(activeCaller)
        activeCaller != null && caller != activeCaller && caller != UNKNOWN_CALLER ->
            Decision.UpdateCaller(caller)
        activeCaller != null -> Decision.Ignore
        isRinging && !anySessionActive -> Decision.Start
        else -> Decision.Ignore
    }
}
