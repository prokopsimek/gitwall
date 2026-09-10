import SwiftUI
import WidgetKit

@main
struct GitwallWidgetBundle: WidgetBundle {
    var body: some Widget {
        CounterWidget()
        ListWidget()
        BoardWidget()
        WideBoardWidget()
    }
}
