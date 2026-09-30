import AppKit
import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// The per-look layout table of the one-text-view notes, the documents it
// builds per look, and the pure parts of Fluido's motion. Fictional notes only.

@MainActor
private func build(_ direction: DesignDirection, done: Set<String> = []) -> NotesDocument {
    NotesDocumentBuilder.build(
        NotesDocInput(
            structured: NotesStructured(
                summary: "The kelp survey moved to Thursday.",
                detailedNotes: "- Tide sensor calibration is finished.\n\n```\nbuoy --flash\n```",
                decisions: ["The harbour lights stay amber."],
                actionItems: [ActionItem(owner: "Vexatron Labs", text: "Ship the buoy firmware.")],
                userActionItems: [
                    ActionItem(owner: "Demo User", text: "Send the tide table to Quoll Harbor."),
                    ActionItem(owner: "Demo User", text: "Check the jetty lights before Friday."),
                ]),
            doneKeys: done, searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
            direction: direction))
}

@MainActor
@Suite struct NotesDocLookTableTests {
    @Test("each look carries today's NoteSection and user-box values")
    func table() {
        let aquarela = NotesDocLook.of(.aquarela)
        #expect(aquarela.heading == .chip && aquarela.chrome == .field && aquarela.userBox == .field)
        #expect(aquarela.content == .all(14) && aquarela.userContent == .all(14) && aquarela.titleGap == 9)

        let estudio = NotesDocLook.of(.estudio)
        #expect(estudio.heading == .tick && estudio.chrome == .bare && estudio.userBox == .glass)
        #expect(estudio.content == .all(0) && estudio.userContent == .all(16) && estudio.userRadius == 14)
        #expect(estudio.titleGap == 5 + 2 + 10 + NotesDocLook.titleLine)

        let caderno = NotesDocLook.of(.caderno)
        #expect(caderno.heading == .rule && caderno.chrome == .bare && caderno.userBox == .marginNote)
        #expect(caderno.userContent == NotesDocLook.Insets(leading: 18, trailing: 16, top: 14, bottom: 14))
        #expect(caderno.userRadius == 10 && caderno.titleGap == 10 + NotesDocLook.titleLine)
        #expect(caderno.serifReading && caderno.accentMarkers)

        let fluido = NotesDocLook.of(.fluido)
        #expect(fluido.heading == .tick && fluido.chrome == .card && fluido.userBox == .panel)
        #expect(fluido.content == .all(14) && fluido.userContent == .all(16) && fluido.radius == 14)
        #expect(!fluido.serifReading && !fluido.accentMarkers)
    }

    @Test("only Caderno reads in New York, one point larger")
    func readingFace() {
        let serif = NotesDocLook.of(.caderno).readingFont(14, .medium)
        #expect(serif.pointSize == 15)
        #expect(serif.familyName != NSFont.systemFont(ofSize: 15).familyName)
        #expect(serif.fontName.contains("NewYork"))
        for direction in [DesignDirection.aquarela, .estudio, .fluido] {
            let font = NotesDocLook.of(direction).readingFont(14)
            #expect(font.pointSize == 14)
            #expect(font.familyName == NSFont.systemFont(ofSize: 14).familyName)
        }
    }

    @Test("headings: Estúdio and Fluido in tracked caps, Caderno in small-caps serif")
    func headings() {
        #expect(NotesDocLook.of(.estudio).titleText("Detailed Notes") == "DETAILED NOTES")
        #expect(NotesDocLook.of(.fluido).titleKerning == 1.6)
        #expect(NotesDocLook.of(.caderno).titleText("Detailed Notes") == "Detailed Notes")
        let caderno = NotesDocLook.of(.caderno).titleFont
        #expect(caderno.pointSize == 13.5)
        let features = caderno.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Int]]
        #expect(features?.contains { $0[.typeIdentifier] == kLowerCaseType } == true)
        #expect(NotesDocLook.of(.aquarela).titleFont.pointSize == 12)
    }
}

