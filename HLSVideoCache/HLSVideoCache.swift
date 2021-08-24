//
//  HLSVideoCache.swift
//  HLSVideoCache
//
//  Created by Gary Newby on 19/08/2021.
//
// Based on: https://github.com/StyleShare/HLSCachingReverseProxyServer
// Changes:
// HLS Video caching using and embedded reverse proxy web server
// Swapped PINCache for Cache
// Added ability to save m3u8 manifest to disk for offline use
// Fix keys too long for filenames error by hashing

import Foundation
import GDCWebServer
import Cache
import CryptoKit

final class HLSVideoCache {

    static let shared = HLSVideoCache()
    private let webServer: GCDWebServer
    private let urlSession: URLSession
    private let cache: Storage<String, Data>
    private let originURLKey = "__hls_origin_url"
    private let contentType = "application/x-mpegurl"
    private let port: UInt = 1234

    private init() {
        self.webServer = GCDWebServer()
        self.urlSession = URLSession.shared

        // 200 mb disk cache
        let diskConfig = DiskConfig(name: "HLS_Video", expiry: .never, maxSize: 200 * 1024 * 1024)
        // 25 objects in memory
        let memoryConfig = MemoryConfig(expiry: .never, countLimit: 25, totalCostLimit: 25)
        guard let storage = try? Storage<String, Data>(
            diskConfig: diskConfig,
            memoryConfig: memoryConfig,
            transformer: TransformerFactory.forCodable(ofType: Data.self)
        ) else {
            fatalError("HLSVideoCache: unable to create cache")
        }
        self.cache = storage

        addPlaylistHandler()
        addSegmentHandler()
        start() 
    }

    deinit {
        stop()
    }

    // MARK: - Public functions

    func start() {
        guard !webServer.isRunning else { return }
        webServer.start(withPort: port, bonjourName: nil)
    }

    func stop() {
        guard webServer.isRunning else { return }
        webServer.stop()
    }

    func clearCache() throws {
        try cache.removeAll()
    }

    // MARK: - Resource URL

    func reverseProxyURL(from originURL: URL) -> URL? {
        guard var components = URLComponents(url: originURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)

        let originURLQueryItem = URLQueryItem(name: originURLKey, value: originURL.absoluteString)
        components.queryItems = (components.queryItems ?? []) + [originURLQueryItem]

        return components.url
    }

    // MARK: - Request Handler

    private func addPlaylistHandler() {
        webServer.addHandler(forMethod: "GET", pathRegex: "^/.*\\.m3u8$", request: GCDWebServerRequest.self) { [weak self] request, completion in
            guard let self = self else {
                return completion(GCDWebServerDataResponse(statusCode: 500))
            }
            guard let originURL = self.originURL(from: request) else {
                return completion(GCDWebServerErrorResponse(statusCode: 400))
            }

            // Use saved manifest when offline
            if let data = self.cachedData(for: originURL) {
                let playlistData = self.reverseProxyPlaylist(with: data, forOriginURL: originURL)
                completion(GCDWebServerDataResponse(data: playlistData, contentType: self.contentType))

            } else {
                let task = self.urlSession.dataTask(with: originURL) { data, response, _ in
                    guard let data = data, let response = response else {
                        return completion(GCDWebServerErrorResponse(statusCode: 500))
                    }
                    guard response.mimeType == self.contentType else {
                        // Unsupported contentType
                        return completion(GCDWebServerErrorResponse(statusCode: 400))
                    }

                    // Save manifest
                    self.saveCacheData(data, for: originURL)

                    let playlistData = self.reverseProxyPlaylist(with: data, forOriginURL: originURL)
                    completion(GCDWebServerDataResponse(data: playlistData, contentType: self.contentType))
                }

                task.resume()
            }
        }
    }

