import AppKit
import SwiftUI
import UnderstudyShared

/// Understudy Settings edits effects.json beside a live preview of the
/// Understudy camera. It never talks to the agent: the agent watches the file
/// and picks up each save. The preview is just another viewer, so opening
/// this mid-meeting joins the camera rather than disturbing it.
@main
struct SettingsApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = SettingsModel()

    var body: some Scene {
        // A new id from the single-column version, so macOS doesn't restore
        // that window's narrow, tall frame onto this one.
        Window("Understudy Effects", id: "preview-and-settings") {
            SettingsWindow(model: model)
        }
        .defaultSize(width: 1300, height: 620)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@Observable
final class SettingsModel {
    /// Every change is saved straight away; the agent coalesces bursts, so
    /// dragging a slider is fine.
    var settings: EffectSettings {
        didSet {
            guard settings != oldValue else { return }
            do {
                try settings.save()
                saveError = nil
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
    var saveError: String?

    init() {
        do {
            settings = try EffectSettings.load()
        } catch {
            // Leave a broken file alone until the first edit replaces it.
            settings = EffectSettings()
            saveError = "effects.json is unreadable (\(error.localizedDescription)); the next change overwrites it."
        }
    }
}

/// The preview fills the left and grows with the window; the settings keep a
/// fixed column on the right.
struct SettingsWindow: View {
    let model: SettingsModel
    @State private var preview = CameraPreview()

    var body: some View {
        HStack(spacing: 0) {
            PreviewPane(preview: preview)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            EffectsForm(model: model)
                .frame(width: 400)
        }
        .frame(minHeight: 560)
        .onAppear { preview.start() }
        .onDisappear { preview.stop() }
    }
}

struct EffectsForm: View {
    @Bindable var model: SettingsModel

    private var blobs: Binding<BlobSettings> { $model.settings.blobs }

    var body: some View {
        Form {
            Section {
                Toggle("Blob tracking", isOn: blobs.enabled)
            } footer: {
                Text("Changes apply to live video as you make them.")
                    .foregroundStyle(.secondary)
            }

            Section("Detection") {
                LabeledSlider(
                    "Threshold", value: blobs.threshold, in: BlobSettings.thresholdRange,
                    format: { String(format: "%.2f", $0) })
                Toggle("Track dark regions", isOn: blobs.invert)
            }
            .disabled(!model.settings.blobs.enabled)

            Section("Picking") {
                LabeledSlider(
                    "Boxes", value: intBinding(blobs.boxCount), in: closed(BlobSettings.boxCountRange),
                    format: { "\(Int($0))" })
                LabeledSlider(
                    "Re-pick every", value: intBinding(blobs.reselectFrames),
                    in: closed(BlobSettings.reselectFramesRange),
                    format: { String(format: "%.1fs", $0 / 30) })
                LabeledSlider(
                    "Timing jitter", value: blobs.reselectJitter, in: BlobSettings.reselectJitterRange,
                    format: { "\(Int(($0 * 100).rounded()))%" })
                LabeledSlider(
                    "Line chance", value: blobs.lineProbability, in: BlobSettings.lineProbabilityRange,
                    format: { "\(Int(($0 * 100).rounded()))%" })
                HStack {
                    TextField("Seed", value: blobs.seed, format: .number.grouping(.never))
                    Button("Shuffle") {
                        model.settings.blobs.seed = Int.random(in: BlobSettings.seedRange)
                    }
                }
            }
            .disabled(!model.settings.blobs.enabled)

            Section("Look") {
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                LabeledSlider(
                    "Line width", value: blobs.lineWidth, in: BlobSettings.lineWidthRange,
                    format: { String(format: "%.1fpx", $0) })
                Picker("Labels", selection: blobs.labels) {
                    Text("None").tag(BlobSettings.LabelStyle.none)
                    Text("ID").tag(BlobSettings.LabelStyle.id)
                    Text("Full").tag(BlobSettings.LabelStyle.full)
                }
                .pickerStyle(.segmented)
            }
            .disabled(!model.settings.blobs.enabled)

            if let error = model.saveError {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let rgb = model.settings.blobs.rgb
                return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                model.settings.blobs.color =
                    RGB(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent).hex
            })
    }

    /// Whole-number settings on a continuous slider.
    private func intBinding(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }

    private func closed(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    init(
        _ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                // No step: a stepped slider draws a tick per step, and the
                // int bindings round anyway.
                Slider(value: $value, in: range)
                Text(format(value))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}
