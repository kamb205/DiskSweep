import Foundation

/// Sorts audio and DAW project files into producer-friendly groups by reading their file names
/// (e.g. "Track - Unmastered.wav", "808 bass loop.wav", "Hook Vocals.aif").
enum MusicTagger {
    static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "flac", "m4a", "aac", "ogg", "caf", "alac"]
    static let projectExtensions: Set<String> = ["flp", "als", "ptx", "rpp", "cpr", "song", "aup3", "band"]
    static let minimumSize: Int64 = 100_000

    struct Group {
        let name: String
        let symbol: String
        let pattern: NSRegularExpression?
    }

    /// Checked in order; the first match wins (so "unmastered" is never filed under Master).
    static let groups: [Group] = [
        group("Projects", "folder.badge.gearshape", nil),
        group("Unmastered", "slider.horizontal.below.square.filled.and.square", #"\bun-?master(ed)?\b|\bpre-?master|\bno[ _-]?master"#),
        group("Masters", "checkmark.seal", #"\bmaster(ed|s)?\b|\bfinal\b"#),
        group("Vocals", "music.mic", #"\b(vocals?|vox|acapp?ella|a capp?ella|adlibs?|ad-libs?|hooks?|verse|chorus)\b"#),
        group("Bass & 808s", "speaker.wave.3", #"\b(bass|808s?|sub|subs|bassline)\b"#),
        group("Drums", "circle.grid.cross", #"\b(drums?|kicks?|snares?|hats?|hi-?hats?|perc(ussion)?|claps?|cymbals?|toms?)\b"#),
        group("Melodies & Keys", "pianokeys", #"\b(melody|melodies|keys|piano|guitar|synths?|chords?|pads?|lead|strings|arp)\b"#),
        group("Stems", "square.stack.3d.up", #"\bstems?\b|\bmultitracks?\b|\btracks? ?out\b"#),
        group("Samples & Loops", "waveform", #"\b(samples?|sampled|chops?|chopped|loops?|one-?shots?|fx|riser)\b"#),
        group("Instrumentals & Beats", "music.quarternote.3", #"\b(instrumentals?|inst|beats?|type beat|prod)\b"#),
        group("Mixes & Bounces", "dial.medium", #"\b(mix|mixdown|mixed|rough|bounce[ds]?|demo|draft|v\d+|version|export(ed)?)\b"#),
        group("Remixes & Covers", "arrow.triangle.2.circlepath", #"\b(remix(es)?|cover|flip|edit|bootleg|rebalanced|mashup|sped up|slowed)\b"#),
    ]

    private static func group(_ name: String, _ symbol: String, _ pattern: String?) -> Group {
        Group(name: name, symbol: symbol,
              pattern: pattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) })
    }

    static func isMusicFile(extension ext: String) -> Bool {
        audioExtensions.contains(ext) || projectExtensions.contains(ext)
    }

    static let otherGroup = "Other Audio"

    /// The group for an audio or project file, plus the word in its name that matched.
    /// Audio with no recognisable tag goes to "Other Audio"; anything else returns nil.
    static func group(forFileName fileName: String) -> (group: String, match: String?)? {
        if let tagged = classify(fileName: fileName) { return (tagged.group, tagged.match) }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext) ? (otherGroup, nil) : nil
    }

    /// The group for a file, plus the word in its name that matched; nil when the name has no tag.
    static func classify(fileName: String) -> (group: String, match: String)? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if projectExtensions.contains(ext) { return ("Projects", ext.uppercased() + " project") }
        guard audioExtensions.contains(ext) else { return nil }
        // Treat _ and - as spaces so names like "track_vocals_v2" still match whole words.
        let stem = (fileName as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
        let range = NSRange(stem.startIndex..., in: stem)
        for group in groups {
            guard let pattern = group.pattern,
                  let match = pattern.firstMatch(in: stem, range: range),
                  let matchRange = Range(match.range, in: stem) else { continue }
            return (group.name, String(stem[matchRange]))
        }
        return nil
    }

    static func symbol(for groupName: String) -> String {
        groups.first { $0.name == groupName }?.symbol ?? "music.note"
    }
}
