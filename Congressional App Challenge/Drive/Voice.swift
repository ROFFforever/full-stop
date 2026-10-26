import AVFoundation // Text-to-speech and the audio session.

// Speaks the coach's short phrases out loud, offline. Music or a podcast is turned down (ducked) only while a phrase
// plays, then comes back. Plays even with the ring/silent switch on silent: a driver can't check it.
@MainActor
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt,
                                                         options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }

    func say(_ text: String) {
        guard AppSettings.voice else { return } // Spoken alerts turned off in Settings.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) } // The newest alert is the one that matters.
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.53 // A little faster than default (0.5): alerts must be short.
        synthesizer.speak(utterance)
    }

    func finish() {
        synthesizer.stopSpeaking(at: .immediate)
        release()
    }

    // Done talking: give other audio its volume back.
    private func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { self.release() } }
    }
}
