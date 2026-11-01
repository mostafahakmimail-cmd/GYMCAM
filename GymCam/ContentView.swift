import SwiftUI

struct ContentView: View {
    @StateObject private var cam = CameraEngine()
    @State private var showAdjust = false
    @State private var showGrid = true
    @State private var focusPoint: CGPoint?
    @State private var lastTap: CGPoint?
    @State private var viewSize: CGSize = .zero
    @State private var delay = 0
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let frame = CameraEngine.previewRect(in: geo.size)
                ZStack {
                    CameraPreview(renderer: cam.renderer, onHardwareButton: recordTapped)

                    if showGrid {
                        GridOverlay()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { point in
                            lastTap = point
                            tapFocus(point, size: geo.size, lock: false)
                        }
                        .onLongPressGesture(minimumDuration: 0.6) {
                            let p = lastTap ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                            tapFocus(p, size: geo.size, lock: true)
                        }
                        .onAppear { viewSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in viewSize = newSize }

                    if let p = focusPoint {
                        FocusSquare(locked: cam.aeafLocked)
                            .position(p)
                            .allowsHitTesting(false)
                    }

                    if let c = countdown {
                        Text("\(c)")
                            .font(.system(size: 140, weight: .thin, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(radius: 12)
                            .allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea()

            controls

            if cam.permissionDenied { permissionView }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { cam.start() }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            topBar
            Spacer()
            if let t = cam.toast {
                Text(t)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
            if showAdjust {
                AdjustPanel(cam: cam)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            LookStrip(selected: $cam.look)
            lensRow
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: cam.toast)
    }

    private var topBar: some View {
        HStack {
            Menu {
                Picker("Resolution", selection: $cam.resolution) {
                    ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Frame rate", selection: $cam.fps) {
                    ForEach(CameraEngine.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Self-timer", selection: $delay) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("10 seconds").tag(10)
                }
                .pickerStyle(.menu)
                Toggle("Stabilization", isOn: $cam.stabilization)
                Toggle("Grid", isOn: $showGrid)
            } label: {
                chip("\(cam.resolution.rawValue) · \(cam.fps)")
            }
            .disabled(cam.isRecording)

            Spacer()

            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(timeString(cam.recordingSeconds))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.45), in: Capsule())
            } else if cam.isSaving {
                chip("SAVING…")
            }

            Spacer()

            if cam.aeafLocked {
                chip("AE/AF LOCK", color: .yellow)
            } else if delay > 0 {
                chip("TIMER \(delay)s")
            } else {
                chip(cam.look.title.uppercased())
            }
        }
        .padding(.top, 8)
    }

    private var lensRow: some View {
        HStack(spacing: 10) {
            ForEach(cam.availableLenses) { lens in
                let selected = cam.lens == lens
                Button {
                    cam.lens = lens
                } label: {
                    Text(lens.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selected ? Color.yellow : Color.white)
                        .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(cam.isRecording)
        .opacity(cam.isRecording ? 0.4 : 1)
        .animation(.spring(duration: 0.25), value: cam.lens)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                withAnimation(.spring(duration: 0.3)) { showAdjust.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(showAdjust ? Color.yellow : Color.white)
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            RecordButton(isRecording: cam.isRecording, isCounting: countdown != nil, action: recordTapped)

            Spacer()

            Button {
                let p = lastTap ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                tapFocus(p, size: viewSize, lock: !cam.aeafLocked)
            } label: {
                Image(systemName: cam.aeafLocked ? "lock.fill" : "lock.open")
                    .font(.title3)
                    .foregroundStyle(cam.aeafLocked ? Color.yellow : Color.white)
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Camera access is off").font(.headline)
            Text("Turn on Camera and Microphone for GymCam in Settings to start filming.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Actions

    private func tapFocus(_ point: CGPoint, size: CGSize, lock: Bool) {
        guard size.width > 0 else { return }
        cam.focus(at: point, in: size, lock: lock)
        focusPoint = point
        let stamp = point
        DispatchQueue.main.asyncAfter(deadline: .now() + (lock ? 2.5 : 1.2)) {
            if focusPoint == stamp {
                withAnimation(.easeOut(duration: 0.3)) { focusPoint = nil }
            }
        }
    }

    private func recordTapped() {
        if cam.isRecording {
            cam.stopRecording()
            return
        }
        if countdownTask != nil {
            countdownTask?.cancel()
            countdownTask = nil
            countdown = nil
            return
        }
        guard delay > 0 else {
            cam.startRecording()
            return
        }
        let seconds = delay
        countdownTask = Task { @MainActor in
            for s in stride(from: seconds, to: 0, by: -1) {
                countdown = s
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            cam.startRecording()
        }
    }

    private func chip(_ text: String, color: Color = .white) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.45), in: Capsule())
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Pieces

struct RecordButton: View {
    let isRecording: Bool
    let isCounting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 32, style: .continuous)
                    .fill(isCounting ? Color.orange : Color.red)
                    .frame(width: isRecording ? 32 : 64, height: isRecording ? 32 : 64)
            }
            .animation(.spring(duration: 0.25), value: isRecording)
        }
        .buttonStyle(.plain)
    }
}

struct LookStrip: View {
    @Binding var selected: Look

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Look.allCases) { look in
                    let isOn = selected == look
                    Button {
                        selected = look
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Text(look.title.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(isOn ? Color.black : Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(isOn ? Color.white : Color.black.opacity(0.45), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct AdjustPanel: View {
    @ObservedObject var cam: CameraEngine

    var body: some View {
        VStack(spacing: 14) {
            SliderRow(title: "Exposure", value: $cam.exposureBias, range: -2...2,
                      text: String(format: "%+.1f EV", cam.exposureBias))
            Toggle("Auto white balance", isOn: $cam.wbAuto)
                .font(.footnote.weight(.semibold))
                .tint(.yellow)
            if !cam.wbAuto {
                SliderRow(title: "Warmth", value: $cam.temperature, range: 2500...9000,
                          text: "\(Int(cam.temperature))K")
                SliderRow(title: "Tint", value: $cam.tint, range: -60...60,
                          text: String(format: "%+.0f", cam.tint))
            }
            SliderRow(title: "Film FX", value: $cam.fxAmount, range: 0...1.5,
                      text: "\(Int(cam.fxAmount * 100))%")
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                Spacer()
                Text(text).font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
                .tint(.white)
        }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { path in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: g.size.height))
                    let y = g.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
    }
}

struct FocusSquare: View {
    let locked: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(locked ? Color.yellow : Color.white, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .overlay(alignment: .top) {
                if locked {
                    Text("LOCK")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.yellow)
                        .offset(y: -16)
                }
            }
    }
}
