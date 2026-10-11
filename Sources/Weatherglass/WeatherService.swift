import Foundation
import WeatherglassCore

/// Asks Open-Meteo for the current weather every 15 minutes, and sooner after a failure.
@MainActor
final class WeatherService {
    enum State: Equatable {
        case idle
        case loading
        case ok(Date)
        case failed(String)
    }

    static let interval: TimeInterval = 15 * 60
    private static let retries: [TimeInterval] = [30, 60, 120, 300, 600]

    private(set) var state: State = .idle
    var onUpdate: ((Conditions) -> Void)?
    var onStateChange: (() -> Void)?

    private var coordinates: Coordinates?
    private var timer: Timer?
    private var failures = 0
    private var task: URLSessionDataTask?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Weatherglass/\(AppInfo.version) (+\(AppInfo.repository))"]
        return URLSession(configuration: c)
    }()

    func track(_ c: Coordinates?) {
        coordinates = c
        failures = 0
        refresh()
    }

    func refresh() {
        timer?.invalidate()
        task?.cancel()
        guard let c = coordinates else {
            state = .idle
            onStateChange?()
            return
        }
        state = .loading
        onStateChange?()
        let url = OpenMeteo.forecastURL(for: c)
        let t = session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor [weak self] in
                self?.finish(data: data, status: status, error: error)
            }
        }
        task = t
        t.resume()
    }

    private func finish(data: Data?, status: Int, error: Error?) {
        if let e = error as? URLError, e.code == .cancelled { return }
        do {
            guard let data else { throw error ?? OpenMeteoError.badResponse }
            let c = try OpenMeteo.decodeConditions(data)
            failures = 0
            state = .ok(Date())
            onUpdate?(c)
            schedule(after: Self.interval)
        } catch {
            failures += 1
            state = .failed(Self.describe(error, status: status))
            schedule(after: Self.retries[min(failures - 1, Self.retries.count - 1)])
        }
        onStateChange?()
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = min(seconds * 0.1, 60)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func describe(_ error: Error, status: Int) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Offline"
            case .timedOut: return "Open-Meteo did not answer"
            default: return "Network error"
            }
        }
        if case OpenMeteoError.server(let reason) = error { return reason }
        return status == 429 ? "Too many requests" : "Unexpected answer from Open-Meteo"
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let repository = "https://github.com/yangyang1508/weatherglass"
}
