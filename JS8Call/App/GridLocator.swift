import CoreLocation
import Foundation
import Observation

/// Turns the device location into a Maidenhead grid, either once on request
/// or continuously while automatic updates are on.
@MainActor
@Observable
final class GridLocator: NSObject, CLLocationManagerDelegate {
    private(set) var isLocating = false
    private(set) var isTracking = false
    private(set) var lastError: String?

    /// Called with each new 6-character grid.
    @ObservationIgnored var onGrid: ((String) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()

    #if os(macOS)
    private static let deniedMessage = "Location access is off. Turn it on for JS8 Firefly in System Settings › Privacy & Security › Location Services."
    #else
    private static let deniedMessage = "Location access is off. Turn it on in Settings › Apps › JS8 Firefly › Location."
    #endif

    override init() {
        super.init()
        manager.delegate = self
        // A 6-character subsquare is about 5 x 2.5 arc-minutes (several km), so coarse fixes are plenty.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 500
    }

    /// One fix, then stop (unless tracking is on).
    func locateOnce() {
        lastError = nil
        isLocating = true
        if authorize() { manager.requestLocation() }
    }

    func startTracking() {
        guard !isTracking else { return }
        lastError = nil
        isTracking = true
        if authorize() { manager.startUpdatingLocation() }
    }

    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        manager.stopUpdatingLocation()
    }

    /// Requests permission if needed; false when a fix can't be requested yet.
    private func authorize() -> Bool {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            return false
        case .denied, .restricted:
            fail(Self.deniedMessage)
            return false
        default:
            return true
        }
    }

    private func fail(_ message: String) {
        lastError = message
        isLocating = false
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined, isLocating || isTracking else { return }
            if authorize() {
                if isTracking { manager.startUpdatingLocation() } else { manager.requestLocation() }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
            isLocating = false
            lastError = nil
            onGrid?(GridMath.grid(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            // Transient: Core Location keeps trying.
            if (error as? CLError)?.code == .locationUnknown, isTracking { return }
            if (error as? CLError)?.code == .denied {
                fail(Self.deniedMessage)
            } else {
                fail("Couldn't get a location fix. Try again, or enter your grid manually.")
            }
        }
    }
}
