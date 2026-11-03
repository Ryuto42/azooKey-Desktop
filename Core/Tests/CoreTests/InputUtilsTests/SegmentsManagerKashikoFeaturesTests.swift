@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private final class StubContextDelegate: SegmentManagerDelegate {
    var left: String?
    init(left: String?) {
        self.left = left
    }
    func getLeftSideContext(maxCount: Int) -> String? {
        self.left.map { String($0.utf16.suffix(maxCount)) ?? $0 }
    }
    func getRightSideContext(maxCount: Int) -> String? {
        nil
    }
}

private func makeSegmentsManager() -> SegmentsManager {
    SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentsManagerKashikoFeaturesTests-\(UUID().uuidString)", isDirectory: true),
        containerURL: nil,
        context: .init(useZenzai: false)
    )
}

private func element(_ word: String, _ ruby: String) -> DicdataElement {
    DicdataElement(word: word, ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: 0)
}

// MARK: - 左文脈の行結合

@Test func joinContextLinesTurnsLineBreaksIntoSentenceBreaks() {
    #expect(SegmentsManager.joinContextLines("矢入さんの話\n\n  そのあとで\n  今日は") == "矢入さんの話。そのあとで。今日は")
    #expect(SegmentsManager.joinContextLines("終わり。\n「はい」\nよし！\n次") == "終わり。「はい」よし！次")
    #expect(SegmentsManager.joinContextLines("一行目\r\n二行目") == "一行目。二行目")
    #expect(SegmentsManager.joinContextLines("前\n今の行 ") == "前。今の行 ")
    #expect(SegmentsManager.joinContextLines("\n今") == "今")
    #expect(SegmentsManager.joinContextLines("前\n") == "前。")
}

@Test func cleanLeftSideContextKeepsEarlierLinesAndTail() {
    let manager = makeSegmentsManager()
    let delegate = StubContextDelegate(left: "矢入さんに会った\n今日は")
    manager.delegate = delegate
    #expect(manager.getCleanLeftSideContext() == "矢入さんに会った。今日は")

    delegate.left = String(repeating: "あ", count: 100) + "\nいう"
    let context = manager.getCleanLeftSideContext()
    #expect(context?.count == 64)
    #expect(context?.hasSuffix("あ。いう") == true)
}

// MARK: - Backspace中の表示

@Test func backspaceViewKeepsWordsBeforeTheCaret() {
    let view = BackspaceConversionView(
        reading: "やいりさんについては",
        text: "矢入さんについては",
        words: [("ヤイリ", "矢入"), ("サン", "さん"), ("ニツイテ", "について"), ("ハ", "は")]
    )
    #expect(view?.view(currentReading: "やいりさんについて") == "矢入さんについて")
    #expect(view?.view(currentReading: "やいりさんについ") == "矢入さんについ")
    #expect(view?.view(currentReading: "やいりさんにつけ") == "矢入さんにつけ")
    #expect(view?.view(currentReading: "やいりさ") == nil)
}

@Test func backspaceViewCutsInsideTheKanaAfterKanji() {
    let view = BackspaceConversionView(
        reading: "けんきゅうしつにいきました",
        text: "研究室に行きました",
        words: [("ケンキュウシツ", "研究室"), ("ニ", "に"), ("イキマシタ", "行きました")]
    )
    #expect(view?.view(currentReading: "けんきゅうしつにいきまし") == "研究室に行きまし")
    #expect(view?.view(currentReading: "けんきゅうしつにいき") == "研究室にいき")
    #expect(view?.view(currentReading: "けんきゅうしつに") == nil)
}

@Test func backspaceViewRejectsMismatchedData() {
    #expect(BackspaceConversionView(reading: "かんじ", text: "漢字", words: [("カンジ", "感じ")]) == nil)
    #expect(BackspaceConversionView(reading: "かんじ", text: "漢字", words: [("ヘンカン", "漢字")]) == nil)
}

@MainActor
@Test func backspaceInLiveConversionKeepsTheFarPartConverted() {
    guard Config.LiveConversion().value else {
        return
    }
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kenkyuushitsuniikimashita", inputStyle: .roman2kana)
    let before = manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
    #expect(before != manager.convertTarget)

    manager.deleteBackwardFromCursorPosition(keepsLiveConversion: true)
    let after = manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
    #expect(manager.convertTarget == "けんきゅうしつにいきまし")
    #expect(after.hasSuffix("まし"))
    #expect(after != manager.convertTarget)

    let committed = manager.commitMarkedText(inputState: .composing)
    #expect(committed == after)
}

