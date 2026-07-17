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

                // ── Currents ─────────────────────────────────────────────
                Section("Currents") {
                    Picker("Current", selection: $settings.currentStyle) {
                        ForEach(CurrentStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // ── Appearance ───────────────────────────────────────────
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // ── Map Style ────────────────────────────────────────────
                Section {
                    ForEach(Basemap.allCases.filter(\.isAvailable)) { style in
                        mapStyleRow(style)
                    }
                } header: {
                    Text("Map Style")
                } footer: {
                    Text("Standard works fully offline. Satellite streams online only, caching the areas you view.")
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
                if settings.basemap == style {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                } else if !selectable {
                    // "Online only" when it's the connection that's missing;
                    // "Unavailable" when the build has no MapTiler key at all
                    // (so it can never stream, online or not).
                    Text(MapConfig.hasMaptilerKey ? "Online only" : "Unavailable")
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
                LabeledContent("Salish Sea", value: "SalishSeaCast · UBC")
                LabeledContent("North Coast", value: "WebTide · DFO")
                Text("Offline currents are synthesized on device from tidal harmonic constituents: the Salish Sea from a year of the SalishSeaCast NEMO model (UBC Earth, Ocean & Atmospheric Sciences), and the outer coast north to Southeast Alaska from the WebTide ne_pac4 model (Fisheries and Oceans Canada). Tide-driven flow only, without weather effects.")
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
                Text("Map rendering by MapLibre. Offline map data © OpenStreetMap contributors (ODbL). Online Ocean and Satellite styles © MapTiler and their data providers.")
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
