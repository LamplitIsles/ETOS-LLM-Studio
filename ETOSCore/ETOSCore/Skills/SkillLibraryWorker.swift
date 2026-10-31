import Foundation

actor SkillLibraryWorker {
    private var revision: UInt64 = 0

    func snapshot() throws -> SkillLibraryState {
        guard let settings = Persistence.withConfigDatabaseRead({ try SkillLibrarySettings.read(in: $0) }) else {
            throw SkillLibraryError.persistenceFailed
        }
        revision &+= 1
        return SkillLibraryState(revision: revision, skills: SkillStore.listSkills(),
                                 enabledNames: settings.0, chatToolsEnabled: settings.1)
    }
}

extension SkillManager {
    public func reloadLibraryInBackground() async throws {
        do {
            let state = try await libraryWorker.snapshot()
            guard !Task.isCancelled else { return }
            applyLibraryState(state)
        } catch {
            if !Task.isCancelled { invalidateLibraryAfterReadFailure() }
            throw error
        }
    }
}
