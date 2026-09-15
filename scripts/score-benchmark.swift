import Darwin
import Foundation

@main
enum BenchmarkScorer {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: murmur-score-benchmark RESULTS.jsonl\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let contents = try String(contentsOf: url, encoding: .utf8)
        var references: [String: String] = [:]
        var runs: [(caseID: String, raw: String, latency: Double?)] = []

        for (lineNumber, line) in contents.split(whereSeparator: { $0.isNewline }).enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let caseID = row["case_id"] as? String
            else { throw ScoringError.invalidRow(lineNumber + 1) }
            if let reference = row["reference_text"] as? String { references[caseID] = reference }
            if let raw = row["raw_text"] as? String {
                runs.append((caseID, raw, row["release_to_delivery_ms"] as? Double))
            }
        }

        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var referenceWords = 0
        var missing: [String] = []
        var latencies: [Double] = []
        for run in runs {
            guard let reference = references[run.caseID] else {
                missing.append(run.caseID)
                continue
            }
            let score = RecognitionMetrics.score(reference: reference, hypothesis: run.raw)
            substitutions += score.substitutions
            deletions += score.deletions
            insertions += score.insertions
            referenceWords += score.referenceWords
            if let latency = run.latency { latencies.append(latency) }
        }
        guard missing.isEmpty else { throw ScoringError.missingReferences(Array(Set(missing)).sorted()) }

        let errors = substitutions + deletions + insertions
        var report: [String: Any] = [
            "runs_scored": runs.count,
            "reference_words": referenceWords,
            "substitutions": substitutions,
            "deletions": deletions,
            "insertions": insertions,
            "word_error_rate": referenceWords == 0 ? Double(errors) : Double(errors) / Double(referenceWords),
            "normalization": "Unicode letters/numbers lowercased; punctuation separates words",
        ]
        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            report["release_to_delivery_ms_median"] = percentile(sorted, 0.5)
            report["release_to_delivery_ms_p95"] = percentile(sorted, 0.95)
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let index = max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))
        return sorted[index]
    }
}

private enum ScoringError: LocalizedError {
    case invalidRow(Int)
    case missingReferences([String])

    var errorDescription: String? {
        switch self {
        case let .invalidRow(line): return "Invalid JSONL benchmark row at line \(line)."
        case let .missingReferences(ids): return "Missing reference text for: \(ids.joined(separator: ", "))."
        }
    }
}
