import AppKit
import BPCore
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Updates Bullpen from its GitHub releases: finds a newer version, downloads the universal zip,
/// checks it against the release's SHA256SUMS.txt, swaps the app bundle once Bullpen has quit
/// and opens the new one. Sessions keep running in bpd meanwhile.
@MainActor
@Observable
final class Updater {
    static let repository = "byLuisMoya/Bullpen"
    /// BULLPEN_PRETEND_VERSION=0.0.1 makes this build look old, to try the update flow while developing.
    static var currentVersion: String { ProcessInfo.processInfo.environment["BULLPEN_PRETEND_VERSION"] ?? Bullpen.version }

    struct Release: Equatable {
        var version: ReleaseVersion
        var zip: URL
        var sums: URL
        /// Ed25519 signature of the zip (`<zip>.sig`); releases without one are not installed.
        var signature: URL?
        var page: URL?
        var notes: String
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var lastChecked: Date?

    var available: Release? {
        if case let .available(release) = state { return release }
        return nil
    }

    /// Checks at launch, every hour, and when Bullpen comes back to the front (at most every
    /// half hour), so a new version shows up during the day without looking for it.
    func start() async {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self, Date().timeIntervalSince(self.lastChecked ?? .distantPast) > 1800 else { continue }
                await self.check(quietly: true)
            }
        }
        while !Task.isCancelled {
            await check(quietly: true)
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    func check(quietly: Bool = false) async {
        if case .installing = state { return }
        if !quietly { state = .checking }
        do {
            let latest = try await Self.latestRelease()
            lastChecked = Date()
            if let latest, let current = ReleaseVersion(Self.currentVersion), latest.version > current {
                state = .available(latest)
                announce(latest)
            } else {
                state = quietly && state != .checking ? .idle : .upToDate
            }
        } catch {
            if !quietly { state = .failed("No se pudo consultar GitHub: \(error.localizedDescription)") }
        }
    }

    /// One notification per new version, the first time it is seen.
    private func announce(_ release: Release) {
        let key = "updater.announced"
        guard ProcessInfo.processInfo.environment["BULLPEN_PRETEND_VERSION"] == nil,
              UserDefaults.standard.string(forKey: key) != release.version.description else { return }
        UserDefaults.standard.set(release.version.description, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = "Bullpen \(release.version) disponible"
        content.body = "Pulsa «Actualizar» en la barra de herramientas para instalarla."
        let request = UNNotificationRequest(identifier: "bullpen-update", content: content, trigger: nil)
        Task {
            guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func dismissResult() {
        if case .available = state { return }
        if case .installing = state { return }
        state = .idle
    }

    func install(_ release: Release) async {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            state = .failed("Solo se puede actualizar la app empaquetada (Bullpen.app).")
            return
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            state = .failed("No hay permiso para escribir en \(target.deletingLastPathComponent().path). Descarga la versión desde GitHub y sustitúyela a mano.")
            return
        }
        do {
            state = .installing("Descargando \(release.version)…")
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("bullpen-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent(release.zip.lastPathComponent)
            let (downloaded, _) = try await URLSession.shared.download(from: release.zip)
            try FileManager.default.moveItem(at: downloaded, to: zip)
            let (sumsData, _) = try await URLSession.shared.data(from: release.sums)

            state = .installing("Comprobando la descarga…")
            let expected = ReleaseVersion.sha256(for: zip.lastPathComponent, in: String(decoding: sumsData, as: UTF8.self))
            let actual = try await Task.detached { SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined() }.value
            guard let expected, expected == actual else {
                throw UpdateError("La descarga no coincide con SHA256SUMS.txt; no se instala.")
            }
            // The checksum only proves the download is complete; the signature proves it is ours.
            guard let signatureURL = release.signature else {
                throw UpdateError("La versión \(release.version) no está firmada; no se instala.")
            }
            let (signature, _) = try await URLSession.shared.data(from: signatureURL)
            let zipData = try Data(contentsOf: zip)
            guard ReleaseSignature.isValid(zipData, signature: String(decoding: signature, as: UTF8.self)) else {
                throw UpdateError("La firma de la versión \(release.version) no es válida; no se instala.")
            }

            state = .installing("Preparando la nueva versión…")
            let extracted = work.appendingPathComponent("app")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
            let newApp = extracted.appendingPathComponent("Bullpen.app")
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleShortVersionString"] as? String == release.version.description else {
                throw UpdateError("El paquete descargado no es la versión \(release.version).")
            }

            state = .installing("Reiniciando…")
            try Self.swapAfterQuit(newApp: newApp, target: target, work: work)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: GitHub

    private static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bullpen/\(Bullpen.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UpdateError("respuesta inesperada")
        }
        return releases.compactMap { release -> Release? in
            guard release["draft"] as? Bool != true,
                  let tag = release["tag_name"] as? String, let version = ReleaseVersion(tag),
                  let assets = release["assets"] as? [[String: Any]] else { return nil }
            func asset(_ match: (String) -> Bool) -> URL? {
                assets.first { ($0["name"] as? String).map(match) ?? false }
                    .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
            }
            guard let zip = asset({ $0.hasSuffix("-universal.zip") }), let sums = asset({ $0 == "SHA256SUMS.txt" }) else { return nil }
            return Release(version: version, zip: zip, sums: sums, signature: asset({ $0 == zip.lastPathComponent + ".sig" }),
                           page: (release["html_url"] as? String).flatMap(URL.init(string:)),
                           notes: release["body"] as? String ?? "")
        }
        .max { $0.version < $1.version }
    }

    // MARK: Installing

    /// A small script outlives Bullpen: it waits for this process to end, moves the new bundle
    /// into place (keeping the old one until the move worked) and opens it.
    private static func swapAfterQuit(newApp: URL, target: URL, work: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.previous"
        if mv "$3" "$3.previous" && mv "$2" "$3"; then
          rm -rf "$3.previous"
        else
          [ -d "$3" ] || mv "$3.previous" "$3"
        fi
        xattr -dr com.apple.quarantine "$3" 2>/dev/null
        open "$3"
        rm -rf "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "bullpen-update", String(ProcessInfo.processInfo.processIdentifier),
                             newApp.path, target.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError("\(tool) falló (\(process.terminationStatus))") }
        }.value
    }
}

struct UpdateError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Toolbar button: checks for a new version, and offers to install it when there is one.
struct UpdateButton: View {
    @Environment(Updater.self) private var updater
    @State private var showing = false

    var body: some View {
        Group {
            if let release = updater.available {
                // Hard to miss: a purple pill with the word, not just a tinted icon.
                Button {
                    showing = true
                } label: {
                    // Drawn by hand: the toolbar greys out system "prominent" buttons when the
                    // window isn't active, and this must stay purple.
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Actualizar")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.49, green: 0.30, blue: 0.86)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Hay una versión nueva: \(release.version)")
            } else {
                Button {
                    showing = true
                    if !isBusy { Task { await updater.check() } }
                } label: {
                    Label("Actualizar", systemImage: "arrow.down.circle")
                }
                .help("Buscar actualizaciones")
            }
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
        .onChange(of: showing) { _, shown in if !shown { updater.dismissResult() } }
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .installing: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle, .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Buscando actualizaciones…") }
        case .upToDate:
            Label("Tienes la última versión (\(Bullpen.version)).", systemImage: "checkmark.circle")
        case let .available(release):
            Text("Bullpen \(release.version) disponible").font(.headline)
            Text("Tienes la \(Bullpen.version). Se descarga, se comprueba y Bullpen se reinicia; las terminales y los agentes siguen en marcha.")
                .font(.callout).foregroundStyle(.secondary)
            if !release.notes.isEmpty {
                ScrollView {
                    Text(LocalizedStringKey(release.notes)).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            HStack {
                if let page = release.page { Link("Ver en GitHub", destination: page).font(.callout) }
                Spacer()
                Button("Actualizar y reiniciar") { Task { await updater.install(release) } }
                    .buttonStyle(.borderedProminent)
            }
        case let .installing(step):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step) }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("Reintentar") { Task { await updater.check() } }
        }
    }
}
