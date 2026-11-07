Add an opt-in setting to stop recordings when the meeting ends

## Summary

Refs #650. Since #368, the "Meeting signal lost" warning is advisory for every start origin, because
automatic stops cut real meetings short (#303). That stays the default. This PR adds an opt-in setting,
off by default, for people who would rather lose a stalled tail than record the next conversation:
**Stop recording when the meeting ends** (Settings → Meetings → Recording;
`stop_recording_when_meeting_ends`).

```diff
 source-backed recording (detected prompt, calendar auto-record, scheduled prompt, Join & Record)
-  source gone 20 s and transcript quiet 45 s
+  source gone 20 s and transcript quiet 45 s           (setting off: either channel, unchanged)
+  source gone 20 s and REMOTE (system) audio quiet 45 s (setting on: the mic is ignored)
     show "Meeting signal lost" for 30 s
-      "Recording continues. Stop if the meeting ended."   timeout → keep recording
+      setting off: unchanged; any speech closes the warning
+      setting on:  "Stopping in 30 s. Close this to keep recording."
+        timeout with no user action      → stop, as "Stop Transcribing" would
+        user closes the warning          → keep recording for the rest of this recording
+        you keep talking in the room     → still stops (microphone speech is ignored)
+        remote speech resumes            → stop cancelled; warns again after 45 s of remote quiet
+        source returns                   → stop cancelled (existing warning dismissal)
 manual recording → inactivity reminder, never stops (unchanged)
 "Scheduled time ended" → never stops (unchanged); it no longer replaces a warning that is about to stop
```

Why only the remote side: when a call ends, people often keep talking in the room, and the microphone
transcript would keep the recording going indefinitely, capturing the conversation after the meeting.
Once the meeting app or room is gone, remote audio is the evidence that the meeting still runs (the same
rule OpenWhispr's meeting auto-end uses after the call app releases the microphone).

The decision stays in the existing policy types (`MeetingAutoStopPolicy.swift`):

```diff
 enum MeetingSignalLossResponse {
   case none, warnOnly
+  case stopAfterWarning
   case transcriptInactivity
+  func stoppingWhenMeetingEnds(_ enabled: Bool) -> Self  // only warnOnly ⇄ stopAfterWarning
 }
 +enum MeetingTranscriptChannel { case microphone, system }  // from the live speaker label
 struct MeetingSignalLossPromptState {
+  isStopPending           // set by markPromptPresented(response: .stopAfterWarning)
+  markTimedOut() -> Bool  // true only if still pending and the user did not close the warning
+  noteTranscriptActivity(now:channel:) -> Bool   // false = mic speech during a pending stop
+  hasRecentTranscriptActivity(now:quietPeriod:response:)  // .stopAfterWarning: system channel only
 }
```

`MuesliController.presentMeetingSignalLossPromptIfNeeded` applies the setting when the warning is shown
and stops only from the warning's `onAutoDismiss`, with the same `activeMeetingID`, recording and pause
guards as before. The live transcript callbacks pass their channel ("You" is the microphone; any other
label counts as remote, which can only keep a recording going). With the setting off, the warning text,
its timeout, which speech defers or closes it, and the scheduled-end notice behave exactly as on `main`.

## Validation

- **Before** (`main` 4aea4f04): the new policy tests do not compile —
  `type 'MeetingSignalLossResponse' has no member 'stopAfterWarning'`.
  **After**: `swift test --build-system native --package-path native/MuesliNative --filter MeetingAutoStopPolicyTests`
  → 21 tests passed (11 on `main`). New cases:
  - every source-backed origin becomes `.stopAfterWarning` with the setting on; `.manual` stays `.transcriptInactivity`;
  - only an unanswered stopping warning returns `markTimedOut() == true`; `.warnOnly` and the manual reminder never do;
  - closing the warning keeps recording for the rest of the recording, whatever either side says afterwards;
  - with the setting on, the user talking in the room after the source is lost neither defers nor
    closes the warning, and the timeout stops;
  - with the setting on, remote speech defers the warning and cancels a pending stop, and the warning
    returns after 45 s of remote quiet;
  - renewed remote speech, a recovered source, or a non-timeout close cancels a pending stop;
  - with the setting off, speech on either channel defers and closes the warning, which never stops;
  - live speaker labels map to channels ("You" → microphone, anything else → remote).
  Red first: the channel cases failed to compile, then the re-arm case failed on `canPresentPrompt`
  before the change; swapping the channel that feeds the remote timestamp fails three of them.
- `AppConfigTests`: the key defaults off, ignores an invalid value and round-trips.
- CI shards, run on a build that carries this commit with an identical diff (`git range-diff` `=`) on
  `v0.8.6-preprod.2` together with an unrelated opt-in patch, `./scripts/run_ci_test_shard.sh <shard>`:
  core 1212, dictation-transcription 1024, meetings 1199 passed; the legacy-unsharded suites
  (`scripts/ci_unsharded_test_suites.txt`, which include `MeetingAutoStopPolicyTests`) 561 passed.
  `v0.8.6-preprod.2` alone: 1210 / 1024 / 1189 / 550, all passing; every difference is a new test.
  Flake note: `QoLTests` indicator-hover timing tests occasionally fail in the parallel core shard on
  any branch; this PR does not touch the indicator.
- Built and run locally with Xcode 27.2 (Swift 6.4.2) on macOS 26.6, `--build-system native`, as CI does.
- Not yet exercised in a live call: the end-to-end timeout → stop path in the running app.

## Merge danger

**Door:** two-way. Opt-in and off by default; one new optional config key that older builds ignore;
no persistence or schema change.

**Blast radius:** small. With the setting off nothing changes. With it on, a recording can end on its own
after a visible 30-second countdown — the opt-in trade-off #650 asks for. The stop goes through
`stopMeetingRecording()`, the same path as the warning's Stop button.

AGENTS.md says "Dismissing UI or pressing Escape must not stop an established meeting; meeting stop
actions remain explicit." Dismissing still never stops: closing the warning is the way to keep
recording. The only implicit stop is the one the user turns on in Settings, announced by the countdown.

## Contribution certification

- [x] Every non-merge commit in this pull request has a valid
      `Signed-off-by` trailer from its author under the
      [Developer Certificate of Origin](https://developercertificate.org/).
- [x] I created this contribution or otherwise have the right to submit it
      under Muesli's
      [MIT License](https://github.com/Muesli-HQ/muesli/blob/main/LICENSE).
- [ ] I have obtained any permission required by an employer, client,
      institution, or other party that may have rights in this contribution.
- [x] I have identified all third-party code, models, datasets, media, and
      other assets introduced by this pull request, including their sources
      and licenses or terms.
- [x] I have disclosed material AI assistance and reviewed and tested the
      resulting changes.

### Third-party materials

None.

### AI assistance

Implemented with an AI coding agent (Anthropic Claude, in the Pi agent harness): code, tests and this
description. I reviewed the diff and ran the tests listed above.
