import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

struct ControlPanelView: View {
    @EnvironmentObject var manager: WallpaperManager
    @State private var isImporting = false
    @State private var launchAtLogin = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Dashboard") {
                    Label("Active Wallpaper", systemImage: "display")
                        .foregroundStyle(.blue)
                }
                
                if !manager.library.isEmpty {
                    Section("Library") {
                        ForEach(manager.library) { item in
                            HStack {
                                Image(systemName: "film")
                                Text(item.name)
                                    .lineLimit(1)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    manager.removeFromLibrary(id: item.id)
                                }
                            }
                            .onTapGesture {
                                manager.loadFromLibrary(item: item)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 20) {
                // Status Bar
                HStack {
                    if manager.isPluggedIn {
                        Label("Plugged In: Active", systemImage: "bolt.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .padding(6)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(6)
                    } else {
                        Label("On Battery: Paused", systemImage: "battery.50")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .padding(6)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                    }
                    Spacer()
                    
                    // Launch at Login Toggle
                    if #available(macOS 13.0, *) {
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .onChange(of: launchAtLogin) { newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    print("Failed to update launch at login: \(error)")
                                }
                            }
                            .onAppear {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                    }
                }
                .padding(.horizontal)

                // Main Preview
                VStack(spacing: 0) {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.1))
                            .aspectRatio(16/9, contentMode: .fit)

                        if let preview = manager.previewImage {
                            preview
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .layoutPriority(-1)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipped()
                    .cornerRadius(12, corners: [.topLeft, .topRight])

                    HStack {
                        Text(manager.currentVideoName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer()
                        Button("Change Wallpaper") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12, corners: [.bottomLeft, .bottomRight])
                }
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                .padding(.horizontal)

                // Volume Control
                VStack(alignment: .leading, spacing: 8) {
                    Label("Volume", systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $manager.volume, in: 0...1)
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Library
                if !manager.library.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Library")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 15) {
                                ForEach(manager.library) { item in
                                    LibraryItemView(item: item)
                                        .environmentObject(manager)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 10)
                        }
                        .frame(height: 110)
                    }
                    .padding(.bottom)
                }
            }
            .padding(.top)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.movie],
            allowsMultipleSelection: false
        ) { result in
            if let url = try? result.get().first {
                Task { @MainActor in
                    manager.loadVideo(url: url)
                }
            }
        }
    }
}

struct LibraryItemView: View {
    let item: SavedWallpaper
    @EnvironmentObject var manager: WallpaperManager
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.1))
                    .aspectRatio(16/9, contentMode: .fit)
                
                if let url = manager.thumbnailURL(for: item.id) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            Color.clear
                        }
                    }
                }
                
                // Play overlay on hover
                if isHovering {
                    Color.black.opacity(0.3)
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 140)
            .clipped()
            .cornerRadius(8)
            .shadow(radius: isHovering ? 4 : 0)
            .scaleEffect(isHovering ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isHovering)
            
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
                .foregroundStyle(.secondary)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            manager.loadFromLibrary(item: item)
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                manager.removeFromLibrary(id: item.id)
            }
        }
    }
}

// MARK: - Fixed Rounded Corner Logic (nonisolated)
extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + tl))

        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                    startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)

        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)

        path.closeSubpath()
        return path
    }
}

// MARK: - RectCorner (Sendable)
struct RectCorner: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let topLeft     = RectCorner(rawValue: 1 << 0)
    static let topRight    = RectCorner(rawValue: 1 << 1)
    static let bottomLeft  = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}
