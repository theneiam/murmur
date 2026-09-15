import Foundation

struct RecognitionScore: Equatable {
    var substitutions: Int
    var deletions: Int
    var insertions: Int
    var referenceWords: Int

    var totalErrors: Int { substitutions + deletions + insertions }
    var wordErrorRate: Double {
        referenceWords == 0 ? Double(totalErrors) : Double(totalErrors) / Double(referenceWords)
    }
}

enum RecognitionMetrics {
    /// Computes a conventional word error rate after a documented, minimal
    /// normalization: Unicode letters/numbers are lowercased and punctuation
    /// is treated as a separator. Raw transcript text is never persisted here.
    static func score(reference: String, hypothesis: String) -> RecognitionScore {
        let expected = words(in: reference)
        let actual = words(in: hypothesis)
        var table = Array(
            repeating: Array(repeating: RecognitionScore(substitutions: 0, deletions: 0, insertions: 0, referenceWords: expected.count), count: actual.count + 1),
            count: expected.count + 1
        )
        for row in 1 ..< table.count { table[row][0].deletions = row }
        for column in 1 ..< table[0].count { table[0][column].insertions = column }

        guard !expected.isEmpty, !actual.isEmpty else { return table[expected.count][actual.count] }
        for row in 1 ... expected.count {
            for column in 1 ... actual.count {
                if expected[row - 1] == actual[column - 1] {
                    table[row][column] = table[row - 1][column - 1]
                } else {
                    var substitution = table[row - 1][column - 1]
                    substitution.substitutions += 1
                    var deletion = table[row - 1][column]
                    deletion.deletions += 1
                    var insertion = table[row][column - 1]
                    insertion.insertions += 1
                    table[row][column] = [substitution, deletion, insertion].min {
                        $0.totalErrors < $1.totalErrors
                    }!
                }
            }
        }
        return table[expected.count][actual.count]
    }

    static func words(in text: String) -> [String] {
        text.lowercased().split { character in
            !character.isLetter && !character.isNumber && character != "'"
        }.map(String.init)
    }
}
