import SwiftUI
import ThubanCore

/// The Flashcards section: this class's deck. Review runs the due cards on the 1-3-7-14-21-day ladder (or practises
/// them all without scheduling); the card bank lists every card with when it is due. Cards are Markdown with
/// rendered math, written in fields that render math as it is typed.
struct FlashcardsView: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    private var state: FlashcardsState { session.flashcards }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0.z) {
            header
                .padding(.horizontal, 24.z)
                .padding(.top, 22.z)
                .padding(.bottom, 12.z)
            if let error = state.error {
                Text(error)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.negTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24.z)
                    .padding(.bottom, 8.z)
            }
            Rectangle().fill(theme.lineColor).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.classId) { await session.loadFlashcards() }
        .sheet(item: $state.editing) { draft in
            FlashcardEditor(session: session, draft: draft)
                .environment(\.thubanTheme, theme)
        }
        .sheet(isPresented: $state.isGenerating) {
            FlashcardGenerateSheet(session: session)
                .environment(\.thubanTheme, theme)
        }
        .confirmationDialog(
            "Delete this card?",
            isPresented: Binding(get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } }),
            presenting: state.pendingDelete
        ) { card in
            Button("Delete", role: .destructive) { Task { await session.deleteFlashcard(card.id) } }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text("The card and its review history are removed. This cannot be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var state = state
        return HStack(alignment: .center, spacing: 16.z) {
            VStack(alignment: .leading, spacing: 4.z) {
                Text("Flashcards")
                    .font(ThubanFont.display(28))
                    .foregroundStyle(theme.inkColor)
                Text(subtitle)
                    .font(ThubanFont.body(15))
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            if !state.cards.isEmpty {
                SegmentedPicker(selection: $state.mode, options: [
                    SegmentOption(FlashcardsState.Mode.review, "Review"),
                    SegmentOption(FlashcardsState.Mode.bank, "Card bank"),
                ])
                .fixedSize()
            }
            Button("Generate…") { state.isGenerating = true }
                .buttonStyle(.thubanSecondary)
                .help("Make cards from notes, a document or anything you paste")
            Button {
                state.editing = FlashcardDraft()
            } label: {
                HStack(spacing: 6.z) {
                    Glyph(.plus, size: 14)
                    Text("Add card")
                }
            }
            .buttonStyle(.thubanPrimary)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Add a card (⌘⇧N)")
        }
    }

    private var subtitle: String {
        guard state.isLoaded else { return " " }
        if state.cards.isEmpty { return "\(session.studyClass?.name ?? "This class") · no cards yet" }
        let due = state.dueCards.count
        var line = pluralized(state.cards.count, "card", "cards") + " · \(due) due today"
        if due == 0, let next = state.nextDue { line += " · next on \(FlashcardsState.shortDay(next))" }
        return line
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if state.isLoaded, state.cards.isEmpty {
            EmptyState(icon: .flashcards, title: "No flashcards yet",
                       message: "Write cards by hand (type $ in a field for rendered math) or generate them from your notes. Due cards come back on a 1, 3, 7, 14 and 21-day schedule.") {
                HStack(spacing: 10.z) {
                    Button("Generate from notes…") { state.isGenerating = true }
                        .buttonStyle(.thubanSecondary)
                    Button("Add a card") { state.editing = FlashcardDraft() }
                        .buttonStyle(.thubanPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        } else if state.mode == .bank {
            FlashcardDeckWebView(controller: state.bankPage)
                .accessibilityLabel("Card bank")
        } else if let review = state.review {
            if review.isFinished {
                finished(review)
            } else {
                reviewing(review)
            }
        } else {
            overview
        }
    }

    private var overview: some View {
        let due = state.dueCards.count
        return VStack(spacing: 18.z) {
            VStack(spacing: 6.z) {
                Text(due == 0 ? "Nothing due today" : "\(pluralized(due, "card", "cards")) due")
                    .font(ThubanFont.display(24))
                    .foregroundStyle(theme.inkColor)
                Text(due == 0
                     ? (state.nextDue.map { "The next cards come back on \(FlashcardsState.shortDay($0)). Practice all runs every card without changing the schedule." } ?? "")
                     : "Each card you get comes back after a longer wait: 1, 3, 7, 14, then 21 days. A miss brings it back tomorrow, and again later in this session.")
                    .font(ThubanFont.body(14))
                    .foregroundStyle(theme.inkDimColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460.z)
            }
            HStack(spacing: 10.z) {
                Button("Practice all") { session.startFlashcardReview(practice: true) }
                    .buttonStyle(.thubanSecondary)
                    .help("Run every card; nothing is rescheduled")
                Button(due == 0 ? "Review" : "Review \(due) due") { session.startFlashcardReview(practice: false) }
                    .buttonStyle(.thubanPrimary)
                    .disabled(due == 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32.z)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reviewing(_ review: FlashcardsState.Review) -> some View {
        VStack(spacing: 14.z) {
            HStack(spacing: 10.z) {
                Text("\(review.index + 1) of \(review.ids.count)")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
                if review.practice { Chip("Practice · not scheduled", kind: .signal) }
                if !review.missed.isEmpty { Chip("\(review.missed.count) missed", kind: .neutral) }
                Spacer()
                Button("End session") { session.endFlashcardReview() }
                    .buttonStyle(.thubanSecondary)
                    .help("Stop here; cards already graded keep their new dates (Esc)")
            }
            FlashcardDeckWebView(controller: state.reviewPage)
                .frame(maxHeight: 420.z)
                .accessibilityLabel(review.flipped ? "Card answer" : "Card question")
            HStack(spacing: 12.z) {
                if review.flipped {
                    Button { Task { await session.gradeFlashcard(got: false) } } label: {
                        HStack(spacing: 8.z) { Text("Missed"); KeyHint("1") }
                    }
                    .buttonStyle(.thubanSecondary)
                    Button { Task { await session.gradeFlashcard(got: true) } } label: {
                        HStack(spacing: 8.z) { Text("Got it"); KeyHint("2") }
                    }
                    .buttonStyle(.thubanPrimary)
                } else {
                    Button { session.flipFlashcard() } label: {
                        HStack(spacing: 8.z) { Text("Show answer"); KeyHint("Space") }
                    }
                    .buttonStyle(.thubanPrimary)
                }
            }
        }
        .padding(.horizontal, 32.z)
        .padding(.vertical, 20.z)
        .frame(maxWidth: 820.z, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    private func finished(_ review: FlashcardsState.Review) -> some View {
        // A missed card runs again until it is got, so the run lists it more than once.
        let reviewed = Set(review.ids).count
        return VStack(spacing: 14.z) {
            Text("Session done")
                .font(ThubanFont.display(24))
                .foregroundStyle(theme.inkColor)
            Text("\(pluralized(reviewed, "card", "cards")) · \(review.missed.count) missed at least once"
                 + (review.practice ? " · practice run, nothing rescheduled" : ""))
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
            Button("Done") { session.endFlashcardReview() }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32.z)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A key cap beside a button label ("1", "Space").
private struct KeyHint: View {
    @Environment(\.thubanTheme) private var theme
    var key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(ThubanFont.mono(11))
            .padding(.horizontal, 5.z)
            .padding(.vertical, 1.z)
            .overlay(RoundedRectangle(cornerRadius: 4.z).strokeBorder(theme.lineColor, lineWidth: 1))
            .opacity(0.8)
    }
}
