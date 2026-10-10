import Foundation
import Observation

@Observable
final class RouteViewModel {
    enum State {
        case loading
        case loaded(Route)
        case failed(String)
    }

    let place: Place
    private(set) var state: State = .loading
    /// Live position for the "you are here" dot.
    private(set) var currentLocation: GeoPoint?

    private let location: any LocationServicing
    private let routing: any RoutingServicing
    private let feedback: FeedbackCenter
    private let preferences: RoutingPreferences

    init(place: Place, services: AppServices, feedback: FeedbackCenter, preferences: RoutingPreferences) {
        self.place = place
        self.location = services.location
        self.routing = services.routing
        self.feedback = feedback
        self.preferences = preferences
    }

    var route: Route? {
        if case .loaded(let route) = state { return route }
        return nil
    }

    func load() async {
        let generation = feedback.screenGeneration
        state = .loading
        do {
            let origin = try await location.currentLocation()
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            guard GeorgiaRegion.contains(origin), GeorgiaRegion.contains(place.coordinate) else {
                throw AppError.outsideGeorgia
            }
            let route = try await routing.route(from: origin, to: place, preferences: preferences)
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            state = .loaded(route)
            await feedback.announce(route.spokenOverview, priority: .info)
        } catch {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            let message = ((error as? AppError) ?? .noRoute).spokenMessage
            state = .failed(message)
            await feedback.announce(message, priority: .info)
        }
    }

    /// Follows the user's position while the route screen is open.
    func trackLocation() async {
        for await fix in location.updates() {
            currentLocation = fix.point
        }
    }
}
