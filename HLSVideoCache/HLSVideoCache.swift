//
//  HLSVideoCache.swift
//  HLSVideoCache
//
//  Created by Gary Newby on 19/08/2021.
//
// m3u8 playlist parsing based on: https://github.com/StyleShare/HLSCachingReverseProxyServer
// HLS Video caching using and embedded reverse proxy web server
// Swapped PINCache for Cache
// Added ability to save m3u8 manifest to disk for offline use
// Fix keys too long for filenames error by hashing
// Support segmented mp4 as well as ts

import Foundation
import GCDWebServer
import Cache
import CryptoKit

struct CacheItem: Codable {
    let data: Data
    let url: URL
    let mimeType: String
}

final class HLSVideoCache {

    static let shared = HLSVideoCache()

    private let webServer: GCDWebServer
    private let urlSession: URLSession
    private let cache: Storage<String, CacheItem>
    private let originURLKey = "__hls_origin_url"
    private let port: UInt = 1234

    private init() {
        self.webServer = GCDWebServer()
        self.urlSession = URLSession.shared

        // 200 mb disk cache
        let diskConfig = DiskConfig(name: "HLS_Video", expiry: .never, maxSize: 200 * 1024 * 1024)
        
        // 25 objects in memory
        let memoryConfig = MemoryConfig(expiry: .never, countLimit: 25, totalCostLimit: 25)
        
        guard let storage = try? Storage<String, CacheItem>(
            diskConfig: diskConfig,
            memoryConfig: memoryConfig,
            transformer: TransformerFactory.forCodable(ofType: CacheItem.self)
        ) else {
            fatalError("HLSVideoCache: unable to create cache")
        }
        
        self.cache = storage

        let documentDirectory = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        print("documentDirectory", documentDirectory?.path ?? "--")

        addPlaylistHandler()
        start()
    }

    deinit {
        stop()
    }

    private func start() {
        guard !webServer.isRunning else { return }
        webServer.start(withPort: port, bonjourName: nil)
    }

    private func stop() {
        guard webServer.isRunning else { return }
        webServer.stop()
    }

    private func originURL(from request: GCDWebServerRequest) -> URL? {
        guard let encodedURLString = request.query?[originURLKey] else { return nil }
        guard let urlString = encodedURLString.removingPercentEncoding else { return nil }
        let url = URL(string: urlString)
        return url
    }

    // MARK: - Public functions

    func clearCache() throws {
        try cache.removeAll()
    }

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
        webServer.addHandler(forMethod: "GET", pathRegex: "^/.*\\.*$", request: GCDWebServerRequest.self) { [weak self] (request: GCDWebServerRequest, completion) in
            guard let self = self,
                  let originURL = self.originURL(from: request)
            else {
                return completion(GCDWebServerErrorResponse(statusCode: 400))
            }

            if originURL.pathExtension == "m3u8" {
                // Return cached m3u8 manifest
                if let item = self.cachedDataItem(for: originURL),
                   let playlistData = self.reverseProxyPlaylist(with: item, forOriginURL: originURL) {
                    return completion(GCDWebServerDataResponse(data: playlistData, contentType: item.mimeType))
                }

                // Cache m3u8 manifest
                let task = self.urlSession.dataTask(with: originURL) { data, response, _ in
                    guard let data = data,
                          let response = response
                    else {
                        return completion(GCDWebServerErrorResponse(statusCode: 500))
                    }

                    let mimeType = response.mimeType!//originURL.absoluteString.contains(".m3u8") ? "audio/x-mpegURL" : response.mimeType!
                    let item = CacheItem(data: data, url: originURL, mimeType: mimeType)
                    self.saveCacheDataItem(item)

                    if let playlistData = self.reverseProxyPlaylist(with: item, forOriginURL: originURL) {
                        completion(GCDWebServerDataResponse(data: playlistData, contentType: item.mimeType))
                    } else {
                        print("Error: reverseProxyPlaylist nil", item.mimeType, item.url)
                        return completion(GCDWebServerErrorResponse(statusCode: 500))
                    }
                }

                task.resume()

            } else {

                // Return cached segment
                if let cachedItem = self.cachedDataItem(for: originURL) {
                    return completion(GCDWebServerDataResponse(data: cachedItem.data, contentType: cachedItem.mimeType))
                }

                // Cache segment
                let task = self.urlSession.dataTask(with: originURL) { data, response, _ in
                    guard let data = data,
                          let response = response,
                          let contentType = response.mimeType
                    else {
                        return completion(GCDWebServerErrorResponse(statusCode: 500))
                    }
                    
                    completion(GCDWebServerDataResponse(data: data, contentType: contentType))
                    
                    let mimeType = originURL.absoluteString.contains(".mp4") ? "video/mp4" : response.mimeType!
                    let item = CacheItem(data: data, url: originURL, mimeType: mimeType)
                    self.saveCacheDataItem(item)
                }

                task.resume()
            }
        }
    }

    // MARK: - Manipulating Playlist

    private func reverseProxyPlaylist(with item: CacheItem, forOriginURL originURL: URL) -> Data? {
        let original = String(data: item.data, encoding: .utf8)
        let parsed = original?
            .components(separatedBy: .newlines)
            .map { line in processPlaylistLine(line, forOriginURL: originURL) }
            .joined(separator: "\n")
        return parsed?.data(using: .utf8)
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
        let uriPattern = try! NSRegularExpression(pattern: "URI=\"([^\"]*)\"")
        let lineRange = NSRange(location: 0, length: line.count)
        guard let result = uriPattern.firstMatch(in: line, options: [], range: lineRange) else { return line }

        let uri = (line as NSString).substring(with: result.range(at: 1))
        guard let absoluteURL = absoluteURL(from: uri, forOriginURL: originURL) else { return line }
        guard let reverseProxyURL = reverseProxyURL(from: absoluteURL) else { return line }

        return uriPattern.stringByReplacingMatches(in: line, options: [], range: lineRange, withTemplate: "URI=\"\(reverseProxyURL.absoluteString)\"")
    }

    private func absoluteURL(from line: String, forOriginURL originURL: URL) -> URL? {
        guard ["m3u8", "ts", "mp4"].contains(originURL.pathExtension) else {
            print("Error: unsupported mime type")
            return nil
        }

        if line.hasPrefix("http://") || line.hasPrefix("https://") {
            return URL(string: line)
        }

        guard let scheme = originURL.scheme,
              let host = originURL.host
        else {
            print("Error: bad url")
            return nil
        }

        let path: String
        if line.hasPrefix("/") {
            path = line
        } else {
            path = originURL.deletingLastPathComponent().appendingPathComponent(line).path
        }

        return URL(string: scheme + "://" + host + path)?.standardized
    }

    // MARK: - Caching

    private func cachedDataItem(for resourceURL: URL) -> CacheItem? {
        let key = cacheKey(for: resourceURL)
        let item = try? cache.object(forKey: key)
        return item
    }

    private func saveCacheDataItem(_ item: CacheItem) {
        let key = cacheKey(for: item.url)
        try? cache.setObject(item, forKey: key)
    }
    
    private func cacheKey(for resourceURL: URL) -> String {
        // Hash key to avoid file name too long errors
        SHA256
            .hash(data: Data(resourceURL.absoluteString.utf8))
            .map { String(format: "%02hhx", $0) }
            .joined()
    }
}
