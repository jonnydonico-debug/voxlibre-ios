import Foundation

/// Built-in defaults for the optional house agent. Empty in this repo, so the feature is off
/// until it's set up in Settings. A private build wired to your own assistant can fill these
/// in here, and only this file differs from upstream, which keeps updates easy to merge.
enum HouseAgentDefaults {
    /// What you call your house agent, e.g. "Jarvis".
    static let name = ""
    /// Its HTTPS address (the app calls `<url>/api/ring/ask`).
    static let url = ""
    /// Optional: what the house agent can do, added to the ring agent's instructions.
    static let capabilities = ""
}
