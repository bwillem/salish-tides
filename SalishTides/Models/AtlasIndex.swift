import Foundation

struct AtlasMetadata: Decodable, Sendable {
    let source: String
    let author: String
    let model: String
    let constituents: [String]
    let reference_station: String
}

struct RegionInfo: Decodable, Sendable {
    let name: String
    let landmark: String
}

struct ChartBounds: Decodable, Sendable, Equatable {
    let lat_min: Double
    let lat_max: Double
    let lon_min: Double
    let lon_max: Double

    func intersects(_ other: ChartBounds) -> Bool {
        lat_max > other.lat_min && lat_min < other.lat_max &&
        lon_max > other.lon_min && lon_min < other.lon_max
    }
}

struct ChartEntry: Decodable, Sendable {
    let map_number: Int
    let region: String
    let bounds: ChartBounds
    let vector_count: Int
}

struct AtlasIndex: Decodable, Sendable {
    let index: [ChartEntry]
    // Cosmetic provenance — present in Vol 1's index, omitted from the lean
    // Vol 2-4 index files. Only `index` drives viewport region culling.
    let metadata: AtlasMetadata?
    let regions: [String: RegionInfo]?

    static let empty = AtlasIndex(index: [], metadata: nil, regions: nil)

    static func load(resource: String) throws -> AtlasIndex {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AtlasIndex.self, from: data)
    }

    func regions(forChart chart: Int, intersecting viewport: ChartBounds? = nil) -> [String] {
        let entries = index.filter { $0.map_number == chart }
        guard let vp = viewport else { return entries.map(\.region) }
        return entries.filter { $0.bounds.intersects(vp) }.map(\.region)
    }
}
