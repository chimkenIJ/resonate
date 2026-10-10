import CoreLocation
import Foundation

/// GPS through Core Location. Turn-by-turn keeps running with the screen locked
/// (background location mode + CLBackgroundActivitySession).
final class LiveLocationService: NSObject, LocationServicing, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Bool, Never>] = []
    private var locationWaiters: [CheckedContinuation<GeoPoint, Error>] = []
    private var headingStreams: [UUID: AsyncStream<Double>.Continuation] = [:]

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
    }

    func requestAuthorization() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                authorizationWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    func currentLocation() async throws -> GeoPoint {
        guard await requestAuthorization() else { throw AppError.permissionDenied(.location) }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -15, recent.horizontalAccuracy <= 100 {
            return GeoPoint(recent.coordinate)
        }
        return try await withCheckedThrowingContinuation { continuation in
            locationWaiters.append(continuation)
            manager.requestLocation()
        }
    }

    func updates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            let task = Task {
                guard await self.requestAuthorization() else {
                    continuation.finish()
                    return
                }
                // Keeps updates coming while the phone is locked or in a pocket.
                let background = CLBackgroundActivitySession()
                defer { background.invalidate() }
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                        if Task.isCancelled { break }
                        guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
                        continuation.yield(LocationFix(
                            point: GeoPoint(location.coordinate),
                            accuracy: location.horizontalAccuracy,
                            timestamp: location.timestamp,
                            course: location.course >= 0 && location.courseAccuracy >= 0 && location.courseAccuracy <= 45 ? location.course : nil,
                            speed: location.speed >= 0 ? location.speed : nil
                        ))
                    }
                } catch {
                    continuation.finish()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func headings() -> AsyncStream<Double> {
        AsyncStream { continuation in
            let id = UUID()
            headingStreams[id] = continuation
            manager.startUpdatingHeading()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.removeHeadingStream(id) }
            }
        }
    }

    private func removeHeadingStream(_ id: UUID) {
        headingStreams[id] = nil
        if headingStreams.isEmpty { manager.stopUpdatingHeading() }
    }

    // MARK: CLLocationManagerDelegate (called on the main thread, where the manager was created)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        let granted = status == .authorizedWhenInUse || status == .authorizedAlways
        let waiters = authorizationWaiters
        authorizationWaiters = []
        waiters.forEach { $0.resume(returning: granted) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(returning: GeoPoint(location.coordinate)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(throwing: AppError.server(message: "I couldn't find where you are. Try again outside or near a window.")) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingStreams.values.forEach { $0.yield(heading) }
    }
}