@MainActor
@Test func backspaceOutsideLiveConversionShowsKana() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kenkyuushitsuniikimashita", inputStyle: .roman2kana)
    manager.deleteBackwardFromCursorPosition()
    #expect(manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined() == "けんきゅうしつにいきまし")
}

// MARK: - 確定の取り消し

@MainActor
@Test func undoLastCommitRestoresTheReadingOfAllCommittedParts() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("かんじへんかん", inputStyle: .direct)
    manager.prefixCandidateCommited(
        Candidate(text: "漢字", value: 0, composingCount: .surfaceCount(3), lastMid: 0, data: [element("漢字", "カンジ")]),
        leftSideContext: ""
    )
    #expect(manager.lastCommit == nil)
    manager.prefixCandidateCommited(
        Candidate(text: "変換", value: 0, composingCount: .surfaceCount(4), lastMid: 0, data: [element("変換", "ヘンカン")]),
        leftSideContext: ""
    )
    #expect(manager.isEmpty)
    #expect(manager.lastCommit?.reading == "かんじへんかん")
    #expect(manager.lastCommit?.text == "漢字変換")

    let undone = manager.undoLastCommit()
    #expect(undone?.text == "漢字変換")
    #expect(manager.convertTarget == "かんじへんかん")
    #expect(manager.lastCommit == nil)
}

@MainActor
@Test func commitMarkedTextIsUndoableAndNewInputDiscardsIt() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("あいう", inputStyle: .direct)
    let text = manager.commitMarkedText(inputState: .composing)
    #expect(manager.lastCommit?.reading == "あいう")
    #expect(manager.lastCommit?.text == text)

    manager.insertAtCursorPosition("え", inputStyle: .direct)
    #expect(manager.lastCommit == nil)
    #expect(manager.undoLastCommit() == nil)
}

@MainActor
@Test func discardedCommitCannotBeUndone() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("あいう", inputStyle: .direct)
    _ = manager.commitMarkedText(inputState: .composing)
    manager.discardLastCommit()
    #expect(manager.undoLastCommit() == nil)
    #expect(manager.isEmpty)
}

// MARK: - 候補の選択の始め方

@Test func upAndDownArrowsStartCandidateSelection() {
    for direction in [UserAction.NavigationDirection.up, .down] {
        let (action, callback) = InputState.composing.event(
            eventCore: KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: direction == .up ? 126 : 125),
            userAction: .navigation(direction),
            inputLanguage: .japanese,
            liveConversionEnabled: true,
            enableDebugWindow: false,
            enableSuggestion: false
        )
        guard case .transition(.selecting) = callback else {
            Issue.record("Expected candidate selection for \(direction), got \(callback)")
            continue
        }
        switch (direction, action) {
        case (.up, .selectPrevCandidateWrapping), (.down, .enterCandidateSelectionMode):
            break
        default:
            Issue.record("Unexpected \(action) for \(direction)")
        }
    }
}

@MainActor
@Test func kanaCandidatesComeLastAndUpArrowReachesHiraganaThenKatakana() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kanji", inputStyle: .roman2kana)
    manager.insertCompositionSeparator(inputStyle: .roman2kana, skipUpdate: true)
    manager.update(requestRichCandidates: true)
    guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("No candidates")
        return
    }
    #expect(candidates.suffix(2).map(\.text) == ["カンジ", "かんじ"])
    #expect(candidates.first?.text != "かんじ")
    manager.selectPrevCandidateWrapping()
    #expect(manager.selectedCandidate?.text == "かんじ")
    manager.selectPrevCandidateWrapping()
    #expect(manager.selectedCandidate?.text == "カンジ")
}

@MainActor
private func startSelection(_ manager: SegmentsManager) -> String {
    let live = manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
    manager.insertCompositionSeparator(inputStyle: .roman2kana, skipUpdate: true)
    manager.update(requestRichCandidates: true)
    manager.enterCandidateSelection(liveText: live)
    return live
}

@MainActor
@Test func selectionSkipsTheCandidateShownByLiveConversion() {
    guard Config.LiveConversion().value else {
        return
    }
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kanji", inputStyle: .roman2kana)
    let live = startSelection(manager)
    let shown = manager.getCurrentMarkedText(inputState: .selecting).map(\.content).joined()
    #expect(shown != live)
    #expect(shown.allSatisfy { !($0.isASCII && $0.isLetter) })
}

