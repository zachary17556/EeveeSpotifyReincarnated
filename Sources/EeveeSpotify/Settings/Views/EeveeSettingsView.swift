import SwiftUI
import UIKit
import EeveeSpotifyC

struct EeveeSettingsView: View {
    let navigationController: UINavigationController

    @State private var hasShownCommonIssuesTip = UserDefaults.hasShownCommonIssuesTip
    @State private var isClearingData = false
    @State private var isPresentingDevNoteSheet = false
    @State private var isAudioRecording = false
    @State private var audioRecorderMessage: String?
    @State private var keepSession = false
    @State private var waitForTrackStart = false
    @State private var exportFormats: Set<String> = []
    @State private var recorderLatencyMs = 0
    @State private var captureMethod = "auto"
    @State private var captureMethodActive = "unknown"
    @State private var captureFallbackReason: String? = nil

    private func toggleAudioRecording() {
        if isAudioRecording {
            EeveeAudioRecorderStop()
            isAudioRecording = false
            audioRecorderMessage = "Recording stopped. Check Documents/Recordings."
        } else if EeveeAudioRecorderStart() {
            isAudioRecording = true
            audioRecorderMessage = "Recording started."
        } else {
            audioRecorderMessage = "Could not start recording."
        }
    }

    private func loadRecorderSettings() {
        keepSession = EVSettingBool("keepSession", false)
        waitForTrackStart = EVSettingBool("waitForTrackStart", false)
        recorderLatencyMs = EVSettingInt("metaLatencyMs", 0)
        captureMethod = EVSettingString("captureMethod", "auto") ?? "auto"
        captureMethodActive = EVCaptureMethodActive() ?? "unknown"
        captureFallbackReason = EVCaptureFallbackReason()

        let saved = EVSettingString("exportFormats", "") ?? ""
        exportFormats = Set(saved.split(separator: ",").map(String.init))
    }

