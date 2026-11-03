import Foundation
import KanaKanjiConverterModule

/// 連続したBackspaceの起点で表示していたライブ変換。
/// 消している箇所の手前2文字より前は変換結果を残し、そこから先だけを読みのまま表示する。
struct BackspaceConversionView: Sendable, Equatable {
    struct Cut: Sendable, Equatable {
        var reading: Int
        var text: Int
    }

    private static let kanaReach = 2

    private(set) var reading: [Character]
    private(set) var text: [Character]
    /// 読みと変換結果を切り離せる位置（昇順）。単語の境界と、単語の漢字に続くかなの中だけ。
    private(set) var cuts: [Cut]

    init?(reading: String, text: String, words: [(ruby: String, word: String)]) {
        guard words.map(\.word).joined() == text else {
            return nil
        }
        let normalizedReading = Array(reading.toHiragana())
        var cuts = [Cut(reading: 0, text: 0)]
        var readingPosition = 0
        var textPosition = 0
        for (ruby, word) in words {
            let ruby = Array(ruby.toHiragana())
            let word = Array(word)
            let readingEnd = readingPosition + ruby.count
            guard readingEnd <= normalizedReading.count,
                  Array(normalizedReading[readingPosition ..< readingEnd]) == ruby else {
                break
            }
            let textEnd = textPosition + word.count
            let kana = zip(ruby.reversed(), Array(String(word).toHiragana()).reversed())
                .prefix(while: { $0 == $1 })
                .count
            for k in stride(from: kana, through: 0, by: -1) {
                let cut = Cut(reading: readingEnd - k, text: textEnd - k)
                if cuts.last != cut {
                    cuts.append(cut)
                }
            }
            readingPosition = readingEnd
            textPosition = textEnd
        }
        guard cuts.count > 1 else {
            return nil
        }
        self.reading = Array(reading)
        self.text = Array(text)
        self.cuts = cuts
    }

    /// 現在の読みに対する表示。何も変換結果を残せない場合は`nil`（すべて読みで表示する）。
    func view(currentReading: String) -> String? {
        let now = Array(currentReading)
        let shared = zip(self.reading, now).prefix(while: { $0 == $1 }).count
        let limit = min(shared, max(now.count - Self.kanaReach, 0))
        guard let cut = self.cuts.last(where: { $0.reading <= limit }), cut.reading > 0 else {
            return nil
        }
        return String(self.text.prefix(cut.text)) + String(now[cut.reading...])
    }
}
