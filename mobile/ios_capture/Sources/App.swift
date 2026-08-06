import ARKit
import Photos
import SceneKit
import SwiftUI
import UIKit

@main
struct SweepSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Progress is reported from the stitching thread. Routing it through a `@MainActor`
/// object keeps the reporting closure `Sendable` without capturing the SwiftUI view.
@MainActor
final class StitchProgressModel: ObservableObject {
    @Published var fraction: Double = 0
}

// MARK: - Root view

struct ContentView: View {
    @StateObject private var manager = ARCaptureManager()
    @StateObject private var progress = StitchProgressModel()
    @State private var panorama: PanoramaStitcher.Result?
    @State private var isStitching = false
    @State private var errorMessage: String?
    @State private var showPanorama = false

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    var body: some View {
        ZStack {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()

            VStack {
                statusBar
                Spacer()
                if isStitching { stitchingIndicator } else { controls }
            }
            .padding()
        }
        .task {
            do {
                try manager.startSession()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear { manager.pauseSession() }
        .sheet(isPresented: $showPanorama) {
            if let panorama {
                PanoramaPreview(result: panorama) { message in errorMessage = message }
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Subviews

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(manager.trackingIsGood ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(manager.trackingIsGood ? "Tracking" : "Hold still — tracking is settling")
                    .font(.caption)
                Spacer()
                if manager.isSweeping {
                    Text("\(manager.frameCount) photos")
                        .font(.caption.monospacedDigit().bold())
                }
            }
            if manager.isDrifting {
                // Body rotation is the main cause of smeared panoramas and the user cannot
                // see it happening. Phrased as a nudge, not an error, because these frames
                // are now KEPT and merely down-weighted — telling the user they are being
                // thrown away would be false, and would push them to stop sweeping, which
                // is the failure that cost two device runs half the room.
                Label("Drifting — pivot around the phone, not your body, for sharper detail",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow, in: RoundedRectangle(cornerRadius: 8))
            }
            if manager.isSweeping, let guidance = manager.guidance {
                // The markers alone are not enough: they are spheres two metres away, so a
                // target behind, above or below the user is off screen and cannot be
                // "turned toward". This names the direction instead. Given prominence
                // because incomplete sweeps, not stitch quality, are now the thing
                // limiting the product — three runs ended at 54.6%, 58.6% and 69.6%.
                Label(guidance, systemImage: "location.north.line.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            }
            if manager.isSweeping {
                // Coverage, not a shot count, is what tells the user when to stop.
                ProgressView(value: Double(manager.sweepCoverage))
                    .tint(manager.sweepCoverage >= CaptureQuality.goodCoverage ? .green : .cyan)
                Text(String(format: "%.0f%% of the room covered · %.0f%% double-covered",
                            manager.sweepCoverage * 100, manager.sweepOverlap * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            Text(manager.status)
                .font(.footnote)
            if let separation = manager.lastSweepSeparation {
                Text(String(format: "Last sweep separation: %.3f m", separation))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.cyan)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var stitchingIndicator: some View {
        VStack(spacing: 8) {
            ProgressView(value: progress.fraction)
            Text("Stitching panorama…")
                .font(.footnote)
                .foregroundStyle(.white)
        }
        .padding()
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if manager.isSweeping {
                Button("Finish Sweep") { Task { await finishSweep() } }
                    .buttonStyle(PrimaryButtonStyle(tint: .green))
            } else {
                Button("Start Sweep") { manager.startSweep() }
                    .buttonStyle(PrimaryButtonStyle(tint: .blue))
            }

            if panorama != nil, !manager.isSweeping {
                Button("View") { showPanorama = true }
                    .buttonStyle(PrimaryButtonStyle(tint: .indigo))
            }
        }
    }

    // MARK: Actions

    @MainActor
    private func finishSweep() async {
        let sweep = await manager.finishSweep()
        guard !sweep.frames.isEmpty else {
            errorMessage = SweepError.noFrames.localizedDescription
            return
        }

        progress.fraction = 0
        isStitching = true
        defer { isStitching = false }

        let frames = sweep.frames
        let originYaw = sweep.originYaw
        let originPosition = sweep.originPosition
        let progressModel = progress
        let result = await Task.detached(priority: .userInitiated) { () -> PanoramaStitcher.Result? in
            PanoramaStitcher.stitch(
                frames: frames, originYaw: originYaw, originPosition: originPosition
            ) { fraction in
                Task { @MainActor in progressModel.fraction = fraction }
            }
        }.value

        guard let result else {
            errorMessage = SweepError.stitchFailed.localizedDescription
            return
        }
        panorama = result
        showPanorama = true
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Panorama preview

struct PanoramaPreview: View {
    let result: PanoramaStitcher.Result
    let onError: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saveLabel = "Save to Photos"
    @State private var shareItem: ShareItem?
    /// Hides every control so the panorama has the whole screen. The point of a 360 capture
    /// is the feeling of standing in the room, and a 320-point-high box in the middle of a
    /// form cannot deliver that — it reads as a thumbnail of a photo rather than a place.
    /// This is also the only view in which our output can be judged against Matterport's,
    /// which presents its scans full-bleed.
    @State private var isImmersive = false
    /// Controls fade out after a moment so nothing sits on top of the room, and come back
    /// on tap. Without the auto-hide the exit button is a permanent blemish; without the
    /// tap-to-restore the user is stranded in a view with no way out.
    @State private var showImmersiveControls = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                panorama
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        Text("Drag to look around")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(6)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            isImmersive = true
                            showImmersiveControls = true
                            scheduleControlsHide()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.body.bold())
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        .padding(8)
                        .accessibilityLabel("View full screen")
                    }
                Text(coverageSummary)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button(saveLabel) { Task { await save() } }
                        .buttonStyle(PrimaryButtonStyle(tint: .blue))
                    Button("Share") { shareItem = exportForSharing() }
                        .buttonStyle(PrimaryButtonStyle(tint: .indigo))
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Panorama")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(url: item.url)
            }
        }
        .fullScreenCover(isPresented: $isImmersive) { immersiveViewer }
    }

    private var panorama: some View {
        SphericalPanoramaView(image: result.image)
    }

    /// The panorama with nothing else on screen. `.ignoresSafeArea()` is what makes it
    /// edge-to-edge including under the notch and home indicator; without it the room stops
    /// at the safe-area inset and the effect is lost.
    private var immersiveViewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            panorama
                .ignoresSafeArea()

            if showImmersiveControls {
                VStack {
                    HStack {
                        Button { isImmersive = false } label: {
                            Image(systemName: "xmark")
                                .font(.body.bold())
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        .accessibilityLabel("Exit full screen")
                        Spacer()
                    }
                    Spacer()
                    Text(coverageSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding()
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        // A tap anywhere brings the controls back. It must NOT block the drag that turns
        // the camera, so this is a tap gesture on the stack rather than a button overlay.
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showImmersiveControls = true }
            scheduleControlsHide()
        }
        .onAppear { scheduleControlsHide() }
    }

    private func scheduleControlsHide() {
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard isImmersive else { return }
            withAnimation(.easeInOut(duration: 0.4)) { showImmersiveControls = false }
        }
    }

    /// Writes the panorama to a temporary JPEG and hands it to the system share sheet, so
    /// What the user is looking at, stated honestly.
    ///
    /// `result.coverage` is solid angle measured BEFORE hole filling, so it is what the
    /// sweep actually saw. Saying so matters more now than it used to: uncovered
    /// directions used to render as black wedges, which told the user at a glance that
    /// something was missing. They are now interpolated from their surroundings, which
    /// looks like a soft patch of real room — better to look at, but indistinguishable
    /// from a genuine capture. If the number is not the whole sphere, say what filled
    /// the rest, or the image quietly overstates itself.
    private var coverageSummary: String {
        let percent = result.coverage * 100
        let head = String(format: "%d frames · %.1f%% of the sphere captured",
                          result.frameCount, percent)
        guard result.coverage < Double(CaptureQuality.goodCoverage) else { return head }
        return head + "\nThe rest was filled in from its surroundings — sweep the gaps for real detail."
    }

    /// it can go to AirDrop, Files, or a cloud drive and be opened by the web viewer.
    ///
    /// JPEG, not PNG: a 4096x2048 PNG of a photographic panorama runs to tens of megabytes,
    /// which AirDrop and email handle badly. Quality 0.9 is visually lossless here.
    /// The filename carries the equirect dimensions because most 360 viewers detect the
    /// format from the 2:1 aspect ratio, and a human needs to recognise it too.
    @MainActor
    private func exportForSharing() -> ShareItem? {
        let image = UIImage(cgImage: result.image)
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            onError("The panorama could not be encoded for sharing.")
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-panorama-equirect-4096x2048.jpg")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            onError("Could not prepare the panorama for sharing: \(error.localizedDescription)")
            return nil
        }
        return ShareItem(url: url)
    }

    @MainActor
    private func save() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            onError("Photo library access was denied, so the panorama could not be saved.")
            return
        }
        let image = UIImage(cgImage: result.image)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            saveLabel = "Saved"
        } catch {
            onError("Saving failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Sharing

/// `.sheet(item:)` needs an Identifiable payload, and `URL` is not one.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Spherical panorama viewer

/// Wraps the equirectangular panorama back onto a sphere and puts the camera at its
/// centre, so the user looks around the room instead of at a flattened rectangle.
///
/// The equirect image IS the 360 view — this just undoes the projection for display.
/// The sphere is scaled by -1 on X so the texture is seen the right way round from the
/// INSIDE; without it every panorama reads mirrored, which is subtle enough to ship by
/// accident (text and door handles are the giveaway). `isDoubleSided` is required because
/// that negative scale flips the winding order and the inward faces would be culled.
struct SphericalPanoramaView: UIViewRepresentable {
    let image: CGImage

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.scene = makeScene()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    private func makeScene() -> SCNScene {
        let scene = SCNScene()

        let sphere = SCNSphere(radius: 10)
        // The default 48 segments visibly facet a texture this wide.
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.diffuse.contents = UIImage(cgImage: image)
        material.isDoubleSided = true
        // The panorama is emissive, not lit: no light source exists in this scene.
        material.lightingModel = .constant
        sphere.firstMaterial = material

        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.scale = SCNVector3(-1, 1, 1)
        scene.rootNode.addChildNode(sphereNode)

        let camera = SCNCamera()
        camera.fieldOfView = 80
        // The camera sits at the sphere's centre, so the near plane must not clip it.
        camera.zNear = 0.01
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3Zero
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }
}

// MARK: - AR view

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var manager: ARCaptureManager

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = manager.session
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        view.scene.rootNode.addChildNode(context.coordinator.markerRoot)
        // ARSCNView can claim the session delegate when a session is assigned to it.
        // The manager must keep it, or no frame is ever captured.
        manager.session.delegate = manager
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if manager.session.delegate !== manager {
            manager.session.delegate = manager
        }
        context.coordinator.sync(with: manager)
    }

    @MainActor
    final class Coordinator {
        let markerRoot = SCNNode()
        private var nodes: [UUID: SCNNode] = [:]
        private var builtSweepID: UUID?
        private var builtOriginYaw: Float?

        func sync(with manager: ARCaptureManager) {
            guard manager.isSweeping, manager.sweepOriginEstablished else {
                clear()
                return
            }

            if builtSweepID != manager.sweepID || builtOriginYaw != manager.sweepOriginYaw {
                rebuild(with: manager)
                builtSweepID = manager.sweepID
                builtOriginYaw = manager.sweepOriginYaw
            }

            for target in manager.targets {
                guard let material = nodes[target.id]?.geometry?.firstMaterial else { continue }
                let colour: UIColor = target.isCaptured ? .systemGreen : .white
                guard material.diffuse.contents as? UIColor != colour else { continue }
                material.diffuse.contents = colour
                material.emission.contents = colour.withAlphaComponent(0.5)
            }
        }

        private func clear() {
            guard !nodes.isEmpty else { return }
            markerRoot.childNodes.forEach { $0.removeFromParentNode() }
            nodes = [:]
            builtSweepID = nil
            builtOriginYaw = nil
        }

        private func rebuild(with manager: ARCaptureManager) {
            markerRoot.childNodes.forEach { $0.removeFromParentNode() }
            nodes = [:]

            let origin = manager.sweepOriginPosition
            for target in manager.targets {
                let direction = SweepFrame.toWorld(
                    target.localDirection,
                    originYaw: manager.sweepOriginYaw
                )
                let position = origin + direction * CaptureConfig.markerDistanceMeters

                let sphere = SCNSphere(radius: 0.06)
                sphere.firstMaterial?.lightingModel = .constant
                sphere.firstMaterial?.diffuse.contents = UIColor.white
                sphere.firstMaterial?.emission.contents = UIColor.white.withAlphaComponent(0.5)

                let node = SCNNode(geometry: sphere)
                node.position = SCNVector3(position.x, position.y, position.z)
                markerRoot.addChildNode(node)
                nodes[target.id] = node
            }
        }
    }
}
