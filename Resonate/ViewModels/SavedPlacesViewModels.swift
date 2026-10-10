import Foundation
import OSLog
import Observation

@Observable
final class SavedPlacesViewModel {
    private(set) var folders: [PlaceFolder] = []
    private(set) var errorMessage: String?

    private let service: any SavedPlacesServicing

    init(service: any SavedPlacesServicing) {
        self.service = service
    }

    var subtitle: String { folders.count == 1 ? "1 folder" : "\(folders.count) folders" }

    func load() async {
        do {
            folders = try await service.folders()
            errorMessage = nil
        } catch {
            Log.data.error("Couldn't load folders: \(String(describing: error), privacy: .public)")
            errorMessage = "Couldn't load your saved places."
        }
    }
}

@Observable
final class FolderViewModel {
    let folder: PlaceFolder
    private(set) var places: [SavedPlace] = []
    private(set) var isLoaded = false

    private let service: any SavedPlacesServicing
    private let feedback: FeedbackCenter

    init(folder: PlaceFolder, service: any SavedPlacesServicing, feedback: FeedbackCenter) {
        self.folder = folder
        self.service = service
        self.feedback = feedback
    }

    var countText: String {
        let count = isLoaded ? places.count : folder.placeCount
        return count == 1 ? "1 route" : "\(count) routes"
    }

    func load() async {
        places = (try? await service.places(in: folder.id)) ?? []
        isLoaded = true
    }

    func delete(_ saved: SavedPlace) async {
        do {
            try await service.deletePlace(saved.id)
            places.removeAll { $0.id == saved.id }
            await feedback.announce("Removed \(saved.place.name).", priority: .info)
        } catch {
            await feedback.announce("Couldn't remove \(saved.place.name).", priority: .info)
        }
    }
}

/// "Save" on a search result: pick a folder (or make one) for the place.
@Observable
final class SaveToFolderViewModel {
    let place: Place
    private(set) var folders: [PlaceFolder] = []

    let service: any SavedPlacesServicing
    private let feedback: FeedbackCenter

    init(place: Place, service: any SavedPlacesServicing, feedback: FeedbackCenter) {
        self.place = place
        self.service = service
        self.feedback = feedback
    }

    func load() async {
        folders = (try? await service.folders()) ?? []
    }

    /// Returns true when saved, so the sheet can close.
    func save(to folder: PlaceFolder) async -> Bool {
        do {
            _ = try await service.save(place, routeSummary: nil, to: folder.id)
            await feedback.announce("Saved \(place.name) to \(folder.name).", priority: .info)
            return true
        } catch {
            await feedback.announce("Couldn't save \(place.name). Try again.", priority: .info)
            return false
        }
    }
}

@Observable
final class AddFolderViewModel {
    var name = ""
    var accent: Accent = .slate
    var icon: FolderIcon = .star
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let service: any SavedPlacesServicing

    init(service: any SavedPlacesServicing) {
        self.service = service
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canCreate: Bool { !trimmedName.isEmpty && !isSaving }

    func create() async -> PlaceFolder? {
        guard canCreate else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            return try await service.createFolder(name: trimmedName, accent: accent, icon: icon)
        } catch {
            errorMessage = "Couldn't make the folder. Try again."
            return nil
        }
    }
}
