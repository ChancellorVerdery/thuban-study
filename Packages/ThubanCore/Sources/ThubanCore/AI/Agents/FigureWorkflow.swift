import Foundation

/// The per-question figure workflow shared by the import, the review page and the re-analysis of a stored
/// document: which figures go together, what the agent is told about the question, and how a whole document's
/// figures are run through the agent again.
public enum FigureWorkflow {
    // MARK: Question text

    /// A question as text for the figure agent: stem, then each part's prompt, with the answer choices listed
    /// once and each part's answer named (a sketch is paired with its initial condition from these).
    public static func questionText(_ question: Question) -> String {
        var lines = [question.stem]
        if let ref = question.sourceRef, !ref.isEmpty { lines.insert("[\(ref)]", at: 0) }
        var listedChoices = false
        for part in question.parts {
            var line = "(\(part.id)) \(part.prompt)"
            if let choices = part.choices, !choices.isEmpty, !listedChoices {
                listedChoices = true
                line += "\n  Choices:\n" + choices.enumerated().map { "    \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            }
            if let options = part.choiceFigures, !options.isEmpty {
                // Picture options: which of the question's images each choice is.
                let positions = options.map { id in question.figureIds.firstIndex(of: id).map { "image \($0 + 1)" } ?? "an image" }
                line += "\n  The options are pictures: " + zip(part.choices ?? [], positions).map { "\($0) = \($1)" }.joined(separator: ", ")
            }
            if part.answerKind == .choice, let answer = part.answer.text, !answer.isEmpty {
                if let index = part.choices?.firstIndex(of: answer) { line += "\n  Answer: choice \(index + 1)" }
                else { line += "\n  Answer: \(answer)" }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// "This is image k of n the question refers to, in document order."
    public static func positionNote(of id: FigureID, in questions: [Question]) -> String? {
        for question in questions {
            if let index = question.figureIds.firstIndex(of: id), question.figureIds.count > 1 {
                return "This is image \(index + 1) of \(question.figureIds.count) the question refers to, in document order."
            }
        }
        return nil
    }

    // MARK: Grouping

    /// Figures grouped by the question they sit under, in question order (a figure cited by two questions goes
    /// with the first, and both questions' texts come along), then every uncited figure on its own.
    public static func groups<Item>(_ items: [Item], id: (Item) -> FigureID, questions: [Question]) -> [(questions: [Question], items: [Item])] {
        let byId = Dictionary(items.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<FigureID> = []
        var groups: [(questions: [Question], items: [Item])] = []
        for question in questions {
            let members = question.figureIds.filter { !seen.contains($0) }.compactMap { byId[$0] }
            guard !members.isEmpty else { continue }
            members.forEach { seen.insert(id($0)) }
            let ids = Set(members.map(id))
            let citing = questions.filter { $0.id == question.id || $0.figureIds.contains(where: ids.contains) }
            for slice in stride(from: 0, to: members.count, by: FigureAgent.maxImagesPerCall) {
                groups.append((citing, Array(members[slice..<min(members.count, slice + FigureAgent.maxImagesPerCall)])))
            }
        }
        for item in items where !seen.contains(id(item)) {
            groups.append(([], [item]))
        }
        return groups
    }

    // MARK: Checking stored charts against their pictures

    /// Reconciles every stored chart of a document against its picture (`FigureAgent.check`) without calling the
    /// agent, and writes the result back — for charts analysed before the reader existed, or whose agent call
    /// never came back. Returns one outcome per chart.
    public static func reconcileStored(document: ImportedDocument, store: Store, engine: MathEngine,
                                       only: ((Figure) -> Bool)? = nil) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        let questions = (try? await store.questions(in: document.classId, filter: QuestionFilter(documentIds: [document.id]))) ?? []
        for var figure in try await store.figures(for: document.id) where (only?(figure) ?? true) {
            guard let png = try? Data(contentsOf: AppPaths.figureURL(figure.originalPath)), !png.isEmpty else { continue }
            // Phase lines, whether stored as diagrams or as thin "charts", are read from the picture.
            if figure.chart == nil || FigureAgent.isThin(figure.chart!), figure.kind != .photo, figure.kind != .table,
               let phase = await PhaseLineReader.read(png: png, caption: figure.caption) {
                figure.kind = .chart
                figure.chart = phase.chart
                if figure.status == .keptOriginal || figure.status == .pending || figure.status == .skipped { figure.status = .reviewing }
                figure.acceptIfConfident()
                try await store.update(figure)
                outcomes.append(Outcome(figureId: figure.id, index: figure.pageOrIndex, kind: .chart, isFigure: true,
                                        verification: figure.chart?.verification, caption: figure.caption, definition: nil))
                continue
            }
            // A figure the agent never described (its call failed or skipped it): the picture alone, when it is a plot.
            if figure.chart == nil, figure.status == .pending, figure.kind == .unknown || figure.kind == .chart,
               let fromPixels = await FigureReconciler.chartFromPixels(png: png, engine: engine) {
                figure.kind = .chart
                figure.chart = fromPixels
                figure.status = .reviewing
            }
            // A plot kept as a diagram (a contour map, a family of curves): the picture may name its family.
            if figure.chart == nil, figure.kind == .diagram || figure.kind == .chart || figure.kind == .unknown,
               let recognised = await FamilyRecognizer.recognise(png: png, engine: engine) {
                figure.kind = .chart
                figure.chart = recognised
                figure.status = .reviewing
                figure.acceptIfConfident()
                try await store.update(figure)
                outcomes.append(Outcome(figureId: figure.id, index: figure.pageOrIndex, kind: .chart, isFigure: true,
                                        verification: recognised.verification, caption: figure.caption, definition: nil))
                continue
            }
            guard let chart = figure.chart else { continue }
            let text = questions.filter { $0.figureIds.contains(figure.id) }.map(questionText).joined(separator: "\n\n")
            let checked = await FigureAgent.check(chart, png: png, engine: engine, questionText: text)
            if FigureAgent.isThin(checked) {
                // Not a plot after all (a phase line drawn as two points): keep the original image.
                figure.kind = .diagram
                figure.chart = nil
                figure.status = .keptOriginal
            } else {
                figure.chart = checked
                // A chart the picture now rejects goes back to review, even if it was accepted before.
                if figure.status == .accepted, checked.verification?.passed == false { figure.status = .reviewing }
                // Traced data (no formula) that still misses the picture after every repair: the original image is
                // the faithful one, so it is kept.
                if checked.isTraced, checked.verification?.passed == false, figure.status == .reviewing { figure.status = .keptOriginal }
                figure.acceptIfConfident()
            }
            try await store.update(figure)
            outcomes.append(Outcome(figureId: figure.id, index: figure.pageOrIndex, kind: figure.kind, isFigure: true,
                                    verification: figure.chart?.verification, caption: figure.caption, definition: figure.chart?.definition))
        }
        return outcomes
    }

    // MARK: Re-analysis of a stored document

    public struct Outcome: Sendable {
        public var figureId: FigureID
        public var index: Int
        public var kind: FigureKind
        public var isFigure: Bool
        public var verification: ChartVerification?
        public var caption: String?
        public var definition: String?
    }

    /// Runs every figure of a stored document through the figure workflow again — the questions' text, the
    /// text around each figure (from a fresh parse of the stored file), the earlier captions — and writes the
    /// results back. Images the agent says are not figures are marked skipped, not deleted. Returns one outcome
    /// per figure the agent described.
    public static func reanalyse(
        document: ImportedDocument, store: Store, agent: FigureAgent, engine: MathEngine,
        only: ((Figure) -> Bool)? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [Outcome] {
        let figures = try await store.figures(for: document.id).filter { only?($0) ?? true }
        let questions = try await store.questions(in: document.classId, filter: QuestionFilter(documentIds: [document.id]))
        let content = try? await DocumentParserRegistry.parse(url: AppPaths.documentURL(document.storedPath))
        var pngs: [FigureID: Data] = [:]
        for figure in figures {
            if let data = try? Data(contentsOf: AppPaths.figureURL(figure.originalPath)), !data.isEmpty { pngs[figure.id] = data }
        }
        // A stored image's place in the document, found by its bytes (the stored file is the extracted image).
        var extractionIndex: [FigureID: Int] = [:]
        if let content {
            for figure in figures {
                if let png = pngs[figure.id], let match = content.figures.first(where: { $0.pngData == png }) { extractionIndex[figure.id] = match.index }
            }
        }
        var outcomes: [Outcome] = []
        var done = 0
        let total = figures.count
        for group in groups(figures, id: \.id, questions: questions) {
            let members = group.items.filter { pngs[$0.id] != nil }
            guard !members.isEmpty else { done += group.items.count; continue }
            let around = members.enumerated().compactMap { offset, figure -> String? in
                guard let content, let index = extractionIndex[figure.id] else { return nil }
                let text = content.text(aroundFigure: index)
                guard !text.isEmpty else { return nil }
                return members.count > 1 ? "Around image \(offset + 1):\n\(text.prefix(1500))" : text
            }.joined(separator: "\n\n")
            // A field already stored for the same question, for a sketch the agent cannot describe.
            let questionFigureIds = Set(group.questions.flatMap(\.figureIds))
            let storedField = (try? await store.figures(for: document.id))?
                .first { questionFigureIds.contains($0.id) && ($0.chart?.isSlopeField ?? false) && !($0.chart?.slope ?? "").isEmpty }?.chart
            var context = FigureAgent.FigureContext(
                nearbyText: around,
                questionTexts: group.questions.map(questionText),
                otherQuestionTexts: group.questions.isEmpty ? questions.map(\.stem) : [],
                positionNote: members.count == 1 ? positionNote(of: members[0].id, in: group.questions) : nil
            )
            context.siblingField = storedField
            let started = done
            let analyses = try await agent.describeInSequence(pngs: members.map { pngs[$0.id]! }, context: context, engine: engine) { image in
                progress?(started + image, total)
            }
            done += group.items.count
            for (offset, member) in members.enumerated() {
                guard let analysis = analyses[offset + 1], var figure = try? await store.figure(id: member.id) else { continue }
                figure.kind = analysis.isFigure ? analysis.kind : .unknown
                figure.chart = analysis.isFigure ? analysis.chart : nil
                if let caption = analysis.caption, !caption.isEmpty { figure.caption = caption }
                figure.status = !analysis.isFigure ? .skipped : (analysis.chart != nil ? .reviewing : .keptOriginal)
                figure.acceptIfConfident()
                try await store.update(figure)
                outcomes.append(Outcome(figureId: figure.id, index: figure.pageOrIndex, kind: figure.kind, isFigure: analysis.isFigure,
                                        verification: figure.chart?.verification, caption: figure.caption, definition: figure.chart?.definition))
            }
        }
        return outcomes
    }
}
