# Call Control Extension, Design

Date: 2026-07-15
Status: Approved (design agreed in session), extends 2026-07-14-android-mac-notification-bridge-design.md

## Goal

When my phone rings, the Mac banner for the call offers Reject and Silence buttons that act on the phone. Answering from the Mac is out of scope (impossible without the call audio).

## Principles carried over

All four principles of the base spec hold. The command channel exists only while the phone is ringing: the phone opens it inside the call event and it dies with the ring. No polling, no persistent socket, no queue.

## How it works

### Detection (phone)

The dialer's incoming-call notification already reaches `NotificationRelayService`. It carries `Notification.CATEGORY_CALL`, and its title is the caller. When the new "Mirror calls" toggle is on and such a notification posts, it takes a dedicated call path that bypasses the normal structural filter (call notifications are "ongoing", which the mirror path drops) and the app allowlist. One call session per notification key; dialer re-posts of the same key are ignored while a session is active.

### The ring window channel

1. Phone POSTs `/call` `{v, key, caller, postedAt}`. Mac replies `200 {}` and shows an actionable banner.
2. Phone immediately POSTs `/call/wait` `{key}` with a 50 s read timeout. The Mac holds this request open for up to 45 s and answers `{"action":"reject"|"silence"|"none"}` the moment a button is clicked, the banner is dismissed on the Mac, or the timer runs out.
3. The phone acts on the answer, and the session ends.
4. When the ring stops for any reason, the dialer retracts its notification; the existing `/dismiss` path removes the Mac banner and fulfills any still-open wait with `none`.

If the Mac is unreachable, the `/call` POST fails and the phone does nothing further: the call rings normally, best-effort like everything else.

### Executing actions (phone)

- **Answer** (added later in session): `TelecomManager.acceptRingingCall()`. The call connects on the phone; its audio cannot be moved to the Mac (platform restriction), so this is "pick up while the phone is within reach".
- **Reject**: `TelecomManager.endCall()`.
- **Silence**: set ringer mode to silent, then restore the previous ringer mode when the phone leaves the RINGING state (with a 60 s fallback restore in case state tracking fails).
- **Guard**: both actions execute only if the phone is still RINGING at the moment the command arrives. This prevents the race where a Reject clicked just after picking up would hang up an active call.
- Failures (missing permission, endCall returning false, no longer ringing) land in the send log as explicit outcomes, never silently.

### Permissions (phone)

Requested when the "Mirror calls" toggle is switched on:
- `ANSWER_PHONE_CALLS` and `READ_PHONE_STATE`: one runtime dialog (same permission group).
- Do-Not-Disturb access (`ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS` deep link): required to change ringer mode; needed for Silence only.

The toggle shows which grants are still missing. With partial grants, the corresponding button still appears on the Mac but its execution logs a failure.

### Mac side

- Calls do NOT use notification banners. macOS auto-dismisses banners after a few seconds and offers no per-notification way to make them persist (the Alerts style is a user setting that would also make every mirrored notification sticky). Instead, a `CallPanelController` shows a floating card in the top-right corner: caller name, a pulsing phone icon, and real Reject and Silence buttons. It stays visible until a button is clicked, the ring ends (phone `/dismiss` triggers `CallSink.endCall`), or the 45 s action window expires, whichever comes first. The panel is non-activating (it never steals keyboard focus) and floats above other windows.
- A `CallActionRegistry` maps call key to the pending `/call/wait` completion. It is fulfilled exactly once by whichever comes first: a button click (`reject` or `silence`), phone-side `/dismiss` (`none`), or the 45 s timeout (`none`).
- The HTTP layer gains an async response path: `/call/wait` cannot be answered synchronously, so the handler for it receives a completion instead of returning a result. All existing endpoints stay synchronous.

## Wire protocol additions (protocol.md is updated to match)

- `POST /call` `{"v":1,"key":"...","caller":"Palak","postedAt":1768...}` → `200 {}`
- `POST /call/wait` `{"key":"..."}` → held ≤45 s → `200 {"action":"reject"|"silence"|"none"}`
- `/dismiss` (existing) also ends a call session's banner and wait.

Both carry the bearer token like every other endpoint.

## Failure modes

| Situation | Behaviour |
|---|---|
| Mac offline when ringing | `/call` fails, phone drops the session, call rings normally |
| Button clicked after call answered | Phone sees state != RINGING, does nothing, logs "reject skipped: not ringing" |
| Reject clicked but permission revoked | endCall not attempted, logged "reject failed: no permission" |
| Silence clicked without DND access | Ringer untouched, logged "silence failed: no DND access" |
| Wait times out with no action | Mac answers `none`, phone does nothing |
| Ring ends before any action | Phone's `/dismiss` removes banner and fulfills wait with `none` |

## Out of scope

Answering calls from the Mac, call history, decline-with-SMS, multiple simultaneous calls (only the first active session is tracked; a second incoming call while one session is open is ignored).

## Amendments (2026-07-19)

Field testing surfaced two gaps, both rooted in the same blind spot: the dialer
updates its one notification key in place, and the original design ignored all
re-posts of an active session's key.

1. **Ring end on answer.** Answering on the phone does not remove the dialer's
   notification, it morphs into the ongoing-call notification (same key), so
   no `/dismiss` fired and the Mac card lingered until the call ended or the
   45 s window expired. Now a re-post of the active key while telephony is no
   longer RINGING is treated as "answered on the phone": the phone sends
   `/dismiss` (closing the card and fulfilling the pending wait with `none`),
   restores the ringer if Silence had muted it, and ends the session. Decision
   logic lives in `CallSessionDecider`, pure and JVM-tested.
2a. **The card is a session, not a one-shot prompt (2026-07-19, second
   round).** Originally any button click closed the card and ended the
   session, which was wrong for two of the three buttons. Silence leaves the
   call ringing and Answer leaves it connected, so in both cases there is
   still something to control. Now:

   - **Answer** keeps the card up; once the phone confirms it connected
     (`/call` `"state":"active"`), the card switches to its in-call form with
     a single **End call** button (`/call/wait` action `end` →
     `TelecomManager.endCall()` on the connected call).
   - **Silence** keeps the card up and marks itself done, confirmed by
     `"state":"silenced"`; the card lives until the ring is over.
   - **Reject** and **End call** close the card immediately, since both end
     the call.
   - Answering *on the phone* still closes the card: the user is holding the
     phone, so Mac controls are redundant.

   Consequence for the "command channel dies with the ring" principle: the
   channel now lives for the whole call, because the phone re-polls
   `/call/wait` in a loop until the session ends. The phone is awake during a
   call anyway, so this costs nothing extra in practice, but it is a
   deliberate widening of the original design and is recorded as such. The
   Mac buffers one unclaimed action per key so a click landing between two
   polls is not lost, and the card's auto-close is only a safety net (3 min
   ringing, 4 h in call); the real close is the phone's `/dismiss`.

2. **Caller-name updates.** The dialer often posts the incoming-call
   notification first with the carrier/Google caller-ID name and re-posts with
   the saved contact name once its lookup resolves; the Mac showed whichever
   won that race. A re-post of the active key while still RINGING with a
   changed title is now forwarded as `POST /call` with `"update":true`; the
   Mac rewrites the banner text and the history entry in place (same panel,
   same timer, no repeated sound). Names never downgrade to "Unknown caller".
