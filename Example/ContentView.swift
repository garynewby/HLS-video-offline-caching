//
//  ContentView.swift
//  Example
//
//  Created by Gary Newby on 25/11/2024.
//

import SwiftUI
import AVKit

struct ContentView: View {

    private var player = AVPlayer()
    @State var videoUrl: URL?

    let videoUrls = [
        "1. TS" : "http://devimages.apple.com/iphone/samples/bipbop/bipbopall.m3u8",
        "2. FMP4" : "https://mtoczko.github.io/hls-test-streams/test-vtt-fmp4-segments/playlist.m3u8"
    ]

    var body: some View {
        VStack(spacing: 30) {
            Text("HLS video offline caching")
                .font(.title2).bold()
                .foregroundStyle(.white)

            if videoUrl != nil {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .border(.white)
            } else {
                Rectangle()
                    .aspectRatio(16/9, contentMode: .fit)
                    .border(.white)
            }

            ForEach(videoUrls.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                Button {
                    playVideo(value)
                } label: {
                    Text(key)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                do {
                    try HLSVideoCache.shared.clearCache()
                } catch {
                    print("Error clearing cache: \(error)")
                }
            } label: {
                Text("Clear cache")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text(videoUrl?.absoluteString ?? "No video selected")
                .font(.footnote)
                .foregroundStyle(.white)

            Spacer()
        }
        .padding()
        .background(.black)
    }

    func playVideo(_ urlString: String) {
        guard let url = URL(string: urlString),
              let videoUrl = HLSVideoCache.shared.reverseProxyURL(from: url) else {
            print("Invalid video URL")
            return
        }
        self.videoUrl = videoUrl
        let playerItem = AVPlayerItem(url: videoUrl)
        player.replaceCurrentItem(with: playerItem)
        player.play()
    }
}

#Preview {
    ContentView()
}
