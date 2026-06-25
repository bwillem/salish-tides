import SwiftUI

/// App settings, presented as a standard grouped `Form` inside a
/// `NavigationStack` and shown as a sheet. Follows the iOS HIG settings
/// pattern: sections of related controls, system pickers/toggles, an inline
/// navigation title, and a single confirming **Done** action.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NetworkMonitor.self) private var network
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
                    Toggle("Crosshair", isOn: $settings.showCrosshair)
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
                    Text("Standard works fully offline. Ocean and Satellite stream from MapTiler when online and are cached for offline use over waters you've viewed.")
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
            HStack {
                Text(style.label)
                    .foregroundStyle(selectable ? .primary : .secondary)
                Spacer()
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
                Text("Salish Tides is a fully offline planning aid. It is **not** an official source for navigation. Always consult official charts and current tables.")
                    .font(.callout)
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
