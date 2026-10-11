import AppKit
import CoreLocation
import SwiftUI
import WeatherglassCore

/// Asks macOS for the current location once. Only the rounded coordinates are ever sent anywhere.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum Failure: Error {
        case denied
        case unavailable
    }

    private let manager = CLLocationManager()
    private var completion: ((Result<Coordinates, Failure>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func locate(_ done: @escaping (Result<Coordinates, Failure>) -> Void) {
        completion = done
        switch manager.authorizationStatus {
        case .denied, .restricted:
            finish(.failure(.denied))
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.completion != nil else { return }
            switch status {
            case .denied, .restricted: self.finish(.failure(.denied))
            case .notDetermined: break
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let c = Coordinates(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
        Task { @MainActor in self.finish(.success(c)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in self.finish(.failure(denied ? .denied : .unavailable)) }
    }

    private func finish(_ r: Result<Coordinates, Failure>) {
        let c = completion
        completion = nil
        c?(r)
    }
}

/// Searches Open-Meteo's place names as you type.
@MainActor
final class PlaceSearch: ObservableObject {
    @Published var query = "" {
        didSet { schedule() }
    }
    @Published private(set) var results: [Place] = []
    @Published private(set) var message = ""

    private var pending: DispatchWorkItem?
    private var task: URLSessionDataTask?

    private func schedule() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.search() }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func search() {
        task?.cancel()
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        guard let url = OpenMeteo.searchURL(query: query, language: language) else {
            results = []
            message = ""
            return
        }
        message = "Searching…"
        let q = query
        task = URLSession.shared.dataTask(with: url) { data, _, error in
            let places = data.flatMap { try? OpenMeteo.decodePlaces($0) }
            let cancelled = (error as? URLError)?.code == .cancelled
            Task { @MainActor [weak self] in
                guard let self, !cancelled, self.query == q else { return }
                self.results = places ?? []
                if places == nil {
                    self.message = "Could not reach Open-Meteo."
                } else {
                    self.message = self.results.isEmpty ? "No places found." : ""
                }
            }
        }
        task?.resume()
    }
}

struct PlacePicker: View {
    @ObservedObject var search: PlaceSearch
    let welcome: Bool
    let onPick: (Place) -> Void
    let onUseLocation: () -> Void
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if welcome {
                Text("The weather outside, on your screen.")
                    .font(.title2.weight(.semibold))
                Text("Rain runs down the glass. Snow settles on your windows. Pick where you are, and Weatherglass follows the real weather there.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose a place").font(.title3.weight(.semibold))
            }
            Button(action: onUseLocation) {
                Label("Use My Current Location", systemImage: "location.fill")
            }
            .controlSize(.large)
            TextField("Search for a city", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let first = search.results.first { onPick(first) } }
            List(Array(search.results.enumerated()), id: \.offset, selection: $selection) { i, place in
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                    if !place.detail.isEmpty {
                        Text(place.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(i)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onPick(place) }
            }
            .frame(minHeight: 160)
            HStack {
                Text(search.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose") {
                    if let i = selection, i < search.results.count { onPick(search.results[i]) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            Text("Your search and the place you pick, rounded to about 10 km, go to Open-Meteo. Nothing else leaves your Mac.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The small window for choosing a place.
@MainActor
final class PlaceWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var onDismiss: (() -> Void)?
    private let search = PlaceSearch()

    var isOpen: Bool { window?.isVisible == true }

    /// - Parameter onDismiss: runs when the user closes the window without a choice.
    func show(welcome: Bool, onPick: @escaping (Place) -> Void, onUseLocation: @escaping () -> Void,
              onDismiss: (() -> Void)? = nil) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = PlacePicker(search: search, welcome: welcome, onPick: { [weak self] p in
            onPick(p)
            self?.close()
        }, onUseLocation: { [weak self] in
            onUseLocation()
            self?.close()
        })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = welcome ? "Welcome to Weatherglass" : "Choose a Place"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        self.onDismiss = onDismiss
        // Posted on the main thread while the window closes, by the close button or by `close()`.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                                               queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the window after a choice.
    func close() {
        onDismiss = nil
        window?.close()
    }

    private func closed() {
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        closeObserver = nil
        window = nil
        let dismissed = onDismiss
        onDismiss = nil
        dismissed?()
    }
}
