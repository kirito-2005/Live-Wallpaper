import SwiftUI
import AVFoundation
import Combine
import IOKit.ps
import AppKit

// Helper to wrap non-Sendable types for safe transport to MainActor
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

struct SavedWallpaper: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let bookmarkData: Data
}

@MainActor
final class WallpaperManager: NSObject, ObservableObject {
    @Published var currentVideoName: String = "No video selected"
    @Published var previewImage: Image? = nil
    // Change volume to Double for SwiftUI Slider compatibility
    @Published var volume: Double = 0.0 {
        didSet { engines.forEach { $0.setVolume(Float(volume)) } }
    }
    @Published var isPluggedIn: Bool = true
    @Published var library: [SavedWallpaper] = []

    private var engines: [WallpaperWindow] = []
    private let defaults = UserDefaults.standard
    private var currentVideoURL: URL?
    private var powerTimer: Timer?
    private var hasSecurityScopeAccess = false
    private var rebuildWorkItem: DispatchWorkItem?
    private var screenObserverToken: NSObjectProtocol?
    private var isRebuildingWindows = false
    private var powerRunLoopSource: CFRunLoopSource?
    
    // Sleep/Wake Observers
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?

    override init() {
        super.init()
        loadLibrary()
        regenerateMissingThumbnails()

        screenObserverToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.rebuildWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.setupWindows()
                }
                self.rebuildWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
        }
        
        // Optimize Power: Pause on Sleep, Resume on Wake
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engines.forEach { $0.pauseVideo() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkPowerStatus()
            self?.engines.forEach { $0.resumeVideo() }
        }
        
        // Handle Screen Lock / Display Sleep
        screenSleepObserver = center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engines.forEach { $0.pauseVideo() }
        }
        screenWakeObserver = center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkPowerStatus()
            self?.engines.forEach { $0.resumeVideo() }
        }

        startPowerMonitoring()

        Task { @MainActor in
            self.setupWindows()
            self.volume = self.defaults.double(forKey: "savedVolume")
            self.restoreLastVideo()
        }
    }

    @objc private func setupWindows() {
        isRebuildingWindows = true
        let oldEngines = engines
        engines = []
        oldEngines.forEach { $0.close() }

        for screen in NSScreen.screens {
            let engine = WallpaperWindow(screen: screen)
            engine.orderBack(nil)
            engine.setVolume(Float(volume))
            if let url = currentVideoURL { engine.play(url: url) }
            engines.append(engine)
        }

        checkPowerStatus()
        isRebuildingWindows = false
    }

    func loadVideo(url: URL) {
        currentVideoURL = url
        currentVideoName = url.lastPathComponent
        engines.forEach { $0.play(url: url) }
        generateThumbnail(for: url)
        saveBookmark(for: url)
        addToLibrary(url: url)
    }

    private func generateThumbnail(for url: URL) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Optimize Memory: Downscale thumbnail
        generator.maximumSize = CGSize(width: 512, height: 512)
        
        let time = CMTime(seconds: 1, preferredTimescale: 60)

        if #available(macOS 14.0, *) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let (cgImage, _) = try await generator.image(at: time)
                    let nsImage = NSImage(cgImage: cgImage, size: .zero)
                    self.previewImage = Image(nsImage: nsImage)
                } catch { }
            }
        } else {
            var actualTime = CMTime.zero
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: &actualTime)
                let nsImage = NSImage(cgImage: cgImage, size: .zero)
                self.previewImage = Image(nsImage: nsImage)
            } catch { }
        }
    }

    func setVolume(_ level: Double) {
        volume = level
        defaults.set(level, forKey: "savedVolume")
    }

    private func startPowerMonitoring() {
        // Use a simple Timer for polling instead of C-API callbacks to prevent crashes
        powerTimer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkPowerStatus() }
        }
        if let timer = powerTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func checkPowerStatus() {
        // Fix: IOPSCopyPowerSourcesInfo follows Copy Rule -> takeRetainedValue()
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        
        // Fix: IOPSGetProvidingPowerSourceType follows Get Rule -> takeUnretainedValue()
        guard let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else { return }

        let foundAC = (source == kIOPSACPowerValue)

        if isRebuildingWindows { return }
        if isPluggedIn != foundAC {
            isPluggedIn = foundAC
            if foundAC {
                engines.forEach { $0.resumeVideo() }
            } else {
                engines.forEach { $0.pauseVideo() }
            }
        }
    }

    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: "videoBookmark")
        } catch { }
    }

    private func restoreLastVideo() {
        guard let data = defaults.data(forKey: "videoBookmark") else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if url.startAccessingSecurityScopedResource() {
                hasSecurityScopeAccess = true
                loadVideo(url: url)
            }
        } catch { }
    }
    
    // MARK: - Library Management
    
    private var thumbnailsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Thumbnails")
    }
    
    private func loadLibrary() {
        if let data = defaults.data(forKey: "wallpaperLibrary"),
           let decoded = try? JSONDecoder().decode([SavedWallpaper].self, from: data) {
            self.library = decoded
        }
    }
    
    private func saveLibrary() {
        if let encoded = try? JSONEncoder().encode(library) {
            defaults.set(encoded, forKey: "wallpaperLibrary")
        }
    }
    
    func thumbnailURL(for id: UUID) -> URL? {
        thumbnailsDirectory?.appendingPathComponent("\(id.uuidString).jpg")
    }
    
    private func saveThumbnail(from url: URL, id: UUID) {
        guard let dir = thumbnailsDirectory else { return }
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let destination = dir.appendingPathComponent("\(id.uuidString).jpg")
        
        // Generate in background
        Task {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            
            do {
                let (cgImage, _) = try await generator.image(at: .init(seconds: 1, preferredTimescale: 60))
                let nsImage = NSImage(cgImage: cgImage, size: .zero)
                
                if let tiff = nsImage.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                    try jpeg.write(to: destination)
                }
            } catch {
                print("Failed to save thumbnail: \(error)")
            }
        }
    }
    
    private func regenerateMissingThumbnails() {
        Task {
            for item in library {
                if let url = thumbnailURL(for: item.id), !FileManager.default.fileExists(atPath: url.path) {
                    // Thumbnail missing, regenerate
                    var isStale = false
                    if let videoURL = try? URL(resolvingBookmarkData: item.bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                         if videoURL.startAccessingSecurityScopedResource() {
                             saveThumbnail(from: videoURL, id: item.id)
                             videoURL.stopAccessingSecurityScopedResource()
                         }
                    }
                }
            }
        }
    }
    
    func addToLibrary(url: URL) {
        // Check for duplicates by name (simple check)
        guard !library.contains(where: { $0.name == url.lastPathComponent }) else { return }
        
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let id = UUID()
            let item = SavedWallpaper(id: id, name: url.lastPathComponent, bookmarkData: bookmark)
            
            saveThumbnail(from: url, id: id)
            
            library.append(item)
            saveLibrary()
        } catch {
            print("Failed to create bookmark for library: \(error)")
        }
    }
    
    func removeFromLibrary(id: UUID) {
        library.removeAll { $0.id == id }
        saveLibrary()
        
        // Remove thumbnail file
        if let url = thumbnailURL(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    func loadFromLibrary(item: SavedWallpaper) {
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: item.bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if url.startAccessingSecurityScopedResource() {
                // If we had previous access, stop it
                if hasSecurityScopeAccess { currentVideoURL?.stopAccessingSecurityScopedResource() }
                
                hasSecurityScopeAccess = true
                loadVideo(url: url)
            }
        } catch {
            print("Failed to resolve bookmark: \(error)")
        }
    }

    deinit {
        rebuildWorkItem?.cancel()
        if let token = screenObserverToken { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.removeObserver(self)
        
        if let sleep = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleep) }
        if let wake = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        if let sSleep = screenSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sSleep) }
        if let sWake = screenWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(sWake) }
        
        // Wrap non-Sendable types
        let timer = UncheckedSendable(powerTimer)
        let source = UncheckedSendable(powerRunLoopSource)
        let url = currentVideoURL
        let hasAccess = hasSecurityScopeAccess
        
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                timer.value?.invalidate()
                if let src = source.value {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
                }
                if hasAccess { url?.stopAccessingSecurityScopedResource() }
            }
        } else {
            timer.value?.invalidate()
            if let src = source.value {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            }
            if hasAccess { url?.stopAccessingSecurityScopedResource() }
        }
    }
}
