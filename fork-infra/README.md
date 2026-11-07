# fork-infra — running our own build of Muesli

We run a **personal build of Muesli**: an upstream release tag plus our patch commits plus this
directory as one `fork-infra:` commit, rebuilt whenever we absorb a newer tag. Auto-update is off by
construction, so an upstream release never replaces it. Both Macs run the same build: the MacBook
Pro (build machine) and the work Mac. Test, build, deploy, install and update go through the five
scripts here.

## The stack

```
Muesli-HQ/muesli tag vX.Y.Z[-preprod.N]  ← what upstream ships to testers (preprod) and users
patched (this repo)                      ← our patch commits, then ONE fork-infra commit
```

- **Remotes:** `upstream` = Muesli-HQ/muesli, `origin` = astarktc/muesli (backup of every branch).
- **`patched`** is the branch we build. `git log $(git describe --tags --abbrev=0 patched)..patched`
  is the whole fork.
- **We absorb at tags, never at `main` HEAD.** `main` merges several PRs a day (about 1,200 commits
  in 90 days); release and preprod tags are the states upstream itself puts in front of people. The
  newest tag of either kind is the default; `update.sh --releases-only` skips preprods.
- **Each patch also lives alone on its PR branch** (upstream `main` + that patch only), as offered or
  to be offered upstream: `auto-stop-on-meeting-end`, `auto-record-detected-meetings`,
  `aec-realign-after-mic-gap`, `localvqe-reference-lead`. The PR branches
  stay on `main`, so their commit and `patched`'s differ in base but not in diff. Fix a patch on its PR
  branch first, then replay it here: `git rebase -i <base tag>`, replace that patch's `pick <old>`
  line with `pick <PR branch head>`, and confirm that
  `git range-diff upstream/main..<PR branch> <base tag>..patched` shows `=` for it.
