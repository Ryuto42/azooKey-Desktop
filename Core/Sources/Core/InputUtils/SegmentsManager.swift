import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public final class SegmentsManager {
    private static let textReplacer = TextReplacer.withDefaultEmojiDictionary()

    public init(
        kanaKanjiConverter: KanaKanjiConverter,
        applicationDirectoryURL: URL,
        containerURL: URL?,
        context: Context = Context()
    ) {
        self.kanaKanjiConverter = kanaKanjiConverter
        self.conversionSessionID = kanaKanjiConverter.createSession()
        self.applicationDirectoryURL = applicationDirectoryURL
        self.containerURL = containerURL
        self.context = context
    }

    /// テストなどの設定注入のための型。外部には設定を露出させない。
    public struct Context {
        public init() {}
        public init(useZenzai: Bool, resourcesDirectoryURL: URL? = nil) {
            self.useZenzai = useZenzai
            self.resourcesDirectoryURL = resourcesDirectoryURL
        }

        var useZenzai: Bool = true
        var resourcesDirectoryURL: URL?
    }

    public weak var delegate: (any SegmentManagerDelegate)?
    private let kanaKanjiConverter: KanaKanjiConverter
    private let conversionSessionID: KanaKanjiConverter.ConversionSessionID

    deinit {
        self.kanaKanjiConverter.removeSession(self.conversionSessionID)
    }

    /// 辞書・モデルは共有し、変換中の状態は入力セッションごとに分離する。
    @MainActor
    private func withConverter<Result>(_ operation: (KanaKanjiConverter) -> Result) -> Result {
        do {
            return try self.kanaKanjiConverter.withSession(self.conversionSessionID) {
                operation(self.kanaKanjiConverter)
            }
        } catch {
            // このセッションを破棄するのは自分自身のdeinitだけ。
            preconditionFailure("SegmentsManager lost its conversion session: \(error)")
        }
    }
    private let applicationDirectoryURL: URL
    private let containerURL: URL?
    private let context: Context

    private var composingText: ComposingText = ComposingText()
    private var lastInputStyle: InputStyle = .direct

    private var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }
    private var zenzaiPersonalizationLevel: Config.ZenzaiPersonalizationLevel.Value {
        Config.ZenzaiPersonalizationLevel().value
    }
    private var rawCandidates: ConversionResult?

    private var selectionIndex: Int?
    private var didExperienceSegmentEdition = false
    private var lastOperation: Operation = .other
    private var shouldShowCandidateWindow = false

    private var isShowingAdditionalCandidates = false
    private var additionalCandidates: [CandidatePresentation] = []
    private var showingAdditionalCandidateCount = 0
    private var isFixingAdditionalCandidateTop = false

    private var shouldShowDebugCandidateWindow: Bool = false
    private var debugCandidates: [Candidate] = []

    private var replaceSuggestions: [Candidate] = []
    private var suggestSelectionIndex: Int?
    private var backspaceAdjustedPredictionCandidate: PredictionCandidate?
    private var backspaceTypoCorrectionLock: BackspaceTypoCorrectionLock?
    private var backspaceConversionView: BackspaceConversionView?

    /// 確定した文字列と、その確定で学習した候補。
    public struct CommittedText: Sendable {
        public var reading: String
        public var text: String
        var learnedCandidates: [Candidate]
    }
    /// 現在の入力のうち、すでに確定した部分
    private var pendingCommit: CommittedText?
    /// 直前に完了した入力の確定内容。取り消しの対象になる
    public private(set) var lastCommit: CommittedText?

    public struct PredictionCandidate: Sendable, Equatable {
        public var displayText: String
        public var appendText: String
        public var deleteCount: Int = 0
    }

    struct BackspaceTypoCorrectionLock: Sendable {
        var displayText: String
        var targetReading: String
    }

    public func makeCandidatePresentations(_ candidates: [Candidate]) -> [CandidatePresentation] {
        let additionalPresentations = self.additionalCandidatePresentationsForSelectionIndex
        return candidates.indices.map { index in
            if index < additionalPresentations.count {
                return .init(candidate: candidates[index], displayContext: additionalPresentations[index].displayContext)
            }
            return .init(candidate: candidates[index])
        }
    }

    private lazy var zenzaiPersonalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode? = self.getZenzaiPersonalizationMode()

    private func getZenzaiPersonalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        let alpha = self.zenzaiPersonalizationLevel.alpha
        // オフなので。
        if alpha == 0 {
            return nil
        }
        guard let containerURL else {
            self.appendDebugMessage("❌ Failed to get container URL.")
            return nil
        }

        let base = self.resourcesDirectoryURL.appendingPathComponent("lm", isDirectory: false).path
        let personal = containerURL.appendingPathComponent("Library/Application Support/p13n_v1").path + "/lm"
        // check personal lm existence
        guard [
            FileManager.default.fileExists(atPath: personal + "_c_abc.marisa"),
            FileManager.default.fileExists(atPath: personal + "_r_xbx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_abx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_xbc.marisa")
        ].allSatisfy(\.self) else {
            self.appendDebugMessage("❌ Seems like there is missing marisa file for prefix \(personal)")
            return nil
        }

        return .init(baseNgramLanguageModel: base, personalNgramLanguageModel: personal, alpha: alpha)
    }

    private enum Operation: Sendable {
        case insert
        case delete
        case editSegment
        case other
    }

    private enum ContextLength {
        /// クライアントに要求する長さ（UTF-16）。前の行まで届くよう長めに取る
        static let conversion = 160
        /// 行を結合した後に残す文字数
        static let keptLeftCharacters = 64
    }

    public func appendDebugMessage(_ string: String) {
        self.debugCandidates.insert(
            Candidate(
                text: string.replacingOccurrences(of: "\n", with: "\\n"),
                value: 0,
                composingCount: .surfaceCount(0),
                lastMid: 0,
                data: []
            ),
            at: 0
        )
        while self.debugCandidates.count > 100 {
            self.debugCandidates.removeLast()
        }
    }

    private func zenzaiMode(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool,
        inferenceLimit: Int? = nil
    ) -> ConvertRequestOptions.ZenzaiMode {
        if !self.context.useZenzai {
            return .off
        }
        return .on(
            weight: self.resourcesDirectoryURL.appendingPathComponent("ggml-model-Q5_K_M.gguf", isDirectory: false),
            inferenceLimit: inferenceLimit ?? Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            personalizationMode: self.zenzaiPersonalizationMode,
            versionDependentMode: .v3(
                .init(
                    profile: Config.ZenzaiProfile().value,
                    leftSideContext: leftSideContext,
                    rightSideContext: rightSideContext,
                    enableAlignmentSeparator: true,
                    )
            )
        )
    }

    private var resourcesDirectoryURL: URL {
        if let resourcesDirectoryURL = self.context.resourcesDirectoryURL {
            return resourcesDirectoryURL
        }
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    private var metadata: ConvertRequestOptions.Metadata {
        if let tag = PackageMetadata.gitTag {
            .init(versionString: "azooKey on macOS (\(tag))")
        } else if let commit = PackageMetadata.gitCommit {
            .init(versionString: "azooKey on macOS (\(commit.prefix(7)))")
        } else {
            .init(versionString: "azooKey on macOS (unknown version)")
        }
    }

    private func options(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool,
        requireJapanesePrediction: ConvertRequestOptions.PredictionMode,
        requireEnglishPrediction: ConvertRequestOptions.PredictionMode,
        inferenceLimit: Int? = nil
    ) -> ConvertRequestOptions {
        .init(
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            learningType: Config.Learning().value.learningType,
            memoryDirectoryURL: self.azooKeyMemoryDir,
            sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.azooKeyMemoryDir),
            textReplacer: Self.textReplacer,
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: self.zenzaiMode(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates,
                inferenceLimit: inferenceLimit
            ),
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: self.metadata
        )
    }

    private func hasDebugTypoCorrectionWeights() -> Bool {
        DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: self.downloadedInputN5LMDir)
    }

    public var azooKeyMemoryDir: URL {
        self.applicationDirectoryURL
    }

    public var downloadedInputN5LMDir: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.applicationDirectoryURL.deletingLastPathComponent()
        )
    }

    @MainActor
    public func activate() {
        self.shouldShowCandidateWindow = false
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.zenzaiPersonalizationMode = self.getZenzaiPersonalizationMode()
    }

    @MainActor
    public func reloadUserDictionary() {
        self.withConverter { converter in
            converter.updateUserDictionaryURL(
                CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.azooKeyMemoryDir),
                forceReload: true
            )
        }
    }

    @MainActor
    public func resetLearningData() {
        self.withConverter { $0.resetMemory() }
    }

    @MainActor
    public func deactivate(flushLearningData: Bool = true) {
        self.withConverter { $0.stopComposition() }
        if flushLearningData {
            self.withConverter { $0.commitUpdateLearningData() }
        }
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.composingText.stopComposition()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.pendingCommit = nil
        self.lastCommit = nil
    }

    @MainActor
    /// この入力を打ち切る
    public func stopComposition() {
        self.pendingClosingBracket = nil
        self.composingText.stopComposition()
        self.withConverter { $0.stopComposition() }
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.pendingCommit = nil
    }

    @MainActor
    /// 日本語入力自体をやめる
    public func stopJapaneseInput() {
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.withConverter { $0.commitUpdateLearningData() }
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.pendingCommit = nil
        self.lastCommit = nil
    }

    /// 変換キーを押したタイミングで入力の区切りを示す
    @MainActor
    public func insertCompositionSeparator(inputStyle: InputStyle, skipUpdate: Bool = false) {
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            // すでに末尾がcompositionSeparatorの場合は何もしない
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.beginCompositionIfNeeded()
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(string, inputStyle: inputStyle)
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        self.beginCompositionIfNeeded()
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func editSegment(count: Int) {
        // 現在選ばれているprefix candidateが存在する場合、まずそれに合わせてカーソルを移動する
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            var afterComposingText = self.composingText
            afterComposingText.prefixComplete(composingCount: candidates[selectionIndex].composingCount)
            let prefixCount = self.composingText.convertTarget.count - afterComposingText.convertTarget.count
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + prefixCount)
        }
        if count > 0 {
            if self.composingText.isAtEndIndex && !self.didExperienceSegmentEdition {
                // 現在のカーソルが右端にある場合、左端の次に移動する
                _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + count)
            } else {
                // それ以外の場合、右に広げる
                _ = self.composingText.moveCursorFromCursorPosition(count: count)
            }
        } else {
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
        }
        if self.composingText.isAtStartIndex {
            // 最初にある場合は一つ右に進める
            _ = self.composingText.moveCursorFromCursorPosition(count: 1)
        }
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    private func beginCompositionIfNeeded() {
        if self.composingText.isEmpty {
            self.pendingCommit = nil
            self.lastCommit = nil
        }
    }

    /// - parameter keepsLiveConversion: ライブ変換を表示している状態からの削除なら`true`。削除の起点で表示していた変換を手前の部分に残す。
    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1, keepsLiveConversion: Bool = false) {
        if self.lastOperation != .delete {
            self.backspaceConversionView = keepsLiveConversion ? self.currentBackspaceConversionView() : nil
        }
        var previousComposingText = self.composingText.prefixToCursorPosition()
        if !self.composingText.isAtEndIndex {
            // 右端に持っていく
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // 一度segmentの編集状態もリセットにする
            self.didExperienceSegmentEdition = false
            previousComposingText = self.composingText.prefixToCursorPosition()
        }
        self.composingText.deleteBackwardFromCursorPosition(count: count)
        if self.composingText.isEmpty {
            // 括弧の中を消し切ったら、待っていた閉じ括弧も入れない
            self.pendingClosingBracket = nil
        }
        self.lastOperation = .delete
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        let currentConvertTarget = self.composingText.convertTarget
        guard count == 1 else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
            if self.backspaceAdjustedPredictionCandidate == nil {
                self.backspaceTypoCorrectionLock = nil
            }
            return
        }
        self.backspaceTypoCorrectionLock = self.lmBasedBackspaceTypoCorrectionLock(previousComposingText: previousComposingText)
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
        } else {
            self.backspaceAdjustedPredictionCandidate = nil
        }
    }

    private func currentBackspaceConversionView() -> BackspaceConversionView? {
        guard self.liveConversionEnabled,
              self.composingText.isAtEndIndex,
              self.composingText.convertTarget.count > 1,
              let firstCandidate = self.rawCandidates?.mainResults.first else {
            return nil
        }
        return BackspaceConversionView(
            reading: self.composingText.convertTarget,
            text: firstCandidate.text,
            words: firstCandidate.data.map { ($0.ruby, $0.word) }
        )
    }

    @MainActor
    public func forgetMemory() {
        if let selectedCandidate {
            self.withConverter { $0.forgetMemory(selectedCandidate) }
            self.appendDebugMessage("\(#function): forget \(selectedCandidate.data.map {$0.word})")
        }
    }

    private var candidates: [Candidate]? {
        guard let rawCandidates = self.rawCandidatesList else {
            return self.isShowingAdditionalCandidates
                ? self.additionalCandidatesForSelectionIndex
                : nil
        }
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    private var rawCandidatesList: [Candidate]? {
        self.unorderedRawCandidatesList.map(self.kanaCandidatesLast)
    }

    /// 入力全体をカタカナ・ひらがなにした候補を、この順で末尾に置く。Spaceでは出ず、↑で末尾に回るとひらがな、カタカナの順に出る
    private func kanaCandidatesLast(_ candidates: [Candidate]) -> [Candidate] {
        let reading = self.composingText.convertTarget
        func isWhole(_ candidate: Candidate, _ text: String) -> Bool {
            candidate.text == text && self.composingText.isWholeComposingText(composingCount: candidate.composingCount)
        }
        let kana = [reading.toKatakana(), reading.toHiragana()].compactMap { text in
            candidates.first { isWhole($0, text) }
        }
        guard !kana.isEmpty else {
            return candidates
        }
        return candidates.filter { candidate in !kana.contains { $0.text == candidate.text } } + kana
    }

    private var unorderedRawCandidatesList: [Candidate]? {
        guard let rawCandidates else {
            return nil
        }
        if !self.didExperienceSegmentEdition {
            if rawCandidates.firstClauseResults.contains(where: { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }) {
                // firstClauseCandidateがmainResultsと同じサイズの場合は、何もしない方が良い
                return rawCandidates.mainResults
            } else {
                // 変換範囲がエディットされていない場合
                let seenAsFirstClauseResults = rawCandidates.firstClauseResults.mapSet(transform: \.text)
                return rawCandidates.firstClauseResults + rawCandidates.mainResults.filter {
                    !seenAsFirstClauseResults.contains($0.text)
                }
            }
        } else {
            return rawCandidates.mainResults
        }
    }

    private var candidateOffsetByAdditionalCandidates: Int {
        self.isShowingAdditionalCandidates ? self.showingAdditionalCandidateCount : 0
    }

    private var additionalCandidatesForSelectionIndex: [Candidate] {
        self.additionalCandidatePresentationsForSelectionIndex.map(\.candidate)
    }

    private var additionalCandidatePresentationsForSelectionIndex: [CandidatePresentation] {
        guard self.isShowingAdditionalCandidates else {
            return []
        }
        guard self.candidateOffsetByAdditionalCandidates > 0 else {
            return []
        }
        return Array(self.additionalCandidates.suffix(self.candidateOffsetByAdditionalCandidates))
    }

    public var convertTarget: String {
        self.composingText.convertTarget
    }

    public var isEmpty: Bool {
        self.composingText.isEmpty
    }

    public func getCleanLeftSideContext() -> String? {
        self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
    }

    public func getCleanLeftSideContext(maxCount: Int) -> String? {
        self.delegate?.getLeftSideContext(maxCount: maxCount).map {
            String(Self.joinContextLines($0).suffix(ContextLength.keptLeftCharacters))
        }
    }

    /// 前の行も左文脈に残し、改行を文の区切りとして扱う。
    /// 文末記号で終わっていない行には「。」を補い、空行は捨てる。
    static func joinContextLines(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0, let last = result.last, !"。．.！？!?」』）)…".contains(last) {
                result.append("。")
            }
            if index == lines.count - 1 {
                // 入力中の行は、カーソル直前の空白を残す
                result += line.drop(while: \.isWhitespace)
            } else {
                result += line.trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    public func getCleanRightSideContext(maxCount: Int) -> String? {
        self.delegate?.getRightSideContext(maxCount: maxCount).map {
            var first = $0.split(separator: "\n", omittingEmptySubsequences: false).first ?? $0[...]
            // 後方の空白を削除する
            while first.last?.isWhitespace ?? false {
                first = first.dropLast()
            }
            return String(first)
        }
    }

    /// Updates the `self.rawCandidates` based on the current input context.
    ///
    /// This function is responsible for handling candidate conversion,
    /// taking into account partial confirmations and optionally fetching rich candidates.
    /// It also allows an override for the left-side context when necessary.
    ///
    /// - Parameters:
    ///   - requestRichCandidates: A Boolean flag indicating whether to fetch rich candidates (default is `false`). Generating rich candidates takes longer time.
    ///   - forcedLeftSideContext: An optional string that overrides the left-side context (default is `nil`).
    ///
    /// - Note:
    ///   This function is executed on the `@MainActor` to ensure UI consistency.
    @MainActor private func updateRawCandidate(
        requestRichCandidates: Bool = false,
        forcedLeftSideContext: String? = nil,
        forcedRightSideContext: String? = nil,
        inferenceLimit: Int? = nil
    ) {
        if self.lastOperation != .delete {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
        }
        self.resetAdditionalCandidates()
        // 不要
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.withConverter { $0.stopComposition() }
            return
        }
        /// 日付・時刻変換を事前に入れておく
        let dynamicShortcuts: [DicdataElement] =
            [
                ("M/d", -18, DateTemplateLiteral.CalendarType.western),
                ("yyyy/MM/dd", -18.1, .western),
                ("yyyy-MM-dd", -18.2, .western),
                ("M月d日（E）", -18.3, .western),
                ("yyyy年M月d日", -18.4, .western),
                ("Gyyyy年M月d日", -18.5, .japanese),
                ("E曜日", -18.6, .western)
            ].flatMap { (format, value: PValue, type) in
                [
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-2", deltaUnit: 60 * 60 * 24).export(), ruby: "オトトイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-1", deltaUnit: 60 * 60 * 24).export(), ruby: "キノウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "キョウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "1", deltaUnit: 60 * 60 * 24).export(), ruby: "アシタ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "2", deltaUnit: 60 * 60 * 24).export(), ruby: "アサッテ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
                ]
            } + [
                // 月
                .init(word: DateTemplateLiteral(format: "MM月", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コンゲツ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                // 年
                .init(word: DateTemplateLiteral(format: "yyyy年", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "Gyyyy年", type: .japanese, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                // 時刻
                .init(word: DateTemplateLiteral(format: "HH:mm", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "HH時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                .init(word: DateTemplateLiteral(format: "aK時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.2)
            ]

        self.withConverter { $0.importDynamicUserDictionary([], shortcuts: dynamicShortcuts) }

        let leftSideContext = forcedLeftSideContext ?? self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        let rightSideContext = forcedRightSideContext ?? self.getCleanRightSideContext(maxCount: ContextLength.conversion)
        let addsSeparator = self.endsWithPendingN
        if self.convertedWithAddedSeparator && !addsSeparator {
            // 区切りを足した入力の変換結果は、次の入力の差分変換の元にできない
            self.withConverter { $0.stopComposition() }
        }
        self.convertedWithAddedSeparator = addsSeparator
        let result = self.withConverter { converter in
            converter.requestCandidates(
                self.composingTextForConversion,
                options: options(
                    leftSideContext: leftSideContext,
                    rightSideContext: rightSideContext,
                    requestRichCandidates: requestRichCandidates,
                    requireJapanesePrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
                    requireEnglishPrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
                    inferenceLimit: inferenceLimit
                )
            )
        }
        self.rawCandidates = result
    }

    /// 入力が止まったときに、推論の回数を増やして変換し直す。新しい変換が今の表示より
    /// モデルの採点で一定以上自然なときだけ表示を差し替え、`true`を返す。
    @MainActor public func reconvertAfterPause() -> Bool {
        guard self.context.useZenzai, self.liveConversionEnabled, self.lastOperation == .insert,
              self.composingText.isAtEndIndex, self.composingText.convertTarget.count > 1,
              let previous = self.rawCandidates, let current = previous.mainResults.first else {
            return false
        }
        let input = self.composingTextForConversion
        // 打鍵の途中で決まった先頭の制約を外し、最初から推論し直す
        self.withConverter { $0.stopComposition() }
        self.updateRawCandidate(inferenceLimit: Self.pauseInferenceLimit)
        guard let reconverted = self.rawCandidates?.mainResults.first, reconverted.text != current.text else {
            return false
        }
        let options = self.options(
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion),
            rightSideContext: self.getCleanRightSideContext(maxCount: ContextLength.conversion),
            requestRichCandidates: false,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled
        )
        let scores = self.withConverter { converter in
            (
                converter.zenzaiLogProbability(of: reconverted, for: input, options: options),
                converter.zenzaiLogProbability(of: current, for: input, options: options)
            )
        }
        guard let new = scores.0, let old = scores.1, new - old >= Self.pauseAcceptanceMargin else {
            self.rawCandidates = previous
            return false
        }
        return true
    }

    /// 入力停止後の再変換で使う推論の回数
    static let pauseInferenceLimit = 10
    /// 再変換の結果を採用するのに必要な、モデルの対数確率の差
    static let pauseAcceptanceMargin: Float = 1.0

    /// 末尾の未確定の`n`は「ん」として変換する（Spaceで変換したときと同じ）。入力そのものは変えない。
    private var composingTextForConversion: ComposingText {
        guard self.endsWithPendingN else {
            return self.composingText
        }
        var text = self.composingText
        text.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: self.lastInputStyle)])
        return text
    }

    /// 直前の変換で、末尾の`n`のために区切りを足したか
    private var convertedWithAddedSeparator = false

    private var endsWithPendingN: Bool {
        self.composingText.isAtEndIndex
            && self.composingText.convertTarget.hasSuffix("n")
            && self.lastInputStyle != .direct
            && self.composingText.input.last?.piece != .compositionSeparator
    }

    @MainActor public func update(requestRichCandidates: Bool) {
        self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        self.shouldShowCandidateWindow = true
    }

    /// - note: 画面更新との整合性を保つため、この関数の実行前に左文脈を取得し、これを引数として与える
    @MainActor public func prefixCandidateCommited(_ candidate: Candidate, leftSideContext: String) {
        self.withConverter { $0.setCompletedData(candidate) }
        self.withConverter { $0.updateLearningData(candidate) }
        if self.endsWithPendingN {
            // 候補は末尾の`n`を「ん」とした入力に対するものなので、入力をそれに揃える
            self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: self.lastInputStyle)])
        }
        let previousConvertTarget = self.composingText.convertTarget
        self.composingText.prefixComplete(composingCount: candidate.composingCount)
        self.recordCommit(
            reading: String(previousConvertTarget.prefix(previousConvertTarget.count - self.composingText.convertTarget.count)),
            text: candidate.text,
            learnedCandidate: candidate
        )
        if self.composingText.isEmpty {
            // Spaceで入れた区切りが残っていると、次に打つ`n`が区切りの後ろで「ん」に確定してしまう
            self.composingText.stopComposition()
            self.finishCommit()
        }

        if !self.composingText.isEmpty {
            // カーソルを右端に移動する
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.didExperienceSegmentEdition = false
            self.shouldShowCandidateWindow = true
            self.selectionIndex = nil
            self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext + candidate.text)
        }
    }

    public enum CandidateWindow: Sendable {
        case hidden
        case composing([Candidate], selectionIndex: Int?)
        case selecting([Candidate], selectionIndex: Int?)
    }

    public func requestSetCandidateWindowState(visible: Bool) {
        self.shouldShowCandidateWindow = visible
    }

    public func requestDebugWindowMode(enabled: Bool) {
        self.shouldShowDebugCandidateWindow = enabled
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        self.isFixingAdditionalCandidateTop = false
        let next = (self.selectionIndex ?? -1) + 1
        // 最後の候補の次は先頭に戻る
        if let count = self.candidates?.count, count > 0, next >= count {
            self.selectionIndex = 0
        } else {
            self.selectionIndex = next
        }
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        let selectionIndex = self.selectionIndex ?? 0

        if self.isFixingAdditionalCandidateTop && self.isShowingAdditionalCandidates {
            if self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
                self.showingAdditionalCandidateCount += 1
            }
            self.selectionIndex = 0
            return
        }

        if selectionIndex == 0, !self.isShowingAdditionalCandidates {
            self.showAdditionalCandidatesIfNeeded()
            let additionalCount = self.candidateOffsetByAdditionalCandidates
            if additionalCount > 0 {
                self.isFixingAdditionalCandidateTop = true
                self.selectionIndex = 0
                return
            }
        }
        if selectionIndex == 0, self.isShowingAdditionalCandidates, self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
            self.isFixingAdditionalCandidateTop = true
            self.showingAdditionalCandidateCount += 1
            self.selectionIndex = 0
            return
        }
        self.selectionIndex = max(0, selectionIndex - 1)
    }

    @MainActor
    public func requestSelectingAdditionalCandidates() {
        self.showAdditionalCandidatesIfNeeded()
        guard self.isShowingAdditionalCandidates else {
            return
        }
        self.showingAdditionalCandidateCount = self.additionalCandidates.count
        self.isFixingAdditionalCandidateTop = true
        self.selectionIndex = 0
    }

    public func requestSelectingRow(_ index: Int) {
        if self.isFixingAdditionalCandidateTop, index != 0 {
            self.isFixingAdditionalCandidateTop = false
        }
        self.selectionIndex = max(0, index)
    }

    public func requestSelectingSuggestionRow(_ row: Int) {
        suggestSelectionIndex = row
    }

    public func stopSuggestionSelection() {
        self.selectionIndex = nil
    }

    /// 選んだ文節より後ろの読みを、文全体の変換と同じ表記で返す。読みが文全体の変換の後半と一致しなければ`nil`
    private func convertedRemainder(reading: String) -> String? {
        guard self.liveConversionEnabled, !reading.isEmpty, let whole = self.rawCandidates?.mainResults.first else {
            return nil
        }
        let target = reading.toKatakana()
        for start in whole.data.indices {
            let rest = whole.data[start...]
            if rest.map(\.ruby).joined() == target {
                return rest.map(\.word).joined()
            }
        }
        return nil
    }

    /// Space・↓で候補の選択を始めたときに呼ぶ。先頭の候補を選んだ表示が直前の表示と同じなら、
    /// 先頭と同じ範囲（文節）で表示の変わる次の候補を選ぶ。そのような候補がなければ先頭のままにする。
    @MainActor
    public func enterCandidateSelection(liveText: String) {
        guard let candidates, candidates.count > 1,
              self.getCurrentMarkedText(inputState: .selecting).map(\.content).joined() == liveText else {
            return
        }
        func remainingReading(_ candidate: Candidate) -> String {
            var rest = self.composingText
            rest.prefixComplete(composingCount: candidate.composingCount)
            return rest.convertTarget
        }
        // ローマ字がかなにならず残った候補（`ありがtぷ`）は、表示に英字がないときは選ばない
        let isLatin: (Character) -> Bool = { ($0.isASCII && $0.isLetter) || ("Ａ" ... "ｚ").contains($0) }
        let allowsLatin = liveText.contains(where: isLatin)
        let firstRemainder = remainingReading(candidates[0])
        // 末尾に置いたひらがな・カタカナの候補は↑で選ぶもので、Spaceでは選ばない
        let kana: Set<String> = [self.composingText.convertTarget.toHiragana(), self.composingText.convertTarget.toKatakana()]
        for index in candidates.indices.dropFirst() where remainingReading(candidates[index]) == firstRemainder
            && (allowsLatin || !candidates[index].text.contains(where: isLatin))
            && !kana.contains(candidates[index].text) {
            self.selectionIndex = index
            if self.getCurrentMarkedText(inputState: .selecting).map(\.content).joined() != liveText {
                return
            }
        }
        self.selectionIndex = 0
    }

    /// ↑キーで一つ前の候補を選ぶ。選び始めや先頭からは末尾（ひらがな、その前がカタカナ）に回る
    @MainActor public func selectPrevCandidateWrapping() {
        guard let candidates, !candidates.isEmpty else {
            return
        }
        let index = self.selectionIndex ?? 0
        self.selectionIndex = index == 0 ? candidates.count - 1 : index - 1
    }

    public func requestResettingSelection() {
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.resetAdditionalCandidates()
    }

    public var selectedCandidate: Candidate? {
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            return candidates[selectionIndex]
        }
        return nil
    }

    public func getCurrentCandidateWindow(inputState: InputState) -> CandidateWindow {
        switch inputState {
        case .none, .previewing, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            return .hidden
        case .composing:
            if !self.liveConversionEnabled, let firstCandidate = self.rawCandidates?.mainResults.first {
                return .composing([firstCandidate], selectionIndex: 0)
            } else {
                return .hidden
            }
        case .selecting:
            if self.shouldShowDebugCandidateWindow {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, debugCandidates.count - 1))
                return .selecting(debugCandidates, selectionIndex: self.selectionIndex)
            } else if self.shouldShowCandidateWindow, let candidates, !candidates.isEmpty {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, candidates.count - 1))
                return .selecting(candidates, selectionIndex: self.selectionIndex)
            } else {
                return .hidden
            }
        }
    }

    public struct MarkedText: Sendable, Equatable, Hashable, Sequence {
        public enum FocusState: Sendable, Equatable, Hashable {
            case focused
            case unfocused
            case none
        }

        public struct Element: Sendable, Equatable, Hashable {
            public var content: String
            public var focus: FocusState
        }
        var text: [Element]

        public var selectionRange: NSRange

        public init(text: [Element], selectionRange: NSRange) {
            self.text = text
            self.selectionRange = selectionRange
        }

        public func makeIterator() -> Array<Element>.Iterator {
            text.makeIterator()
        }

        var isEmpty: Bool {
            self.text.isEmpty
        }
    }

    @MainActor
    public func getModifiedRubyCandidate(inputState: InputState, _ transform: (String) -> String) -> Candidate {
        let (ruby, composingCount): (String, ComposingCount) = switch inputState {
        case .selecting:
            if let selectedRuby = selectedCandidate?.data.map({ $0.ruby }).joined() {
                // `selectedCandidate.data` の全ての `ruby` を連結して返す
                (selectedRuby, .surfaceCount(selectedRuby.count))
            } else {
                // 選択範囲なしの場合はconvertTargetを返す
                (self.convertTarget, .inputCount(self.composingText.input.count))
            }
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            (self.convertTarget, .inputCount(self.composingText.input.count))
        }
        let candidateText = transform(ruby)
        return Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
    }

    @MainActor
    public func getModifiedRomanCandidate(inputState: InputState = .composing, _ transform: (String) -> String) -> Candidate {
        let targetComposingText: ComposingText
        switch inputState {
        case .selecting:
            targetComposingText = self.composingText.prefixToCursorPosition()
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            targetComposingText = self.composingText
        }
        let inputString = targetComposingText.input.map(\.piece).inputString(preferIntention: false)
        let composingCount: ComposingCount = .inputCount(targetComposingText.input.count)
        let candidateText = transform(inputString)
        let candidate = Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: inputString,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
        return candidate
    }

    @MainActor
    private func createAdditionalCandidates() -> [CandidatePresentation] {
        let candidates: [(candidate: Candidate, annotationText: String?)] = [
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0 }, "英数"),
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, "全角英数"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, "半角カナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana() }, "カタカナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toHiragana() }, "ひらがな")
        ]
        return candidates.map {
            .init(
                candidate: $0.candidate,
                displayContext: .init(annotationText: $0.annotationText)
            )
        }
    }

    @MainActor
    private func showAdditionalCandidatesIfNeeded() {
        if self.isShowingAdditionalCandidates {
            return
        }
        guard !self.convertTarget.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        let candidates = self.createAdditionalCandidates()
        guard !candidates.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        self.additionalCandidates = candidates
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
    }

    private func resetAdditionalCandidates() {
        self.isShowingAdditionalCandidates = false
        self.additionalCandidates = []
        self.showingAdditionalCandidateCount = 0
        self.isFixingAdditionalCandidateTop = false
    }

    @MainActor
    public func commitMarkedText(inputState: InputState) -> String {
        let markedText = self.getCurrentMarkedText(inputState: inputState)
        let text = markedText.reduce(into: "") {$0.append(contentsOf: $1.content)}
        let candidate = self.candidates?.first(where: {$0.text == text})
        if let candidate {
            self.withConverter { $0.setCompletedData(candidate) }
            self.withConverter { $0.updateLearningData(candidate) }
        }
        self.recordCommit(reading: self.composingText.convertTarget, text: text, learnedCandidate: candidate)
        self.finishCommit()
        self.stopComposition()
        return text
    }

    private func recordCommit(reading: String, text: String, learnedCandidate: Candidate?) {
        var commit = self.pendingCommit ?? CommittedText(reading: "", text: "", learnedCandidates: [])
        commit.reading += reading
        commit.text += text
        if let learnedCandidate, learnedCandidate.isLearningTarget {
            commit.learnedCandidates.append(learnedCandidate)
        }
        self.pendingCommit = commit
    }

    private func finishCommit() {
        self.lastCommit = self.pendingCommit
        self.pendingCommit = nil
    }

    public func discardLastCommit() {
        self.lastCommit = nil
    }

    /// 直前の確定を取り消し、その読みを入力中に戻す。確定で学習した変換も忘れる。
    /// - note: 呼び出し側は、確定した文字列をクライアント上で読みのmarked textに置き換えてから呼ぶ（左文脈を正しくするため）
    @MainActor
    @discardableResult
    public func undoLastCommit() -> CommittedText? {
        guard let commit = self.lastCommit, self.composingText.isEmpty else {
            return nil
        }
        // 変換器には学習の取り消しがないため、確定で選んだ変換（読みのままでない語）を学習から忘れる
        let converted = commit.learnedCandidates.flatMap(\.data).filter {
            $0.word.toHiragana() != $0.ruby.toHiragana()
        }
        if !converted.isEmpty {
            self.withConverter {
                $0.forgetMemory(Candidate(
                    text: converted.map(\.word).joined(),
                    value: 0,
                    composingCount: .surfaceCount(0),
                    lastMid: 0,
                    data: converted
                ))
            }
        }
        self.insertAtCursorPosition(commit.reading, inputStyle: .direct)
        return commit
    }

    // サジェスト候補を設定するメソッド
    public func setReplaceSuggestions(_ candidates: [Candidate]) {
        self.replaceSuggestions = candidates
        self.suggestSelectionIndex = nil
    }

    // サジェスト候補の選択状態をリセット
    public func resetSuggestionSelection() {
        suggestSelectionIndex = nil
    }

    public func requestTypoCorrectionPredictionCandidates() -> [PredictionCandidate] {
        guard Config.DebugTypoCorrection().value else {
            return []
        }
        guard let backspaceAdjustedPredictionCandidate else {
            return []
        }
        return [backspaceAdjustedPredictionCandidate]
    }

    public static func preferredPredictionCandidates(
        typoCorrectionCandidates: [PredictionCandidate],
        predictionCandidates: [PredictionCandidate]
    ) -> [PredictionCandidate] {
        if !typoCorrectionCandidates.isEmpty {
            return typoCorrectionCandidates
        }
        return predictionCandidates
    }

    public static func shouldPresentTypoCorrectionPredictionCandidate(
        candidateDisplayText: String,
        previousComposingDisplayText: String
    ) -> Bool {
        // 削除前の previousComposingText と同じ表示候補は、訂正候補としては提示しない。
        candidateDisplayText != previousComposingDisplayText
    }

    public func requestPredictionCandidates() -> [PredictionCandidate] {
        guard let candidate = self.firstPredictionCandidate(),
              let prediction = Self.makePredictionCandidate(currentTarget: self.composingText.convertTarget, candidate: candidate) else {
            return []
        }
        return [prediction]
    }

    private func firstPredictionCandidate() -> Candidate? {
        guard Config.DebugPredictiveTyping().value else {
            return nil
        }

        let target = self.composingText.convertTarget
        guard !target.isEmpty else {
            return nil
        }

        guard let rawCandidates else {
            return nil
        }

        return rawCandidates.predictionResults.first {
            Self.makePredictionCandidate(currentTarget: target, candidate: $0) != nil
        }
    }

    static func makePredictionCandidate(
        currentTarget: String,
        candidate: Candidate
    ) -> PredictionCandidate? {
        var matchTarget = currentTarget
        var deleteCount = 0
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            deleteCount = 1
        }
        guard matchTarget.count >= 2 else {
            return nil
        }

        let readingHiragana = candidate.data.map(\.ruby).joined().toHiragana()
        let matchTargetHiragana = matchTarget.toHiragana()
        guard readingHiragana.hasPrefix(matchTargetHiragana) else {
            return nil
        }
        guard matchTargetHiragana.count < readingHiragana.count else {
            return nil
        }

        let appendText = String(readingHiragana.dropFirst(matchTargetHiragana.count))
        guard !appendText.isEmpty else {
            return nil
        }

        return .init(displayText: candidate.text, appendText: appendText, deleteCount: deleteCount)
    }

    @MainActor
    public func acceptPredictionCandidate() {
        if let prediction = self.requestTypoCorrectionPredictionCandidates().first {
            self.acceptTypoCorrectionPredictionCandidate(prediction)
        } else if let candidate = self.firstPredictionCandidate() {
            self.acceptPredictionCandidate(candidate)
        }
    }

    @MainActor
    func acceptPredictionCandidate(_ candidate: Candidate) {
        guard self.withConverter({ $0.acceptPredictionCandidate(candidate, composingText: &self.composingText) }) else {
            return
        }
        self.lastInputStyle = .direct
        self.lastOperation = .insert
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    func acceptTypoCorrectionPredictionCandidate(_ prediction: PredictionCandidate) {
        if prediction.deleteCount > 0 {
            self.deleteBackwardFromCursorPosition(count: prediction.deleteCount)
        }
        if !prediction.appendText.isEmpty {
            self.insertAtCursorPosition(prediction.appendText, inputStyle: .direct)
        }
    }

    @MainActor
    private func requestTypoCorrectionCandidates(composingText targetComposingText: ComposingText, inputStyle: InputStyle) -> [String] {
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            return []
        }
        guard !targetComposingText.isEmpty else {
            return []
        }

        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? ""
        let typoCandidates = self.withConverter { converter in
            converter.experimentalRequestTypoCorrection(
                leftSideContext: leftSideContext,
                composingText: targetComposingText,
                options: options(
                    leftSideContext: leftSideContext,
                    rightSideContext: nil,
                    requestRichCandidates: false,
                    requireJapanesePrediction: .disabled,
                    requireEnglishPrediction: .disabled
                ),
                inputStyle: inputStyle,
                config: .init(
                    languageModel: .ngram(.init(prefix: self.downloadedInputN5LMDir.path + "/lm_", n: 5, d: 0.75)),
                    beamSize: 16,
                    topK: 32,
                    nBest: 3
                )
            )
        }

        var seen: Set<String> = []
        return typoCandidates.compactMap { candidate in
            let text = candidate.convertedText.toHiragana()
            guard !text.isEmpty else {
                return nil
            }
            guard seen.insert(text).inserted else {
                return nil
            }
            return text
        }
    }

    @MainActor
    private func convertedText(reading: String, leftSideContext: String?) -> String? {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)

        let result = self.withConverter { converter in
            converter.requestCandidates(
                composingText,
                options: options(
                    leftSideContext: leftSideContext,
                    rightSideContext: nil,
                    requestRichCandidates: false,
                    requireJapanesePrediction: .disabled,
                    requireEnglishPrediction: .disabled
                )
            )
        }
        return result.mainResults.first?.text
    }

    @MainActor
    private func lmBasedBackspaceTypoCorrectionLock(previousComposingText: ComposingText) -> BackspaceTypoCorrectionLock? {
        let typoCorrectionCandidates = self.requestTypoCorrectionCandidates(
            composingText: previousComposingText,
            inputStyle: self.lastInputStyle
        )
        guard let correctedReading = typoCorrectionCandidates.first else {
            return nil
        }

        let correctedDisplayText = self.convertedText(
            reading: correctedReading,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? correctedReading
        let previousComposingDisplayText = self.convertedText(
            reading: previousComposingText.convertTarget,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? previousComposingText.convertTarget
        guard Self.shouldPresentTypoCorrectionPredictionCandidate(
            candidateDisplayText: correctedDisplayText,
            previousComposingDisplayText: previousComposingDisplayText
        ) else {
            return nil
        }

        return .init(displayText: correctedDisplayText, targetReading: correctedReading)
    }

    static func makeBackspaceTypoCorrectionPredictionCandidate(
        currentConvertTarget: String,
        targetReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        let operation = Self.makeSuffixEditOperation(from: currentConvertTarget, to: targetReading)
            ?? Self.makeSuffixEditOperation(from: currentConvertTarget.toHiragana(), to: targetReading)
        guard let operation else {
            return nil
        }
        return .init(displayText: displayText, appendText: operation.appendText, deleteCount: operation.deleteCount)
    }

    private static func makeSuffixEditOperation(from currentText: String, to targetText: String) -> (appendText: String, deleteCount: Int)? {
        let sharedPrefixLength = zip(currentText, targetText).prefix(while: ==).count
        let deleteCount = currentText.count - sharedPrefixLength
        let appendText = String(targetText.dropFirst(sharedPrefixLength))
        guard deleteCount > 0 || !appendText.isEmpty else {
            return nil
        }
        return (appendText, deleteCount)
    }

    // swiftlint:disable:next cyclomatic_complexity
    /// 入力中の文字列の後ろに表示し、確定するときに一緒に確定する閉じ括弧。
    /// 確定済みの文字列の中にカーソルを置けないアプリで、開き括弧の後に続けて打つときに使う
    public var pendingClosingBracket: String?

    /// 入力中の文字列。閉じ括弧を待っていれば末尾に足し、カーソルをその手前に置く
    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        let markedText = self.markedTextWithoutPendingBracket(inputState: inputState)
        guard let closing = self.pendingClosingBracket, !markedText.text.isEmpty else {
            return markedText
        }
        switch inputState {
        case .composing, .previewing, .selecting:
            let length = markedText.text.reduce(0) { $0 + $1.content.utf16.count }
            let selectionRange = markedText.selectionRange.location == NSNotFound
                ? NSRange(location: length, length: 0)
                : markedText.selectionRange
            return MarkedText(text: markedText.text + [.init(content: closing, focus: .none)], selectionRange: selectionRange)
        case .none, .attachDiacritic, .replaceSuggestion, .unicodeInput:
            return markedText
        }
    }

    private func markedTextWithoutPendingBracket(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            let text = if self.lastOperation == .delete {
                // 削除のあとは、削除の起点で表示していた変換を手前に残し、消している箇所はひらがなで示す
                self.backspaceConversionView?.view(currentReading: self.composingText.convertTarget)
                    ?? self.composingText.convertTarget
            } else if self.liveConversionEnabled,
                      self.composingText.convertTarget.count > 1,
                      let firstCandidate = self.rawCandidates?.mainResults.first {
                // それ以外の場合、ライブ変換が有効なら
                firstCandidate.text
            } else {
                // それ以外
                self.composingText.convertTarget
            }
            return MarkedText(text: [.init(content: text, focus: .none)], selectionRange: .notFound)
        case .previewing:
            if let fullCandidate = self.rawCandidates?.mainResults.first,
               self.composingText.isWholeComposingText(composingCount: fullCandidate.composingCount) {
                return MarkedText(text: [.init(content: fullCandidate.text, focus: .none)], selectionRange: .notFound)
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .selecting:
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                var afterComposingText = self.composingText
                afterComposingText.prefixComplete(composingCount: candidates[self.selectionIndex!].composingCount)
                let remainder = self.convertedRemainder(reading: afterComposingText.convertTarget) ?? afterComposingText.convertTarget
                return MarkedText(
                    text: [
                        .init(content: candidates[self.selectionIndex!].text, focus: .focused),
                        .init(content: remainder, focus: .unfocused)
                    ],
                    selectionRange: NSRange(location: candidates[self.selectionIndex!].text.count, length: 0)
                )
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .replaceSuggestion:
            // サジェスト候補の選択状態を独立して管理
            if let index = suggestSelectionIndex,
               replaceSuggestions.indices.contains(index) {
                return MarkedText(
                    text: [.init(content: replaceSuggestions[index].text, focus: .focused)],
                    selectionRange: NSRange(location: replaceSuggestions[index].text.count, length: 0)
                )
            } else {
                return MarkedText(
                    text: [.init(content: composingText.convertTarget, focus: .none)],
                    selectionRange: .notFound
                )
            }
        case .unicodeInput(let codePoint):
            // Unicode入力モード: "U+" + コードポイントを表示
            let displayText = "U+" + codePoint
            return MarkedText(
                text: [.init(content: displayText, focus: .none)],
                selectionRange: NSRange(location: displayText.count, length: 0)
            )
        }
    }
}

public protocol SegmentManagerDelegate: AnyObject {
    func getLeftSideContext(maxCount: Int) -> String?
    func getRightSideContext(maxCount: Int) -> String?
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
