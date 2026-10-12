import Foundation

// Adapted from Ifrit 2.0.6 (3f961f6d39cd2188305671f2ec65914d297571d0):
// Fuse Bitap by Kirollos Risk (2017), MIT; bestMatch by Tomas Ruiz Lopez
// (2021), Apache-2.0. Notices and licenses: LICENSES/IconSearch.txt.
// Changes: score-only implementation, iterative alignment DP, stable ties,
// diacritic folding and a safe edit-distance path for patterns over 64 characters.
enum IconSearch {
    struct Item {
        let title: String
        let bundle: String
    }
    static func matchingIndices(in items: [Item], query: String) -> [Int] {
        let query = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return Array(items.indices) }
        let titles = items.map { folded($0.title) }
        // Ice first filters/ranks with Fuse, then averages the Fuse result rank
        // with its boundary/camel-case alignment score. Bundle search is retained
        // as a secondary searchable title for NookBar.
        let candidates = items.indices.compactMap { index -> (Int, Double, String)? in
            let fields = [titles[index], folded(items[index].bundle)]
            let matches = fields.compactMap { field in fuseScore(query: query, input: field).map { ($0, field) } }
            guard let best = matches.min(by: { $0.0 < $1.0 }) else { return nil }
            return (index, best.0, best.1)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let count = Double(candidates.count)
        var ranked: [(index: Int, score: Double)] = []
        for (rank, candidate) in candidates.enumerated() {
            let fuseRank = count - Double(rank)
            let alignment = bestMatchScore(query: query, input: candidate.2)
            let combined: Double
            if let alignment { combined = (Double(alignment) + fuseRank) / 2 }
            else { combined = fuseRank }
            ranked.append((candidate.0, combined))
        }
        ranked.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        return ranked.map(\.index)
    }
    private static func folded(_ string: String) -> String {
        string.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    // Fuse's default location=0, distance=100, threshold=0.5, tokenize=false.
    static func fuseScore(query: String, input: String) -> Double? {
        let pattern = Array(query.lowercased()), text = Array(input.lowercased())
        guard !pattern.isEmpty, !text.isEmpty else { return nil }
        if pattern == text { return 0 }
        guard pattern.count <= 64 else { return longPatternScore(pattern, text) }
        let length = pattern.count
        var alphabet: [Character: UInt64] = [:]
        for (index, character) in pattern.enumerated() {
            alphabet[character, default: 0] |= UInt64(1) << (length - index - 1)
        }
        func score(_ errors: Int, _ location: Int) -> Double {
            Double(errors) / Double(length) + Double(abs(location)) / 100
        }
        var threshold = 0.5
        if text.count >= length {
            let exact = (0...(text.count - length)).filter { start in
                Array(text[start..<(start + length)]) == pattern
            }
            if let first = exact.first { threshold = min(threshold, score(0, first)) }
            // Match Fuse's reverse exact-match bound: location + 2 * pattern.len.
            if let last = exact.last(where: { $0 + length <= min(2 * length, text.count) }) {
                threshold = min(threshold, score(0, last))
            }
        }
        let mask = UInt64(1) << (length - 1)
        var result = 1.0, binaryMax = length + text.count
        var lastBits: [UInt64] = []
        for errors in 0..<length {
            var binaryMin = 0, binaryMid = binaryMax
            while binaryMin < binaryMid {
                if score(errors, binaryMid) <= threshold { binaryMin = binaryMid }
                else { binaryMax = binaryMid }
                binaryMid = (binaryMax - binaryMin) / 2 + binaryMin
            }
            binaryMax = binaryMid
            let finish = min(binaryMid, text.count) + length
            var bits = [UInt64](repeating: 0, count: finish + 2)
            bits[finish + 1] = (UInt64(1) << errors) &- 1
            for position in (1...finish).reversed() {
                let location = position - 1
                let matching = location < text.count ? alphabet[text[location], default: 0] : 0
                bits[position] = ((bits[position + 1] << 1) | 1) & matching
                if errors > 0 {
                    bits[position] |= (((lastBits[position + 1] | lastBits[position]) << 1) | 1) | lastBits[position + 1]
                }
                if bits[position] & mask != 0 {
                    result = score(errors, location)
                    if result <= threshold {
                        threshold = result
                        if location == 0 { break }
                    }
                }
            }
            if score(errors + 1, 0) > threshold { break }
            lastBits = bits
        }
        return result == 1 ? nil : result
    }
    // Arbitrary-length equivalent cost; avoids machine-word shift truncation.
    private static func longPatternScore(_ pattern: [Character], _ text: [Character]) -> Double? {
        guard pattern.count <= 2 * text.count else { return nil }
        let step = 1 / Double(pattern.count)
        var previous = (0...text.count).map { Double($0) / 100 }
        for (index, character) in pattern.enumerated() {
            var current = [Double](repeating: 0, count: text.count + 1)
            current[0] = Double(index + 1) * step
            for column in 1...text.count {
                current[column] = min(previous[column] + step, current[column - 1] + step,
                                      previous[column - 1] + (character == text[column - 1] ? 0 : step))
            }
            previous = current
        }
        guard let score = previous.min(), score <= 0.5 else { return nil }
        return score
    }
    // Exact bestMatch scoring with boundaryBonus=16, camelCaseBonus=16,
    // default match=16, consecutive=11, first character multiplier=2 and
    // default gap penalty (3 for one character, length+3 otherwise).
    static func bestMatchScore(query: String, input: String) -> Int? {
        let pattern = Array(query), text = Array(input)
        guard !pattern.isEmpty, !text.isEmpty, pattern.count <= text.count else { return nil }
        func matches(_ row: Int, _ column: Int) -> Bool {
            pattern[row].lowercased() == text[column].lowercased()
        }
        func bonus(_ row: Int, _ column: Int) -> Int {
            guard matches(row, column) else { return 0 }
            let boundary = column == 0 || ((text[column].isLetter || text[column].isNumber) &&
                !(text[column - 1].isLetter || text[column - 1].isNumber)) ? 16 : 0
            let camel = column > 0 && text[column - 1].isLowercase && text[column].isUppercase ? 16 : 0
            let adjacent = (row > 0 && column > 0 && matches(row - 1, column - 1)) ||
                (row + 1 < pattern.count && column + 1 < text.count && matches(row + 1, column + 1))
            return (row == 0 ? 2 : 1) * (boundary + camel + (adjacent ? 11 : 0))
        }
        var previous = [Int](repeating: 0, count: text.count + 1)
        for row in pattern.indices {
            var current = [Int](repeating: 0, count: text.count + 1)
            var bestOlderGap = Int.min / 2
            for column in 1...text.count {
                if column >= 2 { bestOlderGap = max(bestOlderGap, current[column - 2] + column - 2) }
                let match = previous[column - 1] + (matches(row, column - 1) ? 16 : 0) + bonus(row, column - 1)
                let gap = max(current[column - 1] - 3, bestOlderGap - column - 3)
                current[column] = max(0, match, gap)
            }
            previous = current
        }
        var bestColumn = 1, bestScore = Int.min
        for column in 1...text.count {
            let score = previous[column] + bonus(pattern.count - 1, column - 1)
            if score > bestScore { bestColumn = column; bestScore = score }
        }
        // Ifrit traceback accepts only an ordered subsequence through this end.
        var row = pattern.count - 1, column = bestColumn - 1
        while row >= 0 && column >= 0 {
            if matches(row, column) { row -= 1 }
            column -= 1
        }
        return row < 0 ? bestScore : nil
    }
}
