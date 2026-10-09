import Foundation

@main
struct MarkdownListTest {
    static func main() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/list-reply.md")
        let raw = try String(contentsOf: fixture, encoding: .utf8)
        let spec = try HiddenDraft.parse(raw)
        precondition(spec.format != "plain", "format")
        precondition(spec.subject == "What has happened", spec.subject)
        let html = HiddenDraft.mdToHTML(spec.body)
        let formatting = spec.format != "plain" && html.contains("<")
        precondition(formatting, "formatting")
        precondition(
            html.contains("<ul><li>Item one.</li><li>Item two.</li></ul>"),
            html
        )
        precondition(
            html.contains("<ol><li>Question one.</li><li>Question two.</li><li>Question three.</li></ol>"),
            html
        )
        precondition(html.contains("</div><ul>"), html)
        precondition(html.contains("</div><ol>"), html)
        precondition(!html.contains("<div><br></div><ul>"), html)
        precondition(!html.contains("<div><br></div><ol>"), html)
        precondition(!html.contains("<p>"), html)
        precondition(!html.contains("<br><ul>") && !html.contains("<br><ol>"), html)

        let looseOL = HiddenDraft.mdToHTML("Intro:\n\n1. One.\n\n2. Two.\n")
        precondition(looseOL.contains("<ol><li>One.</li><li>Two.</li></ol>"), looseOL)
        precondition(looseOL.contains("</div><ol>"), looseOL)
        precondition(!looseOL.contains("<div><br></div><ol>"), looseOL)

        let looseUL = HiddenDraft.mdToHTML("Intro:\n\n- A.\n\n- B.\n")
        precondition(looseUL.contains("<ul><li>A.</li><li>B.</li></ul>"), looseUL)
        precondition(!looseUL.contains("<div><br></div><ul>"), looseUL)

        print("ok")
        print(html)
        print("formatting \(formatting)")
    }
}
