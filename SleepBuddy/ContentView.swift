import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Schlafen", systemImage: "moon.fill")
                }
            SleepHistoryView()
                .tabItem {
                    Label("Verlauf", systemImage: "chart.bar.fill")
                }
            ProfilView()
                .tabItem {
                    Label("Profil", systemImage: "person.fill")
                }
        }
        .tint(.indigo)
    }
}
