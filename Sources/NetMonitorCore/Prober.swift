import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CheckFailure: Hashable, Sendable {
    /// 本机没有 IPv6 出口（解析不到 AAAA 记录，或无路由立即被拒）
    case noIPv6
    case timeout
    case http(Int)
    case parse(ParseError)
    case network(String)
    case unknownEndpoint(String)

    public var message: String {
        switch self {
        case .noIPv6: return "本机无 IPv6 出口"
        case .timeout: return "超时"
        case .http(let code): return "HTTP \(code)"
        case .parse(let e): return e.message
        case .network(let m): return m
        case .unknownEndpoint(let id): return "找不到接口 \(id)"
        }
    }
}

public struct EndpointAttempt: Hashable, Sendable {
    public var endpointID: String
    public var endpointName: String
    public var failure: CheckFailure?
    public var duration: TimeInterval
}

public struct CheckOutcome: Hashable, Sendable {
    public var probeID: UUID
    public var date: Date
    public var geo: GeoInfo?
    public var evaluation: Evaluation?
    /// 最终给出结果的接口
    public var endpointID: String?
    public var endpointName: String?
    public var requestHost: String?
    public var attempts: [EndpointAttempt]
    public var duration: TimeInterval
    /// 本次结果：ok / mismatch / failed（已考虑「检测失败视为正常」）
    public var status: ProbeStatus

    public var failure: CheckFailure? { geo == nil ? attempts.last?.failure : nil }

    public var noIPv6: Bool {
        geo == nil && !attempts.isEmpty && attempts.allSatisfy { $0.failure == .noIPv6 }
    }

    /// 如「cloudflare 超时；ip-sb HTTP 503」
    public var failureSummary: String {
        if noIPv6 { return CheckFailure.noIPv6.message }
        return attempts.compactMap { a in a.failure.map { "\(a.endpointName) \($0.message)" } }
            .joined(separator: "；")
    }
}

/// 网络请求抽象，便于测试
public protocol HTTPFetching: Sendable {
    func fetch(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int)
}

/// 每次请求新建一个不缓存、不复用连接的会话：代理切换节点后，旧的长连接可能仍走旧节点。
public struct URLSessionFetcher: HTTPFetching {
    public init() {}

    public func fetch(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpShouldUsePipelining = false
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpAdditionalHeaders = [
            "User-Agent": "NetMonitor/0.1 (+https://github.com/arschlochnop/netMonitor)",
            "Connection": "close",
            "Accept": "application/json, text/plain, */*",
        ]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }
}

public struct Prober: Sendable {
    public var fetcher: HTTPFetching
    public var timeout: TimeInterval

    public init(fetcher: HTTPFetching = URLSessionFetcher(), timeout: TimeInterval = 8) {
        self.fetcher = fetcher
        self.timeout = timeout
    }

    /// 依次尝试主接口与备用接口，拿到 IP 后补全归属地并按规则判定。
    /// - Parameter supportsIPv6: 系统当前是否有 IPv6；为 false 时 IPv6 接口直接判为「本机无 IPv6」
    public func check(probe: Probe, endpoints: [String: Endpoint], enrichment: Endpoint?,
                      supportsIPv6: Bool? = nil, now: @escaping @Sendable () -> Date = { Date() }) async -> CheckOutcome {
        let started = now()
        var attempts: [EndpointAttempt] = []

        for id in probe.endpointChain {
            guard let endpoint = endpoints[id] else {
                attempts.append(EndpointAttempt(endpointID: id, endpointName: id, failure: .unknownEndpoint(id), duration: 0))
                continue
            }
            if endpoint.ipVersion == .v6, supportsIPv6 == false {
                attempts.append(EndpointAttempt(endpointID: id, endpointName: endpoint.name, failure: .noIPv6, duration: 0))
                continue
            }
            let attemptStart = now()
            do {
                var geo = try await query(endpoint)
                attempts.append(EndpointAttempt(endpointID: id, endpointName: endpoint.name, failure: nil,
                                                duration: now().timeIntervalSince(attemptStart)))
                if !geo.hasLocation, let enrichment {
                    if let extra = try? await query(enrichment, ip: geo.ip) {
                        geo = ResponseParser.merge(geo, enrichment: extra)
                    }
                }
                let evaluation = RuleEngine.evaluate(probe.rules, mode: probe.matchMode, geo: geo)
                return CheckOutcome(
                    probeID: probe.id, date: now(), geo: geo, evaluation: evaluation,
                    endpointID: endpoint.id, endpointName: endpoint.name, requestHost: endpoint.host,
                    attempts: attempts, duration: now().timeIntervalSince(started),
                    status: evaluation.passed ? .ok : .mismatch
                )
            } catch {
                let elapsed = now().timeIntervalSince(attemptStart)
                attempts.append(EndpointAttempt(endpointID: id, endpointName: endpoint.name,
                                                failure: Self.classify(error, endpoint: endpoint, elapsed: elapsed),
                                                duration: elapsed))
            }
        }

        let last = endpoints[probe.endpointChain.last ?? ""]
        return CheckOutcome(
            probeID: probe.id, date: now(), geo: nil, evaluation: nil,
            endpointID: nil, endpointName: nil, requestHost: last?.host,
            attempts: attempts, duration: now().timeIntervalSince(started),
            status: probe.alert.failureIsOK ? .ok : .failed
        )
    }

    /// 只测试一个接口（设置页的「测试一次」也走 check）
    public func query(_ endpoint: Endpoint, ip: String? = nil) async throws -> GeoInfo {
        var urlString = endpoint.url
        if let ip { urlString = urlString.replacingOccurrences(of: "{ip}", with: ip) }
        guard let url = URL(string: urlString) else { throw CheckFailureError(.network("地址无效")) }
        let (data, code) = try await fetcher.fetch(url, timeout: timeout)
        guard (200..<300).contains(code) else { throw CheckFailureError(.http(code)) }
        do {
            return try ResponseParser.parse(data, endpoint: endpoint)
        } catch let e as ParseError {
            throw CheckFailureError(.parse(e))
        }
    }

    static func classify(_ error: Error, endpoint: Endpoint, elapsed: TimeInterval) -> CheckFailure {
        if let e = error as? CheckFailureError { return e.failure }
        guard let urlError = error as? URLError else {
            return .network(error.localizedDescription)
        }
        let isV6 = endpoint.ipVersion == .v6
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cannotFindHost, .dnsLookupFailed:
            return isV6 ? .noIPv6 : .network("无法解析域名")
        case .cannotConnectToHost, .networkConnectionLost:
            // 毫秒级被拒说明本机没有 IPv6 路由，请求根本没发出去
            if isV6 && elapsed < 0.3 { return .noIPv6 }
            return .network("无法连接")
        case .notConnectedToInternet:
            return .network("未连接网络")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .network("证书或 TLS 错误")
        case .appTransportSecurityRequiresSecureConnection:
            return .network("系统禁止明文 HTTP")
        default:
            return .network(urlError.localizedDescription)
        }
    }
}

public struct CheckFailureError: Error {
    public var failure: CheckFailure
    public init(_ failure: CheckFailure) { self.failure = failure }
}
