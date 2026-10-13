import BPCore
import BPGit
import PDFKit
import SwiftUI

/// Read-only browser for a worktree (PLAN §10): code with line numbers, Markdown, images, PDF.
/// Editing is the agents' and the terminal's job.
struct FilesView: View {
    let worktree: Worktree
    let project: Project
    @State private var files: [String] = []
    @State private var selected: String?
    @State private var search = ""

    private var tree: [FileNode] { FileNode.build(search.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(search) }) }

    var body: some View {
        // Stacked: it lives in the narrow panel beside the terminal.
        VSplitView {
            VStack(spacing: 0) {
                TextField("Buscar fichero", text: $search).textFieldStyle(.roundedBorder).padding(6)
                List(selection: $selected) {
                    OutlineGroup(tree, children: \.children) { node in
                        Label(node.name, systemImage: node.children == nil ? FileNode.icon(node.name) : "folder")
                            .tag(node.path)
                    }
                }
            }
            .frame(minHeight: 120, idealHeight: 240)

            Group {
                if let selected, !files.isEmpty, files.contains(selected) {
                    FileContent(url: URL(fileURLWithPath: worktree.path).appendingPathComponent(selected))
                        .id(selected)
                } else {
                    ContentUnavailableView("Elige un fichero", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        }
        .task(id: worktree.id) {
            let repo = try? await Repository.open(at: URL(fileURLWithPath: worktree.review?.repoPath ?? project.path))
            files = (try? await repo?.listFiles(in: URL(fileURLWithPath: worktree.path))) ?? []
            if selected == nil { selected = files.first { $0.lowercased() == "readme.md" } }
        }
    }
}

struct FileNode: Identifiable, Hashable {
    var name: String
    var path: String
    var children: [FileNode]?
    var id: String { path }

    /// Folders first, then files, alphabetically.
    static func build(_ paths: [String]) -> [FileNode] {
        final class Dir { var dirs: [String: Dir] = [:]; var files: [String] = [] }
        let root = Dir()
        for path in paths {
            var dir = root
            let parts = path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                if dir.dirs[part] == nil { dir.dirs[part] = Dir() }
                dir = dir.dirs[part]!
            }
            if let last = parts.last { dir.files.append(last) }
        }
        func nodes(_ dir: Dir, prefix: String) -> [FileNode] {
            dir.dirs.keys.sorted().map { name in
                FileNode(name: name, path: prefix + name + "/", children: nodes(dir.dirs[name]!, prefix: prefix + name + "/"))
            } + dir.files.sorted().map { FileNode(name: $0, path: prefix + $0, children: nil) }
        }
        return nodes(root, prefix: "")
    }

    static func icon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown": "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": "photo"
        case "pdf": "doc.text.image"
        case "json", "toml", "yml", "yaml", "plist": "curlybraces"
        default: "doc.plaintext"
        }
    }
}

private struct FileContent: View {
    let url: URL
    @State private var renderMarkdown = true

    private var ext: String { url.pathExtension.lowercased() }

    var body: some View {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp":
            if let image = NSImage(contentsOf: url) {
                ScrollView([.horizontal, .vertical]) { Image(nsImage: image).padding() }
            } else { unreadable }
        case "pdf":
            PDFPane(url: url)
        default:
            if let text = Self.text(url) {
                if ext == "md" || ext == "markdown" {
                    VStack(spacing: 0) {
                        Picker("", selection: $renderMarkdown) {
                            Text("Vista").tag(true)
                            Text("Fuente").tag(false)
                        }
                        .pickerStyle(.segmented).fixedSize().padding(6)
                        if renderMarkdown { MarkdownView(text: text) } else { CodeView(text: text) }
                    }
                } else {
                    CodeView(text: text)
                }
            } else { unreadable }
        }
    }

    private var unreadable: some View {
        ContentUnavailableView("No se puede mostrar", systemImage: "eye.slash",
                               description: Text("Fichero binario o demasiado grande (más de 2 MB)."))
    }

    /// UTF-8 text up to 2 MB; nil for binary files.
    static func text(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 2_000_000,
              !data.prefix(8000).contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct CodeView: View {
    let text: String

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let width = CGFloat(String(lines.count).count) * 9 + 12
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: width, alignment: .trailing)
                        Text(String(line).replacingOccurrences(of: "\t", with: "    ")).fixedSize()
                    }
                    .font(.system(.body, design: .monospaced))
                }
            }
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Block-level Markdown: headings, lists, quotes and code blocks; inline styles via AttributedString.
private struct MarkdownView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .heading(level, content):
                        Text(Self.inline(content)).font(level == 1 ? .title : level == 2 ? .title2 : .title3).bold().padding(.top, 6)
                    case let .code(content):
                        Text(content).font(.system(.callout, design: .monospaced)).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    case let .quote(content):
                        Text(Self.inline(content)).foregroundStyle(.secondary).padding(.leading, 10)
                            .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
                    case let .paragraph(content):
                        Text(Self.inline(content))
                    }
                }
            }
            .textSelection(.enabled)
            .padding()
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    enum Block { case heading(Int, String), code(String), quote(String), paragraph(String) }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = [], code: [String]?
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("```") {
                if let current = code { blocks.append(.code(current.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let hashes = line.prefix(while: { $0 == "#" }).count as Int?, hashes > 0, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") {
                flush(); blocks.append(.heading(hashes, String(line.dropFirst(hashes + 1)))); continue
            }
            if line.hasPrefix("> ") { flush(); blocks.append(.quote(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { paragraph.append("• " + line.dropFirst(2)); continue }
            paragraph.append(raw)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

private struct PDFPane: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}
