import SwiftUI
import Observation

@Observable
final class HomeViewModel {
    var showTrackingSheet = false
    var showHistory = false

    func startSleep() {
        showTrackingSheet = true
    }
}
