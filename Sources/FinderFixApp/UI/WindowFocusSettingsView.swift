import AppKit
import FinderFixCore
import SwiftUI
import UniformTypeIdentifiers

struct WindowFocusSettingsView: View {
    @ObservedObject var preferencesStore: PreferencesStore
    @ObservedObject var appViewModel: AppViewModel

    @State private var applicationSelectionMessage: String?

    var body: some View {
        let applications: [ExcludedApplication] = excludedApplications
        return ScrollView {
            VStack(alignment: .leading, spacing: ArcaneTokens.sectionSpacing) {
                ArcaneSectionHeader(
                    title: "Focus Follows Pointer",
                    detail: "Bring a supported window forward after the pointer hovers over it."
                )

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Focus a window after hovering over it",
                            isOn: focusBinding(\.isEnabled)
                        )
                        .font(.headline)

                        Text("This feature is off by default. When enabled, FinderFix brings the window and its app forward without clicking anything.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Divider()

                        Group {
                            LabeledContent("Focus delay") {
                                HStack(spacing: 10) {
                                    Slider(
                                        value: activationDelayBinding,
                                        in: 0...1_000,
                                        step: 50
                                    )
                                    .frame(width: 220)

                                    Text(activationDelayLabel)
                                        .monospacedDigit()
                                        .frame(width: 84, alignment: .trailing)
                                }
                            }

                            Toggle(
                                "Wait until the pointer stops moving",
                                isOn: focusBinding(\.requirePointerStop)
                            )

                            Picker(
                                "Pause while holding",
                                selection: focusBinding(\.pauseModifier)
                            ) {
                                ForEach(WindowFocusPauseModifier.allCases, id: \.self) { modifier in
                                    Text(modifier.title).tag(modifier)
                                }
                            }
                            .pickerStyle(.menu)

                            Text(pauseModifierDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .disabled(!preferencesStore.preferences.windowFocus.isEnabled)
                    }
                }

                if preferencesStore.preferences.windowFocus.isEnabled,
                   !appViewModel.accessibilityTrusted {
                    ArcaneCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Accessibility Required", systemImage: "hand.raised.fill")
                                .font(.headline)
                            Text("FinderFix needs Accessibility permission to identify and raise the window beneath the pointer. Pointer positions are processed locally and are never stored; FinderFix does not read window text or press controls.")
                                .foregroundStyle(.secondary)
                            Button("Open Accessibility Settings") {
                                appViewModel.requestAccessibility()
                            }
                            .buttonStyle(ArcanePrimaryButtonStyle())
                        }
                    }
                }

                if case let .unavailable(message) = appViewModel.windowFocusRuntimeState,
                   preferencesStore.preferences.windowFocus.isEnabled {
                    ArcaneCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Window Focus Needs Attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(ArcaneTokens.warning)
                            Text(message)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Excluded Apps")
                                .font(.headline)
                            Text("Windows from these apps will never be focused by pointer movement.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if applications.isEmpty {
                            Text("No apps are excluded.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(applications) { application in
                                    ExcludedApplicationRow(
                                        application: application,
                                        remove: {
                                            removeExcludedApplication(application.bundleIdentifier)
                                        }
                                    )
                                    if application.id != applications.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }

                        Button("Add Application…") {
                            chooseExcludedApplications()
                        }
                        .disabled(
                            applications.count >= WindowFocusSettings.maximumExcludedApplications
                        )

                        if let applicationSelectionMessage {
                            Label(applicationSelectionMessage, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .arcaneSettingsPage()
        }
    }

    private var excludedApplications: [ExcludedApplication] {
        preferencesStore.preferences.windowFocus.excludedApplicationBundleIdentifiers.map {
            ExcludedApplication.resolve(bundleIdentifier: $0)
        }
    }

    private var activationDelayBinding: Binding<Double> {
        Binding(
            get: {
                Double(preferencesStore.preferences.windowFocus.activationDelayMilliseconds)
            },
            set: { value in
                preferencesStore.preferences.windowFocus.activationDelayMilliseconds = Int(
                    value.rounded()
                )
            }
        )
    }

    private var activationDelayLabel: String {
        let milliseconds: Int = preferencesStore.preferences.windowFocus.activationDelayMilliseconds
        return milliseconds == 0 ? "Immediately" : "\(milliseconds) ms"
    }

    private var pauseModifierDetail: String {
        switch preferencesStore.preferences.windowFocus.pauseModifier {
        case .control:
            "Hold Control to prevent focus changes temporarily."
        case .option:
            "Hold Option to prevent focus changes temporarily."
        case .off:
            "No modifier key will pause pointer focus."
        }
    }

    private func focusBinding<Value>(
        _ keyPath: WritableKeyPath<WindowFocusSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferencesStore.preferences.windowFocus[keyPath: keyPath] },
            set: { value in
                preferencesStore.preferences.windowFocus[keyPath: keyPath] = value
            }
        )
    }

    private func chooseExcludedApplications() {
        let panel: NSOpenPanel = NSOpenPanel()
        panel.title = "Choose Apps to Exclude"
        panel.prompt = "Exclude Apps"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]

        guard panel.runModal() == .OK else { return }

        var identifiers: [String] = preferencesStore.preferences.windowFocus
            .excludedApplicationBundleIdentifiers
        var comparisonIdentifiers: Set<String> = Set(identifiers.map { $0.lowercased() })
        var addedCount: Int = 0
        var invalidCount: Int = 0
        var overflowCount: Int = 0

        for url in panel.urls {
            guard let bundleIdentifier: String = Bundle(url: url)?.bundleIdentifier,
                  !bundleIdentifier.isEmpty else {
                invalidCount += 1
                continue
            }

            let comparisonIdentifier: String = bundleIdentifier.lowercased()
            guard comparisonIdentifiers.insert(comparisonIdentifier).inserted else { continue }
            guard identifiers.count < WindowFocusSettings.maximumExcludedApplications else {
                overflowCount += 1
                continue
            }
            identifiers.append(bundleIdentifier)
            addedCount += 1
        }

        preferencesStore.preferences.windowFocus.excludedApplicationBundleIdentifiers = identifiers

        if overflowCount > 0 {
            applicationSelectionMessage = "FinderFix supports up to \(WindowFocusSettings.maximumExcludedApplications) excluded apps."
        } else if invalidCount > 0 {
            applicationSelectionMessage = "Some selections did not identify a macOS application."
        } else if addedCount == 0, !panel.urls.isEmpty {
            applicationSelectionMessage = "The selected apps are already excluded."
        } else {
            applicationSelectionMessage = nil
        }
    }

