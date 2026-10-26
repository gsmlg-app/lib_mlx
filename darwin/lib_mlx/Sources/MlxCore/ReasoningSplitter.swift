import Foundation

/// Holds only a possible delimiter suffix, so markers split across tokens never leak.
struct ReasoningSplitter {
    private(set) var reasoning = false
    private var pending = ""
    private let opening = "<|channel>thought\n"
    private let closing = "<channel|>"
    mutating func append(_ text: String, final: Bool = false) -> [MlxGenerationEvent] {
        pending += text
        var events: [MlxGenerationEvent] = []
        while !pending.isEmpty {
            let delimiter = reasoning ? closing : opening
            if let range = pending.range(of: delimiter) {
                let prefix = String(pending[..<range.lowerBound])
                if !prefix.isEmpty { events.append(reasoning ? .reasoningDelta(prefix) : .textDelta(prefix)) }
                pending = String(pending[range.upperBound...]); reasoning.toggle()
                continue
            }
            var retained = 0
            if !final {
                for length in 1..<delimiter.count where pending.hasSuffix(delimiter.prefix(length)) { retained = length }
            }
            let emitted = String(pending.dropLast(retained))
            if !emitted.isEmpty { events.append(reasoning ? .reasoningDelta(emitted) : .textDelta(emitted)) }
            pending = String(pending.suffix(retained))
            break
        }
        return events
    }
}
