//
//  WallpaperWindow.swift
//  Live Wallpaper
//

import Cocoa
import AVFoundation

@MainActor
final class WallpaperWindow: NSWindow {

    private var playerLooper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?

    override var canBecomeKey: Bool { true }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false

        let desktopLevel = CGWindowLevelForKey(.desktopIconWindow)
        self.level = NSWindow.Level(rawValue: Int(desktopLevel) - 1)

        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true

        setupLayer(for: screen.frame)
    }

    private func setupLayer(for frame: CGRect) {
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        self.contentView = view

        let player = AVQueuePlayer()
        let layer = AVPlayerLayer(player: player)

        queuePlayer = player
        playerLayer = layer

        guard let hostLayer = view.layer else { return }
        layer.frame = hostLayer.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspectFill

        hostLayer.addSublayer(layer)
    }

    func play(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        queuePlayer?.removeAllItems()
        playerLooper?.disableLooping()
        playerLooper = nil

        if let player = queuePlayer {
            playerLooper = AVPlayerLooper(player: player, templateItem: item)
            player.play()
        }
    }

    func setVolume(_ volume: Float) {
        queuePlayer?.volume = volume
        // Optimize CPU: Mute if volume is effectively zero
        queuePlayer?.isMuted = (volume <= 0.001)
    }

    func pauseVideo() {
        queuePlayer?.pause()
        self.alphaValue = 0.0
    }

    func resumeVideo() {
        queuePlayer?.play()
        self.alphaValue = 1.0
    }

    private func teardownPlayer() {
        playerLooper?.disableLooping()
        playerLayer?.player = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        playerLayer?.removeFromSuperlayer()
        playerLooper = nil
        playerLayer = nil
        queuePlayer = nil
    }

    override func close() {
        playerLayer?.player = nil
        teardownPlayer()
        super.close()
    }

    deinit {
        let looper = playerLooper
        let layer = playerLayer
        let player = queuePlayer

        if !Thread.isMainThread {
            DispatchQueue.main.async {
                looper?.disableLooping()
                layer?.player = nil
                player?.pause()
                player?.removeAllItems()
                layer?.removeFromSuperlayer()
            }
        } else {
            looper?.disableLooping()
            layer?.player = nil
            player?.pause()
            player?.removeAllItems()
            layer?.removeFromSuperlayer()
        }
    }
}
