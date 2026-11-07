import Foundation

/// Decides whether a detected meeting may start recording without the prompt
/// ("Auto-record detected meetings"). Only evidence that a call is live counts.
/// A microphone held by some other app, such as dictation, while a browser or a
/// meeting page is in front is not enough; such candidates keep the prompt.
enum MeetingAutoRecordPolicy {
    /// A strong detection whose call session the prompt state can mark as recorded,
    /// so stopping or discarding the recording cannot restart it during the same call.
    static func shouldAutoRecord(_ candidate: MeetingCandidate) -> Bool {
        isStrongDetection(candidate)
            && MeetingPromptStateMachine.recordingStartedSuppressesSession(of: candidate)
    }

    static func isStrongDetection(_ candidate: MeetingCandidate) -> Bool {
        let evidence = candidate.evidence
        // CoreAudio attributes the microphone to the candidate's own app (or its helper).
        let candidateHoldsMicrophone = evidence.contains(.audioInputProcess)

        // A dedicated meeting app (Zoom, Teams, Slack, Webex, FaceTime...) holding the microphone.
        if candidateHoldsMicrophone,
           let bundleID = candidate.sourceBundleID,
           MeetingCandidateResolver.dedicatedApps[bundleID] != nil {
            return true
        }
        // A meeting link open in the browser that holds the microphone.
        if candidateHoldsMicrophone, evidence.contains(.browserURL) {
            return true
        }
        // Microphone and camera together.
        if evidence.contains(.micActive), evidence.contains(.cameraActive) {
            return true
        }
        // A current calendar event while a call-capable app holds the microphone.
        if candidateHoldsMicrophone, evidence.contains(.calendarEvent) {
            return true
        }
        return false
    }
}
