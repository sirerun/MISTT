import Foundation

/// Matches the configured phrase independently of recognizer segmentation.
/// Segment indices preserve the audio boundaries used for wake handoff.
enum WakePhraseMatcher {
    static func matches(_ segments: [String]) -> [ClosedRange<Int>] {
        let words = segments.enumerated().flatMap { index, text in
            text.lowercased().split(whereSeparator: { !$0.isLetter }).map { (String($0), index) }
        }
        guard words.count >= 2 else { return [] }
        return (1..<words.count).compactMap { index in
            guard words[index - 1].0 == "hey", words[index].0 == "zati" else { return nil }
            return words[index - 1].1...words[index].1
        }
    }
}
