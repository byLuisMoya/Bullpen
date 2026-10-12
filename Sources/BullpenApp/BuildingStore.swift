import BPCore
import BPPersistence
import Foundation
import Observation
import os

/// Main-actor view model: the building (offices stacked by project) read from the database.
@MainActor
@Observable
final class BuildingStore {
    private(set) var offices: [Office] = []
    private(set) var loadError: String?
    private var database: AppDatabase?
    private let log = Logger.bullpen("store")

    func start() async {
        do {
            let database = try AppDatabase.onDisk()
            self.database = database
            for try await offices in database.observeOffices() {
                self.offices = offices
            }
        } catch {
            log.error("Database failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    func addProject(at url: URL) {
        guard let database else { return }
        let project = Project(
            name: url.lastPathComponent,
            path: url.path,
            sortIndex: offices.count
        )
        do {
            try database.save(project)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
