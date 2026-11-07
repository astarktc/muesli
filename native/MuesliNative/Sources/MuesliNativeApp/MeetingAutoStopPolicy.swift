import Foundation

enum MeetingRecordingStartOrigin: Equatable {
    case manual
    case detectedPrompt
    case calendarAutoRecord
    case scheduledMeetingPrompt
    case joinAndRecord

    var tracksMeetingSource: Bool {
        switch self {
        case .manual:
            return false
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return true
        }
    }

    var signalLossResponse: MeetingSignalLossResponse {
        switch self {
        case .manual:
            return .transcriptInactivity
        case .detectedPrompt:
            return .warnOnly
        case .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return .warnOnly
        }
    }

    func signalLossSource(
        explicitSource: MeetingAutoStopSource?,
        recentSource: @autoclosure () -> MeetingAutoStopSource?
    ) -> MeetingAutoStopSource? {
        switch self {
        case .manual:
            return nil
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return explicitSource ?? recentSource()
        }
    }
}

enum MeetingSignalLossResponse: Equatable {
    case none
    case warnOnly
    /// Warn first; stop the recording if the warning times out with no user decision.
    case stopAfterWarning
    case transcriptInactivity

    /// Applies the opt-in "stop recording when the meeting ends" setting. Only a
    /// source-backed warning can stop; manual reminders and untracked recordings never do.
    func stoppingWhenMeetingEnds(_ enabled: Bool) -> MeetingSignalLossResponse {
        switch self {
        case .warnOnly, .stopAfterWarning:
            return enabled ? .stopAfterWarning : .warnOnly
        case .none, .transcriptInactivity:
            return self
        }
    }
}

/// The side of a meeting that live transcript text came from.
enum MeetingTranscriptChannel: Equatable {
    /// The user's microphone: the user, and anyone else talking in the room.
    case microphone
    /// System audio: the remote participants.
    case system

    /// MeetingSession labels live microphone text "You" and system-audio text "Others".
    /// Any other label counts as remote, which can only keep a recording going.
    init(liveSpeaker: String) {
        self = liveSpeaker == "You" ? .microphone : .system
    }
}

struct MeetingSignalLossPromptState: Equatable {
    private(set) var isPromptSuppressed = false
    private(set) var isDismissedForRecording = false
    private(set) var lastTranscriptActivityAt: Date?
    private(set) var lastSystemTranscriptActivityAt: Date?
    /// The visible warning stops the recording if it times out unanswered.
    private(set) var isStopPending = false

    static let transcriptQuietPeriod: TimeInterval = 45
    static let notificationDuration: TimeInterval = 30

    var inactivityDeadline: Date? {
        guard canPresentPrompt, let lastTranscriptActivityAt else { return nil }
        return lastTranscriptActivityAt.addingTimeInterval(Self.transcriptQuietPeriod)
    }

    var canPresentPrompt: Bool {
        !isPromptSuppressed && !isDismissedForRecording
    }

    mutating func resetForRecording() {
        isPromptSuppressed = false
        isDismissedForRecording = false
        lastTranscriptActivityAt = nil
        lastSystemTranscriptActivityAt = nil
        isStopPending = false
    }

    /// Records transcript activity and returns whether it shows the meeting is still
    /// going on, which closes a visible warning. `channel` is nil for activity that is
    /// not speech (the recording starting or resuming). A pending stop listens to the
    /// remote side only: the user talking in the room after the call must not cancel it.
    /// Remote speech cancels it and lets the warning return once the remote side has
    /// been quiet for the quiet period again.
    @discardableResult
    mutating func noteTranscriptActivity(now: Date, channel: MeetingTranscriptChannel? = nil) -> Bool {
        lastTranscriptActivityAt = now
        if channel == .system { lastSystemTranscriptActivityAt = now }
        guard isStopPending else { return true }
        guard channel == .system else { return false }
        isStopPending = false
        isPromptSuppressed = false
        return true
    }

    /// Whether recent transcript activity defers the warning. A stopping warning
    /// judges the meeting by the remote side only, so speech in the room after the
    /// call cannot keep an ended meeting recording.
    func hasRecentTranscriptActivity(
        now: Date,
        quietPeriod: TimeInterval,
        response: MeetingSignalLossResponse = .warnOnly
    ) -> Bool {
        let lastActivity = response == .stopAfterWarning ? lastSystemTranscriptActivityAt : lastTranscriptActivityAt
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) < quietPeriod
    }

    mutating func markPromptPresented(response: MeetingSignalLossResponse = .warnOnly) {
        isPromptSuppressed = true
        isStopPending = response == .stopAfterWarning && !isDismissedForRecording
    }

    mutating func markSourceRecovered() {
        isPromptSuppressed = false
        isStopPending = false
    }

    /// Closing the warning means "keep recording" for the rest of this recording.
    mutating func markDismissedByUser() {
        isPromptSuppressed = true
        isDismissedForRecording = true
        isStopPending = false
    }

    /// The warning closed without timing out: speech resumed, or it could not be shown.
    mutating func markAutoDismissed() {
        isPromptSuppressed = true
        isStopPending = false
    }

    /// The warning ran its full duration with no user decision. Returns whether
    /// that timeout stops the recording.
    mutating func markTimedOut() -> Bool {
        let stops = isStopPending && !isDismissedForRecording
        markAutoDismissed()
        return stops
    }
}

