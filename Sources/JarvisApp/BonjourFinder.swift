import Foundation
import Network

/// Cherche le service Bonjour "_jarvis._tcp" annoncé par dashboard/server.py
/// et résout son adresse IP, pour que l'appli n'ait jamais besoin qu'on lui
/// tape l'IP du PC à la main.
final class BonjourFinder {
    private var browser: NWBrowser?
    private var resolveConnection: NWConnection?

    func find(timeout: TimeInterval = 6.0, completion: @escaping (String?) -> Void) {
        var finished = false
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_jarvis._tcp", domain: "local."), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !finished, let first = results.first else { return }
            self.resolve(endpoint: first.endpoint) { ip in
                guard !finished else { return }
                finished = true
                browser.cancel()
                completion(ip)
            }
        }
        browser.start(queue: .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !finished else { return }
            finished = true
            browser.cancel()
            completion(nil)
        }
    }

    private func resolve(endpoint: NWEndpoint, completion: @escaping (String?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.resolveConnection = connection
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var ip: String?
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, _) = remote {
                    ip = Self.hostToString(host)
                }
                connection.cancel()
                completion(ip)
            case .failed, .cancelled:
                completion(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private static func hostToString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr): return "\(addr)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }
}
