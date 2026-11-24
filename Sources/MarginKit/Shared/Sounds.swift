import AppKit

/// The seven interface sounds (the "Paper" set). Files live in the app bundle's Resources/Sounds.
public enum SoundEffect: String, CaseIterable, Sendable {
    case arrive, step, collapse, expand, snap, done, installed
}

/// Plays interface sounds. Used only by the first-launch tour and the "updated" card, so ordinary
/// use stays silent. Silent when the files are missing (an unbundled `swift run`) or when the
/// user switched sounds off.
@MainActor
public enum Sounds {
    private static let key = "margin.sounds"
    private static var cache: [SoundEffect: NSSound] = [:]

    /// The "Sounds" menu item. Defaults to on.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    public static func play(_ effect: SoundEffect) {
        guard isEnabled, let sound = sound(for: effect) else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private static func sound(for effect: SoundEffect) -> NSSound? {
        if let s = cache[effect] { return s }
        guard let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "mp3", subdirectory: "Sounds"),
              let s = NSSound(contentsOf: url, byReference: true) else { return nil }
        s.volume = effect == .step ? 0.45 : 0.55
        cache[effect] = s
        return s
    }
}
