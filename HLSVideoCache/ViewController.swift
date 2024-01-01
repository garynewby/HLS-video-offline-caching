//
//  ViewController.swift
//  HLSVideoCache
//
//  Created by Gary Newby on 24/08/2021.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    @IBOutlet private var playerView: UIView!
    @IBOutlet private var video1: UIButton!
    @IBOutlet private var video2: UIButton!
    @IBOutlet private var video3: UIButton!
    private let player = AVPlayer()
    private var playerLayer: AVPlayerLayer?

    // Test stream examples
    private let videos = [
        "https://cph-msl.akamaized.net/hls/live/2000341/test/master.m3u8",
        "https://mtoczko.github.io/hls-test-streams/test-vtt-fmp4-segments/playlist.m3u8"
    ]

    override func viewDidLoad() {
        super.viewDidLoad()

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = playerView.bounds
        playerView.layer.addSublayer(playerLayer)
        self.playerLayer = playerLayer

        video1.addAction(UIAction { _ in self.playVideo(at: 0) }, for: .touchUpInside)
        video2.addAction(UIAction { _ in self.playVideo(at: 1) }, for: .touchUpInside)

        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(didTapPlayerView(_:)))
        playerView.addGestureRecognizer(tapGestureRecognizer)
    }

    private func playVideo(at index: Int) {
        let url = URL(string: self.videos[index])!
        let videoURL = HLSVideoCache.shared.reverseProxyURL(from: url)!

        let playerItem = AVPlayerItem(url: videoURL)
        player.replaceCurrentItem(with: playerItem)
        playerLayer?.frame = playerView.bounds
        player.play()
    }

    @objc private func didTapPlayerView(_ sender: UITapGestureRecognizer) {
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
    }
}