    private func removeExcludedApplication(_ bundleIdentifier: String) {
        preferencesStore.preferences.windowFocus.excludedApplicationBundleIdentifiers.removeAll {
            $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
        applicationSelectionMessage = nil
    }
}

private struct ExcludedApplication: Identifiable {
    let bundleIdentifier: String
    let displayName: String
    let icon: NSImage

    var id: String { bundleIdentifier.lowercased() }

    static func resolve(bundleIdentifier: String) -> ExcludedApplication {
        guard let applicationURL: URL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return ExcludedApplication(
                bundleIdentifier: bundleIdentifier,
                displayName: bundleIdentifier,
                icon: fallbackIcon
            )
        }

        let bundle: Bundle? = Bundle(url: applicationURL)
        let displayName: String = (bundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: applicationURL.path)

        return ExcludedApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            icon: NSWorkspace.shared.icon(forFile: applicationURL.path)
        )
    }

    private static var fallbackIcon: NSImage {
        NSImage(
            systemSymbolName: "app",
            accessibilityDescription: nil
        ) ?? NSImage(size: NSSize(width: 32, height: 32))
    }
}

private struct ExcludedApplicationRow: View {
    let application: ExcludedApplication
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: application.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(application.displayName)
                    .font(.callout.weight(.medium))
                Text(application.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("Remove", role: .destructive, action: remove)
        }
        .padding(.vertical, 8)
    }
}
