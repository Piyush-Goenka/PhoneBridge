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