@MainActor
@Test func selectionShowsTheRestOfTheSentenceConverted() {
    guard Config.LiveConversion().value else {
        return
    }
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kyouhagoogledekensaku", inputStyle: .roman2kana)
    let live = manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
    manager.insertCompositionSeparator(inputStyle: .roman2kana, skipUpdate: true)
    manager.update(requestRichCandidates: true)
    let marked = manager.getCurrentMarkedText(inputState: .selecting)
    #expect(marked.map(\.content).joined() == live)
    #expect(marked.text.last?.content.contains("ごお") == false)
}

@MainActor
@Test func lastPendingNIsConvertedAsNAndCommitted() {
    guard Config.LiveConversion().value else {
        return
    }
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kanjihenkan", inputStyle: .roman2kana)
    let live = manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
    #expect(!live.hasSuffix("n"))
    #expect(manager.commitMarkedText(inputState: .composing) == live)

    // 「ん」とした変換の次の入力が、前の変換に引きずられない
    manager.insertAtCursorPosition("nigen", inputStyle: .roman2kana)
    #expect(manager.convertTarget == "にげn")
    #expect(!manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined().hasPrefix("ん"))
}

@MainActor
@Test func inputAfterCommittingEverythingStartsFresh() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kanji", inputStyle: .roman2kana)
    manager.insertCompositionSeparator(inputStyle: .roman2kana, skipUpdate: true)
    manager.update(requestRichCandidates: true)
    _ = manager.getCurrentMarkedText(inputState: .selecting)
    guard let whole = manager.selectedCandidate else {
        Issue.record("No candidate")
        return
    }
    manager.prefixCandidateCommited(whole, leftSideContext: "")
    #expect(manager.isEmpty)
    // Spaceで入れた区切りが残っていると、`n`が「ん」に確定して「んい」になる
    manager.insertAtCursorPosition("ni", inputStyle: .roman2kana)
    #expect(manager.convertTarget == "に")
}

// MARK: - 括弧

@Test func openingBracketsHaveTheirClosingBracket() {
    #expect(BracketPair.closing(for: "（") == "）")
    #expect(BracketPair.closing(for: "「") == "」")
    #expect(BracketPair.closing(for: "『") == "』")
    #expect(BracketPair.closing(for: "【") == "】")
    #expect(BracketPair.closing(for: "あ") == nil)
    #expect(BracketPair.closing(for: "「あ") == nil)
}

@Test func unclosedBracketIsFoundAfterTheText() {
    #expect(BracketPair.unclosedClosing(in: "（括弧") == "）")
    #expect(BracketPair.unclosedClosing(in: "今日は「会議") == "」")
    #expect(BracketPair.unclosedClosing(in: "「会議」") == nil)
    #expect(BracketPair.unclosedClosing(in: "（「あ」") == "）")
}

@MainActor
@Test func pendingClosingBracketFollowsTheComposingTextAndIsCommittedWithIt() {
    let manager = makeSegmentsManager()
    manager.pendingClosingBracket = "）"
    manager.insertAtCursorPosition("kaigi", inputStyle: .roman2kana)
    let marked = manager.getCurrentMarkedText(inputState: .composing)
    let text = marked.map(\.content).joined()
    #expect(text.hasSuffix("）"))
    #expect(marked.selectionRange.location == text.utf16.count - 1)
    #expect(manager.commitMarkedText(inputState: .composing) == text)
    #expect(manager.pendingClosingBracket == nil)

    // 括弧の中を消し切ったら、閉じ括弧は入れない
    manager.pendingClosingBracket = "）"
    manager.insertAtCursorPosition("a", inputStyle: .roman2kana)
    manager.deleteBackwardFromCursorPosition()
    #expect(manager.pendingClosingBracket == nil)
}

@MainActor
@Test func spaceDoesNotJumpToTheKanaCandidatesAtTheEnd() {
    guard Config.LiveConversion().value else {
        return
    }
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kanjihenkan", inputStyle: .roman2kana)
    _ = startSelection(manager)
    let selected = manager.selectedCandidate?.text
    #expect(selected != "かんじへんかん")
    #expect(selected != "カンジヘンカン")
}

@MainActor
@Test func selectionLoopsAroundBothEnds() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kanji", inputStyle: .roman2kana)
    manager.insertCompositionSeparator(inputStyle: .roman2kana, skipUpdate: true)
    manager.update(requestRichCandidates: true)
    guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("No candidates")
        return
    }
    manager.requestSelectingRow(candidates.count - 1)
    manager.requestSelectingNextCandidate()
    #expect(manager.selectedCandidate?.text == candidates.first?.text)
    manager.selectPrevCandidateWrapping()
    #expect(manager.selectedCandidate?.text == candidates.last?.text)
}
