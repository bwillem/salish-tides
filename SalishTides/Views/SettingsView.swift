import SwiftUI

/// App settings, presented as a standard grouped `Form` inside a
/// `NavigationStack` and shown as a sheet. Follows the iOS HIG settings
/// pattern: sections of related controls, system pickers/toggles, an inline
/// navigation title, and a single confirming **Done** action.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NetworkMonitor.self) private var network
    @Environment(OfflineMapManager.self) private var offline
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                // ── Units ────────────────────────────────────────────────
                Section("Units") {
                    Picker("Current speed", selection: $settings.speedUnit) {
                        ForEach(SpeedUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    Picker("Tide height", selection: $settings.heightUnit) {
                        ForEach(HeightUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    Picker("Clock", selection: $settings.clockFormat) {
                        ForEach(ClockFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                }

                // ── Map & Display ────────────────────────────────────────
                Section {
                    Picker("Current", selection: $settings.currentStyle) {
                        ForEach(CurrentStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Map & Display")
                } footer: {
                    Text("Particles animate the flow of the current; Arrows show it statically. Arrows are used automatically when Reduce Motion or Low Power Mode is on. The crosshair marks the point used for the speed readout.")
                }

                // ── Appearance ───────────────────────────────────────────
                Section {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Switches the full Day / Night theme — basemap, panels, and current-arrow colours. System follows your device setting.")
                }

                // ── Map Style ────────────────────────────────────────────
                Section {
                    ForEach(Basemap.allCases) { style in
                        mapStyleRow(style)
                    }
                } header: {
                    Text("Map Style")
                } footer: {
                    Text("Standard works fully offline. Selecting Ocean while online downloads it for offline use across the region. Satellite streams online only.")
                }

                // ── Live Data ────────────────────────────────────────────
                Section {
                    Toggle("Offline only", isOn: $settings.offlineOnly)
                } header: {
                    Text("Live Data")
                } footer: {
                    Text("When online, real-time current and water-level forecasts from the SalishSeaCast model (UBC) are downloaded in the background and shown for the next ~36 hours. Without them — offline, or beyond the forecast — currents come from a bundled tidal model of the same waters (marked “Offline model”): astronomical tide only, no weather or river effects. Turn on Offline Only to use bundled data exclusively.")
                }

                // ── About ────────────────────────────────────────────────
                Section("About") {
                    LabeledContent("Version", value: Self.appVersion)
                    NavigationLink("Data Sources") { DataSourcesView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// A Map Style row: tappable + checkmark when selectable; greyed with an
    /// "Online only" caption when it needs network it doesn't have.
    @ViewBuilder
    private func mapStyleRow(_ style: Basemap) -> some View {
        let selectable = settings.isSelectable(style, online: network.isOnline)
        Button {
            settings.basemap = style
        } label: {
            HStack(spacing: Spacing.sm) {
                Text(style.label)
                    .foregroundStyle(selectable ? .primary : .secondary)
                Spacer()
                offlineStatus(style)
                if settings.basemap == style {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                } else if !selectable {
                    Text("Online only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .disabled(!selectable)
    }

    /// Offline-download indicator for a downloadable style: progress while a pack
    /// downloads, a "saved" badge once it's available offline, a warning on
    /// failure. Nothing for styles that aren't pre-downloaded.
    @ViewBuilder
    private func offlineStatus(_ style: Basemap) -> some View {
        switch offline.state(for: style) {
        case .downloading(let fraction):
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("\(Int(fraction * 100))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading \(Int(fraction * 100)) percent")
        case .ready:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Saved offline")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Download failed")
        case .none:
            EmptyView()
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}

/// Attribution for the underlying tide and current data. Reachable from
/// Settings → About; surfacing data provenance in-app is both good practice
/// for a navigation tool and expected at App Store review.
private struct DataSourcesView: View {
    var body: some View {
        Form {
            Section {
                Text("Salish Tides is an offline-first planning aid. It is **not** an official source for navigation. Always consult official charts and current tables.")
                    .font(.callout)
            }

            Section("Live Forecasts") {
                LabeledContent("Model", value: "SalishSeaCast · UBC")
                Text("When online, real-time surface-current and water-level forecasts from the SalishSeaCast NEMO ocean model (UBC Earth, Ocean & Atmospheric Sciences) are shown in place of the sources below, out to roughly 36 hours ahead. Model water levels are aligned to each station's datum against its official predictions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Tidal Currents") {
                LabeledContent("Atlas", value: "Salish Sea Tidal Current Atlas")
                Text("Current vectors are extracted from the four-volume Salish Sea Tidal Current Atlas, covering tidal currents across the Salish Sea (BC / WA).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Tide Heights") {
                LabeledContent("United States", value: "NOAA CO-OPS")
                LabeledContent("Canada", value: "CHS IWLS")
                Text("Tide-height predictions come from NOAA Tides & Currents (MLLW datum) and the Canadian Hydrographic Service (Chart Datum). Heights are above each station’s own datum.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Basemap") {
                Text("Map rendering by MapLibre.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Data Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
        .environment(AppSettings())
        .environment(NetworkMonitor())
}
