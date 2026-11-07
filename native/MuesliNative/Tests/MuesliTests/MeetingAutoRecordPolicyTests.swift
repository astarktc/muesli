import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting auto-record policy")
struct MeetingAutoRecordPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let chrome = "com.google.Chrome"
    private let meetRoom = "meet.google.com/pwm-txwq-txy"

    private func snapshot(
        micActive: Bool = true,
        cameraActive: Bool = false,
        calendarEvent: CalendarEventContext? = nil,
        runningApps: [RunningAppInfo] = [],
        browserMeetings: [BrowserMeetingContext] = [],
        audioInputProcesses: [AudioProcessActivity] = [],
        foregroundBundleID: String? = nil
    ) -> MeetingSignalSnapshot {
        MeetingSignalSnapshot(
            micActive: micActive,
            cameraActive: cameraActive,
            calendarEvent: calendarEvent,
            runningApps: runningApps,
            browserMeetings: browserMeetings,
            audioInputProcesses: audioInputProcesses,
            foregroundBundleID: foregroundBundleID,
            now: now
        )
    }

    private func resolve(
        micActive: Bool = true,
        cameraActive: Bool = false,
        calendarEvent: CalendarEventContext? = nil,
        runningApps: [RunningAppInfo] = [],
        browserMeetings: [BrowserMeetingContext] = [],
        audioInputProcesses: [AudioProcessActivity] = [],
        foregroundBundleID: String? = nil
    ) -> MeetingCandidate? {
        resolve(snapshot(
            micActive: micActive, cameraActive: cameraActive, calendarEvent: calendarEvent,
            runningApps: runningApps, browserMeetings: browserMeetings,
            audioInputProcesses: audioInputProcesses, foregroundBundleID: foregroundBundleID
        ))
    }

    private func resolve(_ snapshot: MeetingSignalSnapshot) -> MeetingCandidate? {
        let resolver = MeetingCandidateResolver()
        resolver.selfBundleID = "com.muesli.app"
        return resolver.resolve(snapshot)
    }

    /// What the prompt path receives: the resolved candidate after media-session stabilization.
    private func promptCandidate(_ snapshot: MeetingSignalSnapshot) async throws -> MeetingCandidate {
        let resolved = try #require(resolve(snapshot))
        return try #require(await MeetingMediaSessionTracker().stabilize(candidate: resolved, snapshot: snapshot))
    }

    private func process(_ bundleID: String, output: Bool = true) -> AudioProcessActivity {
        AudioProcessActivity(pid: 4321, bundleID: bundleID, appName: bundleID,
                             isRunningInput: true, isRunningOutput: output)
    }

    private func meetTab(focused: Bool = true) -> BrowserMeetingContext {
        BrowserMeetingContext(bundleID: chrome, appName: "Chrome", pid: 1234, url: meetRoom,
                              normalizedID: "googleMeet:\(meetRoom)", platform: .googleMeet, isFocused: focused)
    }

    @Test("a dedicated meeting app holding the microphone is strong", arguments: [
        "us.zoom.xos", "com.microsoft.teams2", "com.webex.meetingmanager", "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap.helper",
    ])
    func dedicatedAppAudio(bundleID: String) throws {
        let candidate = try #require(resolve(audioInputProcesses: [process(bundleID)]))
        #expect(MeetingAutoRecordPolicy.isStrongDetection(candidate))
    }

    @Test("a meeting link in the browser that holds the microphone is strong", arguments: [true, false])
    func browserMeetingWithMicrophone(focused: Bool) throws {
        let candidate = try #require(resolve(
            runningApps: [RunningAppInfo(bundleID: chrome, isActive: focused)],
            browserMeetings: [meetTab(focused: focused)],
            audioInputProcesses: [process(chrome, output: false)],
            foregroundBundleID: focused ? chrome : nil
        ))
        #expect(candidate.url == meetRoom)
        #expect(MeetingAutoRecordPolicy.isStrongDetection(candidate))
    }

    @Test("microphone plus camera is strong, even on a site without a known meeting link")
    func microphoneAndCamera() throws {
        let candidate = try #require(resolve(
            cameraActive: true,
            runningApps: [RunningAppInfo(bundleID: chrome, isActive: true)],
            audioInputProcesses: [process(chrome, output: false)],
            foregroundBundleID: chrome
        ))
        #expect(candidate.url == nil)
        #expect(MeetingAutoRecordPolicy.isStrongDetection(candidate))
    }

    @Test("a current calendar event is strong when a call-capable app holds the microphone", arguments: [
        "com.google.Chrome", "com.microsoft.teams2",
    ])
    func calendarEventWithAttributedMicrophone(bundleID: String) throws {
        let candidate = try #require(resolve(
            calendarEvent: CalendarEventContext(id: "evt", title: "Weekly sync"),
            runningApps: [RunningAppInfo(bundleID: bundleID, isActive: true)],
            audioInputProcesses: [process(bundleID, output: false)],
            foregroundBundleID: bundleID
        ))
        #expect(candidate.evidence.contains(.calendarEvent))
        #expect(MeetingAutoRecordPolicy.isStrongDetection(candidate))
    }

    @Test("a browser holding the microphone without a meeting link or camera only prompts")
    func browserMicrophoneWithoutMeetingLink() throws {
        let candidate = try #require(resolve(
            runningApps: [RunningAppInfo(bundleID: chrome, isActive: true)],
            audioInputProcesses: [process(chrome, output: false)],
            foregroundBundleID: chrome
        ))
        #expect(!MeetingAutoRecordPolicy.isStrongDetection(candidate))
    }

    @Test("another app's dictation in front of a meeting tab only prompts")
    func dictationOverMeetingTab() throws {
        // The meeting host's page is in front, but the microphone belongs to a dictation app.
        let candidate = try #require(resolve(
            runningApps: [RunningAppInfo(bundleID: chrome, isActive: true)],
            browserMeetings: [meetTab()],
            audioInputProcesses: [process("com.example.dictation", output: false)],
            foregroundBundleID: chrome
        ))
        #expect(candidate.evidence.contains(.browserURL))
        #expect(!MeetingAutoRecordPolicy.isStrongDetection(candidate))
    }

    @Test("a meeting tab without any microphone activity only prompts")
    func meetingTabWithoutMicrophone() throws {
        let candidate = try #require(resolve(
            micActive: false,
            runningApps: [RunningAppInfo(bundleID: chrome, isActive: true)],
            browserMeetings: [meetTab()],
            foregroundBundleID: chrome
        ))
        #expect(!MeetingAutoRecordPolicy.isStrongDetection(candidate))
    }

    @Test("a strong call session auto-records, and starting it consumes the session")
    func strongSessionAutoRecords() async throws {
        let candidate = try await promptCandidate(snapshot(audioInputProcesses: [process("com.microsoft.teams2")]))
        #expect(MeetingAutoRecordPolicy.shouldAutoRecord(candidate))
        // Stopping the recording must not restart it while the same call goes on.
        let prompts = MeetingPromptStateMachine(candidateStabilityDelay: 0)
        #expect(prompts.markRecordingStarted(candidate))
        let decision = prompts.evaluate(
            candidate: candidate, detectionEnabled: true, isRecording: false, isStartingRecording: false,
            isCalendarNotificationVisible: false,
            visibility: MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil), now: now
        )
        #expect(decision.action == .none && decision.reason == .recordingStartedSuppression)
    }

    @Test("a strong detection that cannot be marked as recorded only prompts")
    func unscopedStrongDetectionPrompts() async throws {
        // Mic and camera during a calendar event, from an app Muesli cannot attribute:
        // nothing would stop this candidate from starting again after the user stops it.
        let candidate = try await promptCandidate(snapshot(
            cameraActive: true,
            calendarEvent: CalendarEventContext(id: "evt", title: "Weekly sync")
        ))
        #expect(MeetingAutoRecordPolicy.isStrongDetection(candidate))
        #expect(!MeetingAutoRecordPolicy.shouldAutoRecord(candidate))
    }

    @Test("dictation during a calendar event only prompts")
    func dictationDuringCalendarEvent() throws {
        // The mic belongs to no call-capable app; a meeting app merely runs in the background.
        let candidate = try #require(resolve(
            calendarEvent: CalendarEventContext(id: "evt", title: "Focus time"),
            runningApps: [RunningAppInfo(bundleID: "com.microsoft.teams2", isActive: false)],
            audioInputProcesses: [process("com.example.dictation", output: false)]
        ))
        #expect(candidate.evidence.contains(.calendarEvent))
        #expect(!MeetingAutoRecordPolicy.isStrongDetection(candidate))
    }
}
