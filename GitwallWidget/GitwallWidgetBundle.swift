import SwiftUI
import WidgetKit

@main
struct GitwallWidgetBundle: WidgetBundle {
    var body: some Widget {
        GitwallWidget()
        GitwallLegacyWidget()
    }
}
