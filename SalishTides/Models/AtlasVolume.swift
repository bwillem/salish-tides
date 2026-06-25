import Foundation

struct VolumeSpec: Sendable {
    let id: Int
    let lookupResource: String
    let mapSubdirectory: String
    let maxChart: Int
    let regions: [String]
    let bounds: ChartBounds
    let atlasIndexResource: String?
}

// Geographic bounds are conservative (slightly padded) so viewport-intersection
// checks don't drop a volume when the user is near the edge.
let atlasVolumes: [VolumeSpec] = [
    VolumeSpec(
        id: 1,
        lookupResource: "atlas_lookup_2026",
        mapSubdirectory: "maps",
        maxChart: 43,
        regions: ["A", "B", "C", "D", "E", "F", "G", "H"],
        bounds: ChartBounds(lat_min: 47.9, lat_max: 49.5, lon_min: -124.0, lon_max: -122.3),
        atlasIndexResource: "atlas_index"
    ),
    VolumeSpec(
        id: 2,
        lookupResource: "atlas_lookup_vol2_2026",
        mapSubdirectory: "maps_vol2",
        maxChart: 64,
        regions: ["A", "B", "C", "D", "E", "F"],
        bounds: ChartBounds(lat_min: 47.0, lat_max: 48.45, lon_min: -123.25, lon_max: -122.15),
        atlasIndexResource: "atlas_index_vol2"
    ),
    VolumeSpec(
        // Vol 3 uses the same tidal lookup as Vol 1 (Point Atkinson reference, 43 charts)
        // but covers a different geographic area (Desolation Sound / Johnstone Strait).
        id: 3,
        lookupResource: "atlas_lookup_2026",
        mapSubdirectory: "maps_vol3",
        maxChart: 43,
        regions: ["A", "B", "C", "D", "E", "F", "G", "H"],
        bounds: ChartBounds(lat_min: 49.1, lat_max: 50.65, lon_min: -125.4, lon_max: -123.6),
        atlasIndexResource: "atlas_index_vol3"
    ),
    VolumeSpec(
        id: 4,
        lookupResource: "atlas_lookup_vol4_2026",
        mapSubdirectory: "maps_vol4",
        maxChart: 69,
        regions: ["A", "B", "C", "D", "E", "F", "G", "H"],
        bounds: ChartBounds(lat_min: 49.85, lat_max: 51.15, lon_min: -128.2, lon_max: -125.0),
        atlasIndexResource: "atlas_index_vol4"
    ),
]