- **Upstream stance:** the maintainer declined both behaviours as defaults (issue #650, auto-stop:
  "users reported meetings automatically ending"; issue #666, auto-record: "detection has a lot of
  false positives"). Both patches are therefore opt-in settings, off by default. Drop a patch once
  upstream ships equivalent behaviour; keep it while it serves us otherwise.
- **Upstream-bound fixes:** `aec-realign-after-mic-gap` (issue #747) and `localvqe-reference-lead`
  (issue #748) fix bugs, each filed with an offer of a PR. They have no setting. Drop each when
  upstream fixes its issue.
- Commit fork-infra edits as `git commit --fixup=':/^fork-infra:'`; `update.sh` autosquashes them into
  the one fork-infra commit.

## Our settings (config.json, snake_case)

| Key | Default | Effect |
| --- | --- | --- |
| `stop_recording_when_meeting_ends` | `false` | A detected, calendar or joined recording stops when its "Meeting signal lost" warning times out unanswered: source gone 20 s, then **remote (system-audio) speech** quiet 45 s, then a 30 s countdown. Microphone speech is ignored once the source is gone, so talking on in the room after the call does not keep it recording; remote speech cancels the countdown, and the warning returns after another 45 s of remote quiet. Closing the warning keeps recording. Manual recordings and "Scheduled time ended" never stop. With the setting off, speech on either side defers and closes the warning as upstream does. |
| `auto_record_detected_meetings` | `false` | A strong detection starts recording without the prompt and shows "Recording started" with Stop/Discard. Needs `show_meeting_detection_notification` on. Strong: a meeting app holds the mic; a meeting link is open in the browser holding the mic; mic + camera; a call-capable app holds the mic during a calendar event. Everything else still prompts; muted apps and prompt suppressions still apply. |

Both are also in Settings → Meetings (Recording, and under Auto-detected meetings). Edit
`~/Library/Application Support/Muesli/config.json` only while Muesli is quit; it rewrites the file.

## Build — `fork-infra/build.sh`

```
fork-infra/build.sh [--version X.Y.Z-qm.N] [--identity <SHA-1>] [--swiftpm]
```

Runs upstream's `scripts/build_native_app.sh` (the release path: xcodebuild for App Intents metadata,
plus `muesli-cli`, LocalVQE and Cotypist bundling) with our deltas, then verifies and packages:

- installs into `release/Muesli.app`, never `/Applications`;
- `SUFeedURL` empty, so `AppDelegate` never creates the Sparkle updater (no update checks at all);
- `scripts/MuesliLocalOnly.entitlements`: no iCloud/CloudKit or APNs (they need a provisioning profile);
- TelemetryDeck unconfigured, so telemetry is off;
- bundle id `com.muesli.app` and support dir `Muesli`: the same data, config and models as the
  official app;
- version from `fork-infra/VERSION` (`X.Y.Z-qm.N`; bump N for every build that gets installed). The
  script refuses an `X.Y.Z` below the base tag's, so our build never sorts below the upstream
  release it replaces;
- LocalVQE required (built on first use into the gitignored `native/MuesliNative/LocalVQE/lib/`);
- signed with our Apple team identity (next section), refusing to build without it. The app,
  `muesli-cli` and Cotypist are re-signed with a designated requirement that pins the team, and
  verified: Team ID present, requirement exact.

Output: `release/Muesli.app`, `release/Muesli-<version>.zip` + `.sha256`, `release/BUILD-INFO.txt`
(commit, base tag, patches, signing identity, designated requirement, CDHash). `release/` is
gitignored. The script refuses a dirty tree and a `patched` that does not sit on an upstream tag.

Prerequisites on the build Mac: Xcode with Swift ≥ 6.3, the Metal Toolchain component
(`xcodebuild -downloadComponent MetalToolchain`), `brew install xcodegen cmake`, and the signing
identity. One SwiftPM cache serves builds and tests: `~/Library/Caches/muesli-spm/qm-release/`
(`swiftpm/` for SwiftPM, `xcodebuild/` for DerivedData). A cold build takes minutes; later ones are
incremental.

## Signing identity — Apple Development, team N66437Y9GD

| | |
| --- | --- |
| Identity | the newest valid `Apple Development: …` certificate in the build Mac's login keychain whose OU is team `N66437Y9GD` (the operator's free personal team); `build.sh` picks it by team, `--identity <SHA-1>` overrides |
| Designated requirement | `identifier "com.muesli.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = "N66437Y9GD"`; `muesli-cli` and Cotypist the same with their own identifiers |
| Renewal | before 2027-11-08 in Xcode → Settings → Accounts → Manage Certificates (QM-356, shared with T3 Code and Skills Hub). A renewed certificate of the same team satisfies the same requirement, so nothing is re-granted |
| Hardened runtime | none: nothing is notarized, so neither it nor library validation is needed |

Why the team: Muesli keeps its credentials (the ChatGPT login, API keys) in **legacy** login-Keychain
items (`KeychainCredentialVault`: a `SecAccess` with trusted applications, not the data-protection
keychain). Such an item also has a partition list, which admits code by Team ID, or, for code without
one, by each build's cdhash. A self-signed identity never carries a Team ID, so every rebuild raised a
login-keychain password prompt; with the team, the partition is `teamid:N66437Y9GD` and rebuilds pass
silently (QM ADR-0017). Privacy (TCC) grants and the items' ACLs record the designated requirement,
which pins the team rather than one certificate.

The work Mac needs no identity: it installs the zip built here, with the same signature.

## Signature costs — read before the first install

The official app is signed with the maintainer's Developer ID (team 58W55QJ567). Ours is signed with
our team, so macOS treats it as a different program for everything keyed to the code signature.
Switching a Mac to our build costs the following once; our rebuilds and certificate renewals keep
the same designated requirement and cost nothing again:

1. **Privacy (TCC) grants** — microphone, system audio capture, screen recording, accessibility,
   input monitoring, calendar, contacts, automation — must be granted again. Run the first install
   with `--reset-privacy` (`tccutil reset All com.muesli.app`), or macOS may silently deny grants it
   recorded for the old signature (Accessibility can show "on" while the app is not trusted).
   TCC records the designated requirement, so grants survive our rebuilds.
2. **Keychain.** Since 0.8.6 (preprod) upstream moves credentials into the login Keychain on first
   launch: the ChatGPT login (`chatgpt-auth.json`, then deleted), API keys and custom headers (removed
   from `config.json`), OpenRouter and Google Calendar tokens. Each item's ACL lists the app and
   `muesli-cli` by designated requirement, and its partition list admits our team. An item created
   under another signature raises one login-keychain password prompt for the new one: answer
   **Always Allow**, which adds our requirement and `teamid:N66437Y9GD`. If a build reads "signed
   out", sign in again and re-enter keys. Going back to the official app may not read items our
   build created. Stale items are
   `com.muesli.credentials.<sha256 of the support dir path>` in Keychain Access; delete them there if a
   save keeps failing.
3. **iCloud/CloudKit and push** are absent from this build. iCloud Sync must stay off (it is off in our
   config); turning it on cannot work here.
4. **Cotypist** (experimental, off by default) is signed with our team like the app; it was not
   tried with this build.
5. **Launch at login** registered by the official app may need re-enabling in Settings.
6. **Gatekeeper**: a locally built app carries no quarantine flag and launches. The zip copied to
   another Mac does: `install.sh` clears `com.apple.quarantine` on the installed copy.

## Deploy — `fork-infra/deploy.sh` (both Macs, every build)

```
fork-infra/deploy.sh --remote mac-uni-auto [--reset-privacy]   # work Mac first
fork-infra/deploy.sh --local [--reset-privacy]                 # MacBook Pro last
```

Every build that gets installed goes to **both Macs**, the same artifact, the same way: the work Mac
first, then the MacBook Pro. `deploy.sh` takes `release/Muesli-<VERSION>.zip` and refuses it unless
it matches its `.sha256`, carries `fork-infra/VERSION` and is signed with our team (Team ID and the
exact designated requirement). `--remote` copies the zip, its `.sha256` and `install.sh` to
`~/.local/share/muesli-qm/` on the host, re-checks the hash there and runs `install.sh --quit
--launch` on it; `--local` runs the same on this Mac. Both then check the installed version,
signature, Team ID and that Muesli is running again, and print `DEPLOY OK`. The remote keeps its
rollback copies in `~/.local/share/muesli-qm/release/previous/`. Pass `--reset-privacy` when a Mac
switches signature (from the official app or another identity); its operator then grants the
privacy prompts on that Mac's screen. A recording in progress on either Mac stops the deploy there.

## Install — `fork-infra/install.sh`

```
fork-infra/install.sh [--app <Muesli.app>] [--quit] [--reset-privacy] [--accept-adhoc] [--launch] [--dry-run]
fork-infra/install.sh --rollback [--quit] [--reset-privacy] [--launch]
```

With the operator present (privacy prompts follow the first launch). The script:

1. refuses an artifact with a Sparkle feed, and an ad-hoc build without `--accept-adhoc`;
2. refuses while Muesli runs unless `--quit`, and never quits during a recording
   (`meetings.meeting_status = 'recording'`);
3. backs up in place, in `~/Library/Application Support/Muesli/`: `muesli.db` through SQLite's backup
   API, and `config.json` without its credential fields;
4. moves the replaced app to `release/previous/Muesli-<version>-<ts>.app`, installs with `ditto`,
   verifies version and signature;
5. with `--reset-privacy`, resets the bundle's privacy grants; with `--launch`, opens the app with a
   scrubbed environment.

Logs go to `/tmp/muesli-qm-install-<ts>.log` on the Mac being installed. `deploy.sh` is the normal
way in; run `install.sh` directly only for a one-off. Rollback: `install.sh --rollback` reinstalls the newest app in
`release/previous/`; then sign in again (point 2) and, if needed, restore the database backup.

**Data direction.** A newer upstream base migrates the database and config forward on first launch
(the schema changes since 0.8.5 checked so far are additive: new tables and columns). An older official
release may not understand everything; the in-place backups are the way back.

## Update — `fork-infra/update.sh`

```
fork-infra/update.sh [--tag vX.Y.Z[-preprod.N]] [--releases-only] [--old-base <ref>]
                     [--no-push] [--no-build] [--version X.Y.Z-qm.N]
```

Fetches upstream tags, picks the newest release or preprod tag (`--tag` names one;
`--releases-only` skips preprods), replays exactly our commits from the current base tag onto it
(`rebase --autosquash --onto`), pushes `patched` to `origin` (force-with-lease), then runs
`build.sh`. It stops at a rebase conflict: resolve, continue, then push, test and build by hand. The
PR branches stay on `upstream/main`; rebase one only when offering it upstream. Then:

1. **Triage each patch against the new base by invariant, not by conflict** (below). A clean replay
   does not prove a patch still covers its concept; a conflict does not mean its intent is obsolete.
2. **Test**: `fork-infra/test.sh` on `patched`, and on the pure tag through a copy (the tag has no
   `fork-infra/`: `cp fork-infra/test.sh /tmp/ && git checkout <tag> && /tmp/test.sh`). It runs
   the three CI shards and the legacy-unsharded suites (`scripts/ci_unsharded_test_suites.txt`, which
   no shard runs; they include `MeetingAutoStopPolicyTests`) with build.sh's SwiftPM cache and prints
   one count line per run. Upstream can ship red tests: a failure on the pure tag is upstream's, not a
   patch's. Two `QoLTests` indicator-hover tests are timing-sensitive in the parallel core shard and
   fail now and then; rerun before triaging.
3. Bump `fork-infra/VERSION` (fixup commit; `build.sh` refuses a version below the base tag), build,
   then deploy to both Macs with the operator (Deploy, above).

### Per-patch invariants to grep on every new base

- **Stop recording when the meeting ends** (`auto-stop-on-meeting-end`). `MeetingAutoStopPolicy.swift`:
  `MeetingSignalLossResponse.stopAfterWarning` and `stoppingWhenMeetingEnds(_:)` (only `.warnOnly`
  becomes a stop; `.transcriptInactivity` and `.none` never do); `MeetingSignalLossPromptState`
  `isStopPending`, set only by `markPromptPresented(response:)` and cleared by user dismissal, source
  recovery, remote (`.system`) transcript activity, `markAutoDismissed` and `resetForRecording`;
  `markTimedOut()`. Channels: `noteTranscriptActivity(now:channel:)` returns false (warning stays,
  stop stays pending) for microphone or unattributed activity during a pending stop, and re-arms the
  warning on remote activity; `hasRecentTranscriptActivity(now:quietPeriod:response:)` reads only the
  system channel for `.stopAfterWarning`. `MuesliController`: both live transcript callbacks
  (`onChunkTranscribed`, `onPartialTranscript`) pass `MeetingTranscriptChannel(liveSpeaker:)`, which
  relies on `MeetingSession` labelling microphone text "You" (grep it); `noteMeetingTranscriptActivity`
  closes the warning only when the state says so; `presentMeetingSignalLossPromptIfNeeded` computes the
  response from `config.stopRecordingWhenMeetingEnds` once, uses it for the quiet check and
  `markPromptPresented`, and stops only from `onAutoDismiss` via `markTimedOut()`;
  `showMeetingEndNotification` must not replace a warning with a pending stop. If upstream adds another
  end-of-meeting warning, another path that closes that warning, another live transcript callback, a
  new speaker label, or a new source-tracking start origin, the patch must cover it.
- **Keep meeting AEC aligned across mic capture gaps** (`aec-realign-after-mic-gap`).
  `MeetingNeuralAec.processStreamingMic(_:capturedAt:)` inserts silence before a mic block that starts
  at least `minimumMicGapFrames` (200 ms) after the previous block's host-clock end, bounded by the
  system lead (`systemAbsoluteEndSample - micSamplesReceived`, itself at least 200 ms);
  `resetForStreaming()` clears `lastMicCaptureEndFrame`. `MeetingSession.enqueueRealtimeMicSamples`
  is the only mic feed into the AEC and calls that overload with `audio.startFrame`, adding the padded
  span to `screenMicSpans` before the block's span. If upstream adds another mic path into the AEC,
  or moves the AEC timelines to host time, re-check or drop the patch. Diagnostics:
  `aec.micGapCount` / `aec.micGapPaddedFrames` in `diagnostics.json`.
- **Lead the LocalVQE reference** (`localvqe-reference-lead`). `MeetingNeuralAec.referenceDelaySamples`
  returns `-localVQEReferenceLeadSamples` (−2,048 = 128 ms) for the `localvqe` processor, so each mic
  frame is paired with the system audio 128 ms after it and waits for it; LocalVQE only cancels
  echo whose playback reaches it first (window about 1 s). If upstream aligns the streams by host time, adds its own lead, or
  changes the LocalVQE model, replay a diagnostics run offline at several leads before dropping or
  keeping the patch.
- **Signing path**: `build.sh` relies on upstream's local-signing path in
  `scripts/build_native_app.sh` (`MUESLI_SKIP_SIGN=1` + `MUESLI_SIGN_IDENTITY`: signs every nested
  binary, framework and the app with the given identity, no hardened runtime) and then re-pins the
  app, `muesli-cli` and Cotypist. If upstream reworks that path or bundles new nested code that
  reads the Keychain, extend the re-pin.
- **Auto-record detected meetings** (`auto-record-detected-meetings`). `MeetingAutoRecordPolicy.swift`
  (`isStrongDetection`, `shouldAutoRecord` = strong + `MeetingPromptStateMachine.
  recordingStartedSuppressesSession`); `MuesliController.presentMeetingDetection` calls
  `autoRecordDetectedMeetingIfStrong` first, which starts through `startRecordingDetectedMeeting`, the
  prompt's own start path (`startOrigin: .detectedPrompt`); `MeetingNotificationController.show`'s
  `secondaryActionLabel`/`onSecondaryAction`. The strength rules read `MeetingCandidate.evidence`
  from `MeetingCandidateResolver`: when upstream adds an evidence kind, a candidate branch or a
  meeting app, re-check that dictation in another app still cannot qualify (the policy tests encode
  this). `MeetingDetector.swift` is legacy and unused by the live path.

## When something is wrong

- Muesli's diagnostics go to stderr, visible only when it is started from Terminal
  (`/Applications/Muesli.app/Contents/MacOS/Muesli`); meeting detection also logs to the unified log
  (`log stream --predicate 'subsystem == "com.muesli.native"'`). Our patches print
  `meeting signal lost; warning timed out, stopping recording` and
  `auto-recording detected meeting platform=<id>` to stderr.
- "Signed out" after an install or rebuild is point 2 of the signature costs, not a bug.
- `build.sh: no valid Apple Development identity of team N66437Y9GD`: see Signing identity (renew
  or re-create it in Xcode); never fall back to ad-hoc or self-signed for a build that gets installed.
- A login-keychain password prompt after an install means an item was created under another
  signature (Signature costs, point 2): Always Allow, once.
- A permission that shows as granted but does not work is point 1: reset privacy and grant again.
