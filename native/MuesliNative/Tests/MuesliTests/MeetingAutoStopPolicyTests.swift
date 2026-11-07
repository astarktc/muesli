import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting auto-stop policy")
struct MeetingAutoStopPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let room = "meet.google.com/aaa-bbbb-ccc"

    private func candidate(
        id: String = "room-a", url: String? = "meet.google.com/aaa-bbbb-ccc",
        bundle: String? = "com.google.Chrome", media: Bool = true,
        suppressionID: String? = "session-a"
    ) -> MeetingCandidate {
        MeetingCandidate(
            id: id, platform: .googleMeet, appName: "Meeting", url: url,
            evidence: media ? [.audioInputProcess] : [.browserURL],
            startedAt: now, meetingTitle: nil, sourceBundleID: bundle,
            suppressionID: suppressionID
        )
    }

    @Test("room identity wins over browser attribution and shared suppression IDs")
    func roomMatching() {
        let source = MeetingAutoStopSource(candidate: candidate())
        let cases: [(MeetingCandidate, Bool)] = [
            (candidate(), true),
            (candidate(id: "calendar-wrapped", suppressionID: "calendar"), true),
            (candidate(id: "audio-fallback", url: nil), true),
            (candidate(id: "new-session", url: nil, suppressionID: "new"), true),
            (candidate(id: "helper", url: nil, bundle: "com.google.Chrome.helper", suppressionID: "new"), true),
            (candidate(id: "foreground", url: nil, media: false, suppressionID: "new"), false),
            (candidate(id: "safari", url: nil, bundle: "com.apple.Safari", suppressionID: "new"), false),
            (candidate(id: "unattributed", url: nil, bundle: nil, suppressionID: "new"), false),
            (candidate(id: "room-b", url: "meet.google.com/zzz-yyyy-xxx", suppressionID: "new"), false),
            // Even a reused browser session or candidate ID cannot override a conflicting URL.
            (candidate(url: "meet.google.com/zzz-yyyy-xxx"), false)
        ]
        for (observed, expected) in cases {
            #expect(MeetingAutoStopPolicy.matches(candidate: observed, source: source) == expected)
        }
    }

    @Test("native source survives new helper/session identity, but not another app")
    func nativeMatching() {
        let source = MeetingAutoStopSource(candidate: candidate(url: nil, bundle: "com.microsoft.teams2"))
        #expect(MeetingAutoStopPolicy.matches(
            candidate: candidate(id: "new", url: nil, bundle: "com.microsoft.teams2.helper", suppressionID: "new"), source: source
        ))
        #expect(!MeetingAutoStopPolicy.matches(
            candidate: candidate(id: "new", url: nil, bundle: "us.zoom.xos", suppressionID: "new"), source: source
        ))
    }

    @Test("URL-only sources need observation and retain identity during refinement")
    func refinement() throws {
        let url = try #require(URL(string: "https://\(room)?authuser=0"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))
        #expect(source.candidateID == "googleMeet:\(room)")
        #expect(source.normalizedURL == room && !source.hasObservedCandidate)
        #expect(!MeetingAutoStopPolicy.matches(candidate: candidate(id: "fallback", url: nil), source: source))
        let refined = source.refined(with: candidate())
        #expect(refined.sourceBundleID == "com.google.Chrome" && refined.hasObservedCandidate)
        #expect(refined.suppressionID == "session-a")
        #expect(refined.normalizedURL == room)
        let partial = source.refined(with: candidate(id: "partial", url: nil, suppressionID: nil))
        #expect(partial.suppressionID == source.suppressionID)
        #expect(MeetingAutoStopSource(candidate: candidate()).hasObservedCandidate)
    }

    @Test("source-backed origins warn without stopping recording", arguments: [
        MeetingRecordingStartOrigin.manual, .detectedPrompt, .calendarAutoRecord,
        .scheduledMeetingPrompt, .joinAndRecord
    ])
    func startOrigin(origin: MeetingRecordingStartOrigin) {
        let explicit = MeetingAutoStopSource(candidate: candidate())
        let recent = MeetingAutoStopSource(candidate: candidate(id: "recent", url: nil))
        let tracksSource = origin != .manual
        let expectedSignalLoss: MeetingSignalLossResponse = tracksSource ? .warnOnly : .transcriptInactivity
        #expect(origin.tracksMeetingSource == tracksSource)
        #expect(origin.signalLossResponse == expectedSignalLoss)
        #expect(origin.signalLossSource(explicitSource: explicit, recentSource: recent) == (tracksSource ? explicit : nil))
        #expect(origin.signalLossSource(explicitSource: nil, recentSource: recent) == (tracksSource ? recent : nil))
    }

    @Test("stopping when the meeting ends applies only to source-backed warnings", arguments: [
        MeetingRecordingStartOrigin.manual, .detectedPrompt, .calendarAutoRecord,
        .scheduledMeetingPrompt, .joinAndRecord
    ])
    func stopWhenMeetingEnds(origin: MeetingRecordingStartOrigin) {
        let expected: MeetingSignalLossResponse = origin == .manual ? .transcriptInactivity : .stopAfterWarning
        #expect(origin.signalLossResponse.stoppingWhenMeetingEnds(true) == expected)
        #expect(origin.signalLossResponse.stoppingWhenMeetingEnds(false) == origin.signalLossResponse)
        #expect(MeetingSignalLossResponse.stopAfterWarning.stoppingWhenMeetingEnds(false) == .warnOnly)
        #expect(MeetingSignalLossResponse.none.stoppingWhenMeetingEnds(true) == MeetingSignalLossResponse.none)
    }

    @Test("an unanswered stopping warning stops the recording; other warnings never do", arguments: [
        (MeetingSignalLossResponse.stopAfterWarning, true),
        (MeetingSignalLossResponse.warnOnly, false),
        (MeetingSignalLossResponse.transcriptInactivity, false)
    ])
    func timeoutStops(response: MeetingSignalLossResponse, stops: Bool) {
        var state = MeetingSignalLossPromptState()
        state.markPromptPresented(response: response)
        #expect(state.isStopPending == stops)
        let stopped = state.markTimedOut()
        #expect(stopped == stops)
        #expect(!state.isStopPending)
        // Like an auto-dismissal, a timeout waits for the source to recover before warning again.
        #expect(!state.canPresentPrompt)
    }

    @Test("closing the warning keeps recording for the rest of the recording")
    func dismissalKeepsRecording() {
        var state = MeetingSignalLossPromptState()
        state.markPromptPresented(response: .stopAfterWarning)
        state.markDismissedByUser()
        #expect(!state.isStopPending)
        let stopped = state.markTimedOut()
        #expect(!stopped)
        state.markSourceRecovered()
        #expect(!state.canPresentPrompt)
        state.resetForRecording()
        #expect(state.canPresentPrompt)
    }

    @Test("renewed remote speech, a recovered source, or a non-timeout close cancels a pending stop")
    func pendingStopCancelled() {
        var state = MeetingSignalLossPromptState()
        state.markPromptPresented(response: .stopAfterWarning)
        state.noteTranscriptActivity(now: now, channel: .system)
        let stoppedAfterSpeech = state.markTimedOut()
        #expect(!stoppedAfterSpeech)

        state.markSourceRecovered()
        state.markPromptPresented(response: .stopAfterWarning)
        state.markSourceRecovered()
        let stoppedAfterRecovery = state.markTimedOut()
        #expect(!stoppedAfterRecovery)

        state.markSourceRecovered()
        state.markPromptPresented(response: .stopAfterWarning)
        state.markAutoDismissed() // Closed because speech resumed, or the panel could not show.
        let stoppedAfterClose = state.markTimedOut()
        #expect(!stoppedAfterClose)

        state.markSourceRecovered()
        state.markPromptPresented(response: .stopAfterWarning)
        state.resetForRecording()
        #expect(!state.isStopPending)
    }

    @Test("with the setting on, the user talking in the room after the meeting source is lost still stops")
    func micSpeechAfterSourceLossStops() {
        let response = MeetingRecordingStartOrigin.detectedPrompt.signalLossResponse.stoppingWhenMeetingEnds(true)
        var state = MeetingSignalLossPromptState()
        state.noteTranscriptActivity(now: now, channel: .system) // The remote side's last words.
        state.noteTranscriptActivity(now: now.addingTimeInterval(58), channel: .microphone)
        // The source has been gone past its grace period: only remote speech defers the warning.
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(60), quietPeriod: 45, response: response))
        state.markPromptPresented(response: response)
        let closesWarning = state.noteTranscriptActivity(now: now.addingTimeInterval(70), channel: .microphone)
        #expect(!closesWarning)
        let stopped = state.markTimedOut()
        #expect(stopped)
    }

    @Test("with the setting on, remote speech continuing after the source is lost keeps recording")
    func remoteSpeechKeepsRecording() {
        let response = MeetingRecordingStartOrigin.joinAndRecord.signalLossResponse.stoppingWhenMeetingEnds(true)
        var state = MeetingSignalLossPromptState()
        state.noteTranscriptActivity(now: now.addingTimeInterval(50), channel: .system)
        #expect(state.hasRecentTranscriptActivity(now: now.addingTimeInterval(60), quietPeriod: 45, response: response))
        state.noteTranscriptActivity(now: now.addingTimeInterval(90), channel: .system)
        #expect(state.hasRecentTranscriptActivity(now: now.addingTimeInterval(134), quietPeriod: 45, response: response))
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(135), quietPeriod: 45, response: response))
        state.markPromptPresented(response: response)
        let closesWarning = state.noteTranscriptActivity(now: now.addingTimeInterval(140), channel: .system)
        #expect(closesWarning)
        #expect(!state.isStopPending)
        let stopped = state.markTimedOut()
        #expect(!stopped)
    }

    @Test("with the setting on, a stop cancelled by remote speech warns again once the remote side is quiet")
    func cancelledStopWarnsAgain() {
        let response = MeetingSignalLossResponse.stopAfterWarning
        var state = MeetingSignalLossPromptState()
        state.markPromptPresented(response: response)
        state.noteTranscriptActivity(now: now.addingTimeInterval(10), channel: .system)
        #expect(state.canPresentPrompt)
        #expect(state.hasRecentTranscriptActivity(now: now.addingTimeInterval(54.9), quietPeriod: 45, response: response))
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(55), quietPeriod: 45, response: response))
        state.markPromptPresented(response: response)
        state.noteTranscriptActivity(now: now.addingTimeInterval(60), channel: .microphone)
        let stopped = state.markTimedOut()
        #expect(stopped)
    }

    @Test("with the setting on, closing the warning keeps recording whatever either side says afterwards")
    func dismissalOutlastsSpeech() {
        let response = MeetingSignalLossResponse.stopAfterWarning
        var state = MeetingSignalLossPromptState()
        state.markPromptPresented(response: response)
        state.markDismissedByUser()
        state.noteTranscriptActivity(now: now.addingTimeInterval(10), channel: .system)
        state.noteTranscriptActivity(now: now.addingTimeInterval(20), channel: .microphone)
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(120), quietPeriod: 45, response: response))
        #expect(!state.canPresentPrompt)
        #expect(!state.isStopPending)
        let stopped = state.markTimedOut()
        #expect(!stopped)
    }

    @Test("with the setting off, speech on either side defers and closes the warning, which never stops", arguments: [
        MeetingTranscriptChannel.microphone, .system
    ])
    func settingOffKeepsUpstreamWarning(channel: MeetingTranscriptChannel) {
        let response = MeetingRecordingStartOrigin.calendarAutoRecord.signalLossResponse.stoppingWhenMeetingEnds(false)
        #expect(response == .warnOnly)
        var state = MeetingSignalLossPromptState()
        state.noteTranscriptActivity(now: now.addingTimeInterval(58), channel: channel)
        #expect(state.hasRecentTranscriptActivity(now: now.addingTimeInterval(60), quietPeriod: 45, response: response))
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(103), quietPeriod: 45, response: response))
        state.markPromptPresented(response: response)
        #expect(!state.isStopPending)
        let closesWarning = state.noteTranscriptActivity(now: now.addingTimeInterval(110), channel: channel)
        #expect(closesWarning)
        // As upstream: no further warning until the source recovers, and a timeout never stops.
        #expect(!state.canPresentPrompt)
        let stopped = state.markTimedOut()
        #expect(!stopped)
    }

    @Test("live speaker labels map to transcript channels; unknown labels count as remote")
    func liveSpeakerChannels() {
        #expect(MeetingTranscriptChannel(liveSpeaker: "You") == .microphone)
        #expect(MeetingTranscriptChannel(liveSpeaker: "Others") == .system)
        #expect(MeetingTranscriptChannel(liveSpeaker: "Speaker 2") == .system)
    }

    @Test("manual reminder waits a full quiet period, including an initially empty transcript")
    func manualReminderDeadline() {
        var state = MeetingSignalLossPromptState()
        #expect(state.inactivityDeadline == nil) // Still preparing.
        state.noteTranscriptActivity(now: now) // Recording became active.
        #expect(state.inactivityDeadline == now.addingTimeInterval(45))
        #expect(state.hasRecentTranscriptActivity(now: now.addingTimeInterval(44.9), quietPeriod: 45))
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(45), quietPeriod: 45))
        state.noteTranscriptActivity(now: now.addingTimeInterval(30))
        #expect(state.inactivityDeadline == now.addingTimeInterval(75))
        state.resetForRecording() // Stop/discard or a different recording.
        #expect(state.inactivityDeadline == nil)
    }

    @Test("manual reminders do not repeat until activity resumes, and explicit dismissal lasts for the recording")
    func manualReminderSuppression() {
        var state = MeetingSignalLossPromptState()
        state.noteTranscriptActivity(now: now)
        state.markPromptPresented()
        state.markAutoDismissed()
        #expect(state.inactivityDeadline == nil)
        state.markSourceRecovered()
        state.noteTranscriptActivity(now: now.addingTimeInterval(100))
        #expect(state.inactivityDeadline == now.addingTimeInterval(145))
        state.markDismissedByUser()
        state.markSourceRecovered()
        state.noteTranscriptActivity(now: now.addingTimeInterval(200))
        #expect(state.inactivityDeadline == nil)
        state.resetForRecording()
        state.noteTranscriptActivity(now: now.addingTimeInterval(300))
        #expect(state.inactivityDeadline == now.addingTimeInterval(345))
        #expect(MeetingSignalLossPromptState.notificationDuration == 30)
    }

    @Test("recent transcript activity defers a signal-loss warning")
    func transcriptActivity() {
        var state = MeetingSignalLossPromptState()
        #expect(!state.hasRecentTranscriptActivity(now: now, quietPeriod: 45))
        state.noteTranscriptActivity(now: now)
        #expect(state.hasRecentTranscriptActivity(now: now.addingTimeInterval(44), quietPeriod: 45))
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(45), quietPeriod: 45))
        state.resetForRecording()
        #expect(!state.hasRecentTranscriptActivity(now: now, quietPeriod: 45))
    }

    @Test("source recovery reopens prompts unless the user dismissed them", arguments: [false, true])
    func promptLifetime(dismissed: Bool) {
        var state = MeetingSignalLossPromptState()
        #expect(state.canPresentPrompt)
        state.markPromptPresented()
        #expect(!state.canPresentPrompt)
        if dismissed { state.markDismissedByUser() }
        state.markSourceRecovered()
        #expect(state.canPresentPrompt == !dismissed)
        state.resetForRecording()
        #expect(state.canPresentPrompt)
    }

    @Test("unobserved source cannot auto-stop; confirmed source uses disappearance grace")
    func disappearance() throws {
        var tracker = MeetingAutoStopTracker()
        let url = try #require(URL(string: "https://\(room)"))
        tracker.arm(source: MeetingAutoStopSource(meetingURL: url))
        let shouldStop1 = tracker.observe(candidate: nil, now: now, gracePeriod: 20)
        #expect(!shouldStop1)
        #expect(tracker.lastSeenAt == nil)
        let shouldStop2 = tracker.observe(candidate: candidate(), now: now, gracePeriod: 20)
        #expect(!shouldStop2)
        #expect(tracker.source?.sourceBundleID == "com.google.Chrome")
        #expect(tracker.source?.hasObservedCandidate == true)
        let shouldStop3 = tracker.observe(candidate: nil, now: now.addingTimeInterval(19), gracePeriod: 20)
        #expect(!shouldStop3)
        let shouldStop4 = tracker.observe(candidate: nil, now: now.addingTimeInterval(21), gracePeriod: 20)
        #expect(shouldStop4)
        tracker.disarm()
        #expect(!tracker.isArmed && tracker.lastSeenAt == nil)
    }

    @Test("media fallback extends grace, but a different known room does not")
    func fallbackGrace() {
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: MeetingAutoStopSource(candidate: candidate()))
        let shouldStop5 = tracker.observe(candidate: candidate(), now: now, gracePeriod: 20)
        #expect(!shouldStop5)
        let shouldStop6 = tracker.observe(candidate: candidate(id: "fallback", url: nil, suppressionID: "new"),
                                now: now.addingTimeInterval(30), gracePeriod: 20)
        #expect(!shouldStop6)
        let shouldStop7 = tracker.observe(candidate: nil, now: now.addingTimeInterval(49), gracePeriod: 20)
        #expect(!shouldStop7)
        let shouldStop8 = tracker.observe(candidate: candidate(id: "room-b", url: "meet.google.com/zzz-yyyy-xxx"),
                               now: now.addingTimeInterval(51), gracePeriod: 20)
        #expect(shouldStop8)
    }

    @Test("startup observation starts grace at recording start, not preparation")
    func preparationGrace() throws {
        var tracker = MeetingAutoStopTracker()
        let url = try #require(URL(string: "https://\(room)"))
        tracker.arm(source: MeetingAutoStopSource(meetingURL: url))
        tracker.observeBeforeRecordingStarted(candidate: candidate())
        tracker.markRecordingStarted(now: now.addingTimeInterval(10))
        #expect(tracker.source?.sourceBundleID == "com.google.Chrome")
        let shouldStop9 = tracker.observe(candidate: nil, now: now.addingTimeInterval(29), gracePeriod: 20)
        #expect(!shouldStop9)
        let shouldStop10 = tracker.observe(candidate: nil, now: now.addingTimeInterval(31), gracePeriod: 20)
        #expect(shouldStop10)
    }
}
