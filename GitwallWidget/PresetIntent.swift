import AppIntents
import GitwallCore
import WidgetKit

/// A preset as seen by the widget configuration UI ("Edit Widget").
struct PresetEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Preset")
    static let defaultQuery = PresetQuery()

    let id: UUID
    let name: String
    let icon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        icon = preset.icon
    }
}

struct PresetQuery: EntityQuery {
    private func presets() -> [Preset] {
        guard let container = AppGroup.containerURL() else { return [] }
        return (try? ConfigStore(directoryURL: container).load().presets) ?? []
    }

    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        presets().filter { identifiers.contains($0.id) }.map(PresetEntity.init)
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        presets().map(PresetEntity.init)
    }

    func defaultResult() async -> PresetEntity? {
        presets().first.map(PresetEntity.init)
    }
}

struct SelectPresetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Preset"
    static let description = IntentDescription("Pick which preset this widget shows. Presets are managed in the Gitwall app.")

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    init() {}

    init(preset: PresetEntity?) {
        self.preset = preset
    }
}
