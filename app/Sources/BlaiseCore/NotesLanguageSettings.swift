import Foundation

// The preferred notes language. The key lives in the existing `app_setting` KV
// table — no schema change.

/// The language new notes are written in. `automatic` follows the meeting's
/// detected language.
public enum NotesLanguage: String, Codable, Sendable, CaseIterable {
    case automatic
    case english = "en"
    case portuguese = "pt"

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (the meeting's language)"
        case .english: return "English"
        case .portuguese: return "Portuguese"
        }
    }

    /// `notes.preferredLanguage` — absent or undecodable ⇒ `automatic`.
    public static let key = "notes.preferredLanguage"

    public static func load(from store: SettingsStore) async -> NotesLanguage {
        (try? await store.get(key, as: NotesLanguage.self)) ?? nil ?? .automatic
    }

    public static func set(_ value: NotesLanguage, in store: SettingsStore) async throws {
        try await store.set(key, to: value)
    }

    /// Appended to the notes and digest prompts' "Dominant language:" line when
    /// the notes language differs from the detected one.
    public static let overrideClause =
        "The language named at the start of this line was chosen by the user and overrides any instruction to write in the meeting's language or never to translate. Phrases quoted verbatim, and company and product terms, still stay in their original language."

    /// The notes language for a meeting whose detected language is `detected`.
    public func resolve(detected: String) -> String {
        self == .automatic ? detected : rawValue
    }

    /// The one language rule every notes run uses. An automatic run of a meeting
    /// that already has notes keeps their stored language (empty ⇒ `detected`)
    /// and never reads the setting; a user-started run, or a meeting's first
    /// notes, follows the setting.
    public static func forRun(
        userStarted: Bool, storedNotesLanguage: String?, detected: String, store: SettingsStore
    ) async -> String {
        if !userStarted, let stored = storedNotesLanguage {
            return stored.isEmpty ? detected : stored
        }
        return await load(from: store).resolve(detected: detected)
    }
}
