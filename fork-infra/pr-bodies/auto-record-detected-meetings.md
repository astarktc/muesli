Add an opt-in setting to auto-record detected meetings

## Summary

Refs #666 and #223. Only calendar meetings can start recording on their own; a call Muesli detects shows
"Meeting detected", and a missed prompt means an unrecorded meeting. #666 was declined because detection
has false positives. This PR keeps the prompt as the default and adds an opt-in setting, off by default,
that skips it **only for detections that confirm a live call**: **Auto-record detected meetings**
(Settings → Meetings → Meeting Notifications, under Auto-detected meetings;
`auto_record_detected_meetings`).

```text
MeetingMonitor emits .show(candidate)           # after muted apps, dismissals, cooldowns, suppression
  presentMeetingDetection(candidate)
+   autoRecordDetectedMeetingIfStrong(candidate)
+     setting on, detection notifications on, nothing recording, no calendar notice on screen,
+     no dictation, Quill or computer-use audio in progress (an auto-start never interrupts them)
+     MeetingAutoRecordPolicy.shouldAutoRecord(candidate)
+       strong evidence and a media-session candidate
+     startRecordingDetectedMeeting(candidate)  # the prompt's own start path, extracted
+     "Recording started" notice: [Discard] [Stop]
+     start failed → fall through to the prompt
    otherwise: the "Meeting detected" prompt, unchanged
```

Strong (`MeetingAutoRecordPolicy.isStrongDetection`, read from `MeetingCandidate.evidence`):

| Evidence | Auto-records |
| --- | --- |
| A dedicated meeting app (Zoom, Teams, Slack, Webex, FaceTime, WhatsApp) holds the microphone | yes |
| A meeting link is open in the browser that holds the microphone | yes |
| Microphone and camera both on | yes |
| A call-capable app holds the microphone during a current calendar event | yes |
| The microphone belongs to another app (dictation) while a browser or meeting page is in front | no, prompt |
| A browser holds the microphone with no meeting link and no camera | no, prompt |
| A meeting tab with no microphone activity (pre-join) | no, prompt |

`shouldAutoRecord` also requires a media-session candidate (`meeting-session:` suppression ID), the only
kind that `MeetingPromptStateMachine.markRecordingStarted` consumes. Stopping or discarding an
auto-recording therefore cannot restart it during the same call; other strong candidates (for example,
mic and camera from an unattributed app during a calendar event) keep the prompt.

Everything else is shared with the prompt: origin `.detectedPrompt`, the same auto-stop source, the
calendar occurrence, the background pill presentation and `meetingMonitor.markRecordingStarted`. The
notification card gains an optional secondary action, used here for Discard (which keeps its
confirmation alert; before capture starts, both buttons cancel the preparation).

Independent of the companion auto-stop PR (`astarktc:auto-stop-on-meeting-end`). Without it, an auto-recorded meeting ends like a prompted one
does today, with the advisory "Meeting signal lost" warning; with it, the opt-in stop applies too,
because the origin is `.detectedPrompt`.

## Validation

- **Before**, with `isStrongDetection` stubbed to `true` (as if every detection auto-recorded), the four
  false-positive cases fail:
  ```
  ✘ another app's dictation in front of a meeting tab only prompts
  ✘ a browser holding the microphone without a meeting link or camera only prompts
  ✘ a meeting tab without any microphone activity only prompts
  ✘ dictation during a calendar event only prompts
  ```
  **After**: `swift test --build-system native --package-path native/MuesliNative --filter MeetingAutoRecordPolicyTests`
  → 10 tests passed. The cases build real `MeetingSignalSnapshot`s and run them through
  `MeetingCandidateResolver` (and `MeetingMediaSessionTracker` for the session cases), so they test the
  evidence the prompt path actually receives. Two more show that a strong session auto-records and is then
  suppressed, and that a strong but unscoped candidate keeps the prompt.
- `AppConfigTests`: the key defaults off, ignores an invalid value and round-trips.
  `MeetingNotificationControllerTests`: both labels fit their 72 pt buttons and the text clears them.
- The new suite is assigned to the meetings shard; `./scripts/test_ci_test_shards.sh` passes.
- CI shards on this branch: core 1232 passed, dictation-transcription 1027 passed, meetings 1205 passed;
  legacy-unsharded suites 551 passed. `main` at the same base: 1231 / 1027 / 1195 / 550, all passing.
- Built and run locally with Xcode 27.2 (Swift 6.4.2) on macOS 26.6, `--build-system native`, as CI does.
- Not yet exercised in a live call: the notice's layout on screen and an end-to-end auto-start.

## Merge danger

**Door:** two-way. Opt-in and off by default; one new optional config key that older builds ignore;
no persistence or schema change.

**Blast radius:** small with the setting off: the prompt's start action now goes through the extracted
`startRecordingDetectedMeeting`, with identical arguments and follow-up calls, and the notification card's
layout only changes when a secondary action is passed. With the setting on, a misclassified detection
records without asking; the notice offers Discard right away, and the classification is covered by the
false-positive tests above.

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