    private func exportFormatBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { exportFormats.contains(key) },
            set: { enabled in
                if enabled {
                    exportFormats.insert(key)
                } else {
                    exportFormats.remove(key)
                }

                let order = ["aac", "alac", "aiff", "flac"]
                let saved = order.filter { exportFormats.contains($0) }
                EVSetSettingString("exportFormats", saved.joined(separator: ","))
            }
        )
    }

    private func adjustRecorderLatency(by delta: Int) {
        recorderLatencyMs += delta
        EVSetSettingInt("metaLatencyMs", recorderLatencyMs)
    }

    private func exportDebugLog() {
        guard let data = FileManager.default.contents(atPath: EeveeLog.path), !data.isEmpty else {
            PopUpHelper.showPopUp(message: "no_debug_log_found".localized, buttonText: "no_debug_log_found_ok".localized)
            return
        }
        let share = UIActivityViewController(activityItems: [URL(fileURLWithPath: EeveeLog.path)], applicationActivities: nil)
        if let popover = share.popoverPresentationController, let view = navigationController.view {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        WindowHelper.shared.present(share)
    }

    private func clearDebugLog() {
        EeveeLog.clear()
        writeDebugLog("Log cleared by user")
        PopUpHelper.showPopUp(message: "debug_log_cleared".localized, buttonText: "debug_log_cleared_ok".localized)
    }

    // Ko-fi is where the tweak is funded from. It is the only place we ask for
    // money, so the button lives with the other "about" style rows near the
    // bottom of the page rather than up in the feature groups.
    private static let supportURL = URL(string: "https://ko-fi.com/jaydenjcpy")!

    private func openSupportPage() {
        UIApplication.shared.open(Self.supportURL)
    }

    private func wipe(_ work: @escaping () -> Void) {
        isClearingData = true
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { exitApplication() }
        }
    }

    private static let groups: [SettingsGroup] = [
        SettingsGroup(key: "settings_group_listening", entries: [
            SettingsEntry(key: "patching", icon: "hammer.fill", color: .orange) { AnyView(EeveePatchingSettingsView()) },
            SettingsEntry(key: "lyrics", icon: "quote.bubble.fill", color: .blue) { AnyView(EeveeLyricsSettingsView()) },
            SettingsEntry(key: "sponsorblock", icon: "forward.end.fill", color: .red) { AnyView(SponsorBlockSettingsView()) },
        ]),
        SettingsGroup(key: "settings_group_looks", entries: [
            SettingsEntry(key: "appearance", icon: "drop.fill", color: Color(hex: "#30B0C7")) { AnyView(AppearanceSettingsView()) },
            SettingsEntry(key: "customization", icon: "paintpalette.fill", color: Color(hex: "#64D2FF")) { AnyView(EeveeUISettingsView()) },
            SettingsEntry(key: "appIcon", icon: "app.badge.fill", color: .pink) { AnyView(EeveeAppIconPickerView()) },
        ]),
        SettingsGroup(key: "settings_group_advanced", entries: [
            SettingsEntry(key: "spotify_features", icon: "switch.2", color: .green) { AnyView(SpotifyFeaturesView()) },
            SettingsEntry(key: "flags", icon: "flag.fill", color: Color(hex: "#5E5CE6")) { AnyView(FlagBrowserView()) },
            SettingsEntry(key: "experiments", icon: "sparkle", color: .purple) { AnyView(EeveeExperimentsSettingsView()) },
            SettingsEntry(key: "miscellaneous", icon: "ellipsis.circle.fill", color: .gray) { AnyView(EeveeMiscellaneousSettingsView()) },
        ]),
    ]

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
        SettingsNavigator.navigationController = navigationController
    }

    var body: some View {
        List {
            Section {
                SettingsHero()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            EeveeSettingsVersionView()

            if !hasShownCommonIssuesTip {
                CommonIssuesTipView(
                    onDismiss: {
                        hasShownCommonIssuesTip = true
                        UserDefaults.hasShownCommonIssuesTip = true
                    }
                )
            }

            ForEach(Self.groups) { group in
                SettingsGroupSection(group: group) { entry in
                    SettingsNavigator.push(entry.make(), title: entry.key.localized)
                }
            }

            Section(
                header: Text("Audio Recording"),
                footer: Text("Recordings are saved under Documents/Recordings. Export formats create additional files from the captured session.")
            ) {
                Button(action: toggleAudioRecording) {
                    Label(
                        isAudioRecording ? "Stop Recording" : "Start Recording",
                        systemImage: isAudioRecording ? "stop.circle.fill" : "record.circle"
                    )
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Recorder status")
                    Spacer(minLength: 12)
                    Text(EeveeRecorderStatusLine())
                        .font(.footnote)
                        .foregroundColor(isAudioRecording ? .red : .secondary)
                        .multilineTextAlignment(.trailing)
                }

                if let message = audioRecorderMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Picker("Capture method", selection: Binding(
                    get: { captureMethod },
                    set: { newValue in
                        guard newValue == "audiounit" || newValue == "alternate" else {
                            audioRecorderMessage = "// Unblocked alternate capture"
                            return
                        }
                        captureMethod = newValue
                        EVSetSettingString("captureMethod", newValue)
                        captureMethodActive = EVCaptureMethodActive() ?? "unknown"
                        captureFallbackReason = EVCaptureFallbackReason()
                    }
                )) {
                    Text("Auto (Hook)").tag("auto")
                Text("Converter (Fishhook)").tag("converter")
                Text("Pump (Inline Hook)").tag("pump")
                Text("AudioUnitRender").tag("audiounit")
                Text("Alternate (RenderNotify)").tag("alternate")

                }
                HStack {
                    Text("Active method").foregroundColor(.secondary)
                    Spacer()
                    Text(captureMethodActive).foregroundColor(.secondary)
                }
                if let reason = captureFallbackReason, !reason.isEmpty {
                    Text("Fallback: \(reason)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Toggle("Keep full session WAV", isOn: Binding(
                    get: { keepSession },
                    set: {
                        keepSession = $0
                        EVSetSettingBool("keepSession", $0)
                    }
                ))

                Toggle("Wait for next track beginning", isOn: Binding(
                    get: { waitForTrackStart },
                    set: {
                        waitForTrackStart = $0
                        EVSetSettingBool("waitForTrackStart", $0)
                    }
                ))

                Text("Additional export formats")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Toggle("AAC (.m4a)", isOn: exportFormatBinding("aac"))
                Toggle("ALAC lossless (.m4a)", isOn: exportFormatBinding("alac"))
                Toggle("AIFF (.aiff)", isOn: exportFormatBinding("aiff"))
                Toggle("FLAC (.flac)", isOn: exportFormatBinding("flac"))

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Track-start latency")
                        Text("Adjusts metadata split timing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button {
                        adjustRecorderLatency(by: -25)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Decrease latency by 25 milliseconds")

                    Text("\(recorderLatencyMs) ms")
                        .frame(minWidth: 68)

                    Button {
                        adjustRecorderLatency(by: 25)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel("Increase latency by 25 milliseconds")
                }

                Button {
                    EeveeRecorderPresentDebugPanel()
                } label: {
                    Label("Recorder Diagnostics", systemImage: "stethoscope")
                }
            }

            Section {
                Button {
                    isPresentingDevNoteSheet = true
                } label: {
                    HStack {
                        Image(systemName: "person.fill.questionmark")
                        Text("\("developer_note".localized)...")
                    }
                }
            }
            .sheet(isPresented: $isPresentingDevNoteSheet) {
                EeveeDevNoteView()
            }

            Section {
                Button(action: openSupportPage) {
                    SettingsLabel(
                        title: "support_the_project".localized,
                        subtitle: "support_the_project_description".localized,
                        icon: "cup.and.saucer.fill",
                        color: Color(hex: "#FF5E5B")
                    )
                }
            }

            Section(header: Text("troubleshooting".localized), footer: Text("debug_section_footer".localized)) {
                Toggle(
                    "debug_logging".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.debugLoggingEnabled },
                        set: { UserDefaults.debugLoggingEnabled = $0 }
                    )
                )

                Button(action: exportDebugLog) {
                    SettingsLabel(title: "export_debug_log".localized, icon: "square.and.arrow.up", color: .blue)
                }
                Button(action: clearDebugLog) {
                    SettingsLabel(title: "clear_debug_log".localized, icon: "trash.fill", color: .gray)
                }
            }

            Section(header: Text("reset_section".localized), footer: Text("reset_section_footer".localized)) {
                Button {
                    confirmDestructive(title: "reset_data".localized, message: "reset_data_description".localized, confirm: "reset_data".localized) {
                        wipe { OfflineHelper.resetData(clearCaches: true) }
                    }
                } label: {
                    SettingsLabel(title: "reset_data".localized, subtitle: "reset_data_subtitle".localized, icon: "arrow.counterclockwise", color: .orange)
                }
                Button {
                    confirmDestructive(title: "resetButtonTitle".localized, message: "resetFooter".localized, confirm: "resetButtonTitle".localized) {
                        wipe { FullResetHelper.wipeSpotifyState() }
                    }
                } label: {
                    SettingsLabel(title: "resetButtonTitle".localized, subtitle: "full_reset_subtitle".localized, icon: "exclamationmark.triangle.fill", color: .red)
                }
            }
            .disabled(isClearingData)

            SpacerView()
        }
        .eeveeSettingsStyle()

        .animation(.default, value: isClearingData)
        .animation(.default, value: hasShownCommonIssuesTip)

        .onAppear {
            WindowHelper.shared.overrideUserInterfaceStyle(.dark)
            isAudioRecording = EeveeAudioRecorderIsRecording()
            loadRecorderSettings()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSNotification.Name.EeveeRecorderStateDidChange
        )) { _ in
            isAudioRecording = EeveeAudioRecorderIsRecording()
            audioRecorderMessage = EeveeRecorderStatusLine()
        }
    }
}