    private func addSegmentHandler() {
        webServer.addHandler(forMethod: "GET", pathRegex: "^/.*\\.ts$", request: GCDWebServerRequest.self) { [weak self] request, completion in
            guard let self = self else {
                return completion(GCDWebServerDataResponse(statusCode: 500))
            }
            guard let originURL = self.originURL(from: request) else {
                return completion(GCDWebServerErrorResponse(statusCode: 400))
            }

            if let cachedData = self.cachedData(for: originURL) {
                return completion(GCDWebServerDataResponse(data: cachedData, contentType: "video/mp2t"))
            }

            let task = self.urlSession.dataTask(with: originURL) { data, response, _ in
                guard let data = data, let response = response else {
                    return completion(GCDWebServerErrorResponse(statusCode: 500))
                }

                let contentType = response.mimeType ?? "video/mp2t"
                completion(GCDWebServerDataResponse(data: data, contentType: contentType))

                self.saveCacheData(data, for: originURL)
            }
            task.resume()
        }
    }

    private func originURL(from request: GCDWebServerRequest) -> URL? {
        guard let encodedURLString = request.query?[originURLKey] else { return nil }
        guard let urlString = encodedURLString.removingPercentEncoding else { return nil }
        let url = URL(string: urlString)
        return url
    }

    // MARK: - Manipulating Playlist

    private func reverseProxyPlaylist(with data: Data, forOriginURL originURL: URL) -> Data {
        return String(data: data, encoding: .utf8)!
            .components(separatedBy: .newlines)
            .map { line in processPlaylistLine(line, forOriginURL: originURL) }
            .joined(separator: "\n")
            .data(using: .utf8)!
    }

    private func processPlaylistLine(_ line: String, forOriginURL originURL: URL) -> String {
        guard !line.isEmpty else { return line }

        if line.hasPrefix("#") {
            return lineByReplacingURI(line: line, forOriginURL: originURL)
        }

        if let originalSegmentURL = absoluteURL(from: line, forOriginURL: originURL),
           let reverseProxyURL = reverseProxyURL(from: originalSegmentURL) {
            return reverseProxyURL.absoluteString
        }
        return line
    }

    private func lineByReplacingURI(line: String, forOriginURL originURL: URL) -> String {
        let uriPattern = try! NSRegularExpression(pattern: "URI=\"(.*)\"")
        let lineRange = NSRange(location: 0, length: line.count)
        guard let result = uriPattern.firstMatch(in: line, options: [], range: lineRange) else { return line }

        let uri = (line as NSString).substring(with: result.range(at: 1))
        guard let absoluteURL = absoluteURL(from: uri, forOriginURL: originURL) else { return line }
        guard let reverseProxyURL = reverseProxyURL(from: absoluteURL) else { return line }

        return uriPattern.stringByReplacingMatches(in: line, options: [], range: lineRange, withTemplate: "URI=\"\(reverseProxyURL.absoluteString)\"")
    }

    private func absoluteURL(from line: String, forOriginURL originURL: URL) -> URL? {
        guard ["m3u8", "ts"].contains(originURL.pathExtension) else { return nil }

        if line.hasPrefix("http://") || line.hasPrefix("https://") {
            return URL(string: line)
        }

        guard let scheme = originURL.scheme, let host = originURL.host else { return nil }

        let path: String
        if line.hasPrefix("/") {
            path = line
        } else {
            path = originURL.deletingLastPathComponent().appendingPathComponent(line).path
        }

        return URL(string: scheme + "://" + host + path)?.standardized
    }

    // MARK: - Caching

    private func cachedData(for resourceURL: URL) -> Data? {
        let key = cacheKey(for: resourceURL)
        return try? cache.object(forKey: key)
    }

    private func saveCacheData(_ data: Data, for resourceURL: URL) {
        let key = cacheKey(for: resourceURL)
        try? cache.setObject(data, forKey: key)
    }

    private func cacheKey(for resourceURL: URL) -> String {
        // Hash key to avoid file name too long errors
        SHA256.hash(data: Data(resourceURL.absoluteString.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }
}