struct MeetingAutoStopSource: Equatable {
    let candidateID: String?
    let suppressionID: String?
    let normalizedURL: String?
    let sourceBundleID: String?
    let hasObservedCandidate: Bool

    private init(
        candidateID: String?,
        suppressionID: String?,
        normalizedURL: String?,
        sourceBundleID: String?,
        hasObservedCandidate: Bool
    ) {
        self.candidateID = candidateID
        self.suppressionID = suppressionID
        self.normalizedURL = normalizedURL
        self.sourceBundleID = sourceBundleID
        self.hasObservedCandidate = hasObservedCandidate
    }

    init(candidate: MeetingCandidate) {
        self.candidateID = candidate.id
        self.suppressionID = candidate.suppressionID
        self.normalizedURL = candidate.url
        self.sourceBundleID = candidate.sourceBundleID
        self.hasObservedCandidate = true
    }

    init?(meetingURL: URL) {
        guard let normalized = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
            return nil
        }
        self.candidateID = normalized.id
        self.suppressionID = normalized.id
        self.normalizedURL = normalized.url
        self.sourceBundleID = nil
        self.hasObservedCandidate = false
    }

    func refined(with candidate: MeetingCandidate) -> MeetingAutoStopSource {
        let refinedSuppressionID = candidate.suppressionID == candidate.id
            ? suppressionID ?? candidate.suppressionID
            : candidate.suppressionID
        return MeetingAutoStopSource(
            candidateID: candidateID ?? candidate.id,
            suppressionID: refinedSuppressionID,
            normalizedURL: normalizedURL ?? candidate.url,
            sourceBundleID: sourceBundleID ?? candidate.sourceBundleID,
            hasObservedCandidate: true
        )
    }
}

struct MeetingAutoStopTracker: Equatable {
    private(set) var source: MeetingAutoStopSource?
    private(set) var lastSeenAt: Date?
    private var observedBeforeRecordingStarted = false

    var isArmed: Bool {
        source != nil
    }

    mutating func arm(source: MeetingAutoStopSource?) {
        self.source = source
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
    }

    mutating func disarm() {
        source = nil
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
    }

    mutating func observeBeforeRecordingStarted(candidate: MeetingCandidate?) {
        guard let currentSource = source,
              let candidate,
              MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) else {
            return
        }
        source = currentSource.refined(with: candidate)
        observedBeforeRecordingStarted = true
    }

    mutating func markRecordingStarted(now: Date) {
        guard observedBeforeRecordingStarted, lastSeenAt == nil else { return }
        lastSeenAt = now
        observedBeforeRecordingStarted = false
    }

    mutating func observe(
        candidate: MeetingCandidate?,
        now: Date,
        gracePeriod: TimeInterval
    ) -> Bool {
        guard let currentSource = source else {
            return false
        }

        if let candidate,
           MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) {
            source = currentSource.refined(with: candidate)
            lastSeenAt = now
            return false
        }

        guard let lastSeenAt else {
            return false
        }

        return now.timeIntervalSince(lastSeenAt) >= gracePeriod
    }
}

enum MeetingAutoStopPolicy {
    static func matches(candidate: MeetingCandidate, source: MeetingAutoStopSource) -> Bool {
        // Missing room evidence permits a media fallback; conflicting room
        // evidence must never extend the original recording, even in one browser.
        if let room = source.normalizedURL, let candidateRoom = candidate.url,
           room != candidateRoom { return false }
        if candidate.id == source.candidateID
            || candidate.suppressionID == source.suppressionID
            || (source.normalizedURL != nil && candidate.url == source.normalizedURL) {
            return true
        }
        guard let sourceBundle = source.sourceBundleID,
              let candidateBundle = candidate.sourceBundleID,
              bundleIDsReferToSameApp(sourceBundle, candidateBundle) else { return false }
        // Native sources have no room identity. Browser sources need observed
        // media attribution when their room URL is temporarily unavailable.
        return source.normalizedURL == nil
            || (source.hasObservedCandidate && candidate.evidence.contains(.audioInputProcess))
    }

    static func bundleIDsReferToSameApp(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.lowercased()
        let rhs = rhs.lowercased()
        return lhs == rhs || lhs.hasPrefix("\(rhs).") || rhs.hasPrefix("\(lhs).")
    }
}
