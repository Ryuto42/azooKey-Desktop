/// 開き括弧と閉じ括弧の対応
public enum BracketPair {
    /// `text`が開き括弧1文字なら、対になる閉じ括弧
    public static func closing(for text: String) -> String? {
        pairs[text]
    }

    /// `text`の中で最後に開いたまま閉じていない括弧の、閉じ括弧
    public static func unclosedClosing(in text: String) -> String? {
        var opened: [String] = []
        for character in text {
            let c = String(character)
            if let closing = pairs[c] {
                opened.append(closing)
            } else if opened.last == c {
                opened.removeLast()
            }
        }
        return opened.last
    }

    private static let pairs: [String: String] = [
        "（": "）", "「": "」", "『": "』", "【": "】", "［": "］", "｛": "｝", "〔": "〕", "〈": "〉", "《": "》",
        "〘": "〙", "〚": "〛", "｢": "｣", "(": ")", "[": "]", "{": "}", "“": "”", "‘": "’",
    ]
}
