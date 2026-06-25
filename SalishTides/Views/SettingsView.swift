import SwiftUI

/// App settings, presented as a standard grouped `Form` inside a
/// `NavigationStack` and shown as a sheet. Follows the iOS HIG settings
/// pattern: sections of related controls, system pickers/toggles, an inline
/// navigation title, and a single confirming **Done** action.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
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
                }

                // ── Map & Display ────────────────────────────────────────
                Section {
                    Toggle("Crosshair", isOn: $settings.showCrosshair)
                } header: {
                    Text("Map & Display")
                } footer: {
                    Text("The crosshair marks the point used for the speed readout.")
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
                    Text("The chart’s colours are tuned for daylight on the water and stay constant; this affects the app’s panels and menus.")
                }

                // ── Basemap (developer) ──────────────────────────────────
                Section {
                    Picker("Style", selection: $settings.basemap) {
                        Section("Light") {
                            ForEach(Basemap.light) { Text($0.label).tag($0) }
                        }
                        Section("Dark") {
                            ForEach(Basemap.dark) { Text($0.label).tag($0) }
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Basemap (Developer)")
                } footer: {
                    Text(MapConfig.maptilerKey.isEmpty
                         ? "Set MAPTILER_KEY in Config/Secrets.xcconfig to load these styles. Without a key, the offline stub style is shown for all options."
                         : "Switch the map’s base style to compare options. Loaded from MapTiler — requires a network connection.")
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
}