@MainActor
@Suite struct NotesDocLookDocumentTests {
    private func font(_ doc: NotesDocument, containing needle: String) -> NSFont? {
        let range = (doc.text.string as NSString).range(of: needle)
        return doc.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    @Test("content starts where the look's section chrome puts it")
    func indents() {
        for direction in DesignDirection.allCases {
            let doc = build(direction)
            let look = NotesDocLook.of(direction)
            #expect(doc.look == look)
            let summary = doc.blocks.first { $0.section == .summary && $0.range.length > 0 }
            #expect(summary?.indent == look.content.leading)
            let user = doc.blocks.first { $0.section == .userActionItem }
            #expect(user?.indent == look.userContent.leading)
            let style = doc.paragraphs[summary!.paragraph].style
            #expect(style.tailIndent == -look.content.trailing)
        }
    }

    @Test("Caderno sets the notes in New York; the others in the system face")
    func faces() {
        #expect(font(build(.caderno), containing: "kelp survey")?.pointSize == 15)
        #expect(font(build(.caderno), containing: "harbour lights")?.pointSize == 15)
        #expect(font(build(.estudio), containing: "kelp survey")?.pointSize == 14)
        // Code keeps its monospaced face in every look.
        #expect(font(build(.caderno), containing: "buoy --flash")?.pointSize == 12.5)
    }

    @Test("section titles read as the look shows them")
    func titles() {
        let estudio = build(.estudio)
        let title = estudio.paragraphs[estudio.sections[0].title].range
        #expect((estudio.text.string as NSString).substring(with: title).hasPrefix("SUMMARY"))
        #expect(estudio.paragraphs[estudio.sections[0].title].isTitle)
    }
}

@MainActor
@Suite struct NotesDocMotionTests {
    @Test("a tick is the same items with a larger done set; nothing else is")
    func completion() {
        let item = "Send the tide table to Quoll Harbor."
        let before = build(.fluido)
        let after = build(.fluido, done: [ActionItemKey.key(for: item)])
        #expect(NotesDocMotion.completed(from: before, to: after) == [item])
        #expect(NotesDocMotion.completed(from: after, to: before).isEmpty)
        #expect(NotesDocMotion.completed(from: before, to: build(.fluido)).isEmpty)
        // Other notes (a regeneration, another meeting) are never a tick.
        let other = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "", detailedNotes: "", decisions: [], actionItems: [],
                    userActionItems: [ActionItem(owner: "Demo User", text: item)]),
                doneKeys: [ActionItemKey.key(for: item)], searchTerms: [], portuguese: false,
                userActionTitle: "Demo User — Action Items", direction: .fluido))
        #expect(NotesDocMotion.completed(from: before, to: other).isEmpty)
    }

    @Test("the shine sweeps from the top-leading corner, brightest mid-way, gone at the end")
    func shine() {
        let content = CGRect(x: 0, y: 0, width: 600, height: 4000)
        let start = NotesDocMotion.shine(over: content, fraction: 0)
        #expect(start.alphas.allSatisfy { $0 == 0 })
        let middle = NotesDocMotion.shine(over: content, fraction: 0.5)
        #expect(middle.alphas.count == 16)
        #expect((middle.alphas.max() ?? 0) > 0.3 && (middle.alphas.max() ?? 1) < 0.8 * sin(0.5) + 0.001)
        // The band travels down-right along the content's diagonal.
        let early = NotesDocMotion.shine(over: content, fraction: 0.2)
        #expect(middle.start.y > early.start.y && middle.start.x > early.start.x)
        #expect(abs(NotesDocMotion.easeInOut(0)) < 0.0001 && abs(NotesDocMotion.easeInOut(1) - 1) < 0.0001)
        #expect(abs(NotesDocMotion.easeInOut(0.5) - 0.5) < 0.001)
    }
}
