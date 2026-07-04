import SwiftUI

// MARK: - DatenschutzView

struct DatenschutzView: View {
    @Environment(\.openURL) private var openURL

    private let supportMail = "doemugerber@gmail.com"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                abschnitt(
                    icon: "mic.fill",
                    titel: "Audio bleibt auf dem Gerät",
                    text: "Die Geräusch- und Atemanalyse läuft vollständig auf deinem iPhone. Rohaudio verlässt niemals das Gerät — es werden nur anonyme Merkmale (z. B. Lautstärke, Frequenzbänder) ausgewertet."
                )

                abschnitt(
                    icon: "icloud.fill",
                    titel: "Deine iCloud, deine Daten",
                    text: "Schlafdaten werden über deine private iCloud (CloudKit) zwischen deinen Geräten synchronisiert. Optionale Geräusch-Aufnahmen (Clips) werden — wenn aktiviert — ausschließlich in deinem eigenen iCloud-Ordner gespeichert. Niemand außer dir hat Zugriff."
                )

                abschnitt(
                    icon: "heart.fill",
                    titel: "Gesundheitsdaten (HealthKit)",
                    text: "Wenn du es erlaubst, liest SleepBuddy deine Herzfrequenz aus Apple Health und schreibt deine Schlafanalyse zurück. Diese Daten bleiben auf deinem Gerät bzw. in deiner iCloud und werden nicht an Dritte weitergegeben."
                )

                abschnitt(
                    icon: "arrow.left.arrow.right",
                    titel: "Datenaustausch mit PainDiary",
                    text: "Wenn du die App PainDiary desselben Entwicklers nutzt und die Verknüpfung aktivierst, überträgt SleepBuddy eine Zusammenfassung deiner Nacht (z. B. Schlafdauer und -qualität) an PainDiary. Dieser Austausch findet ausschließlich lokal auf deinem Gerät über eine gemeinsame, geschützte App-Gruppe statt — keine Übertragung an Server oder Dritte. Du kannst die Verknüpfung jederzeit im Profil deaktivieren."
                )

                abschnitt(
                    icon: "hand.raised.fill",
                    titel: "Kein Tracking, keine Werbung",
                    text: "SleepBuddy enthält keine Werbung, kein Analyse-Tracking durch Dritte und verkauft keine Daten. Es gibt keine Nutzerkonten — deine Identität wird nicht erfasst."
                )

                abschnitt(
                    icon: "cross.case.fill",
                    titel: "Kein Medizinprodukt",
                    text: "SleepBuddy dient der Information und dem persönlichen Wohlbefinden. Die App ist kein Medizinprodukt und ersetzt keine ärztliche Diagnose oder Behandlung."
                )

                kontaktKarte

                Text("Stand: \(Date().formatted(.dateTime.month(.wide).year()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Datenschutz")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Deine Privatsphäre zuerst")
                .font(.title3.bold())
            Text("SleepBuddy ist so gebaut, dass deine sensibelsten Daten — dein Schlaf und deine Geräusche — bei dir bleiben.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func abschnitt(icon: String, titel: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(titel).font(.subheadline.bold())
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private var kontaktKarte: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Entwickler & Kontakt")
                .font(.subheadline.bold())

            LabeledContent("Entwickler") {
                Text("Dominik Gerber").foregroundStyle(.secondary)
            }
            Divider()
            Button {
                if let url = URL(string: "mailto:\(supportMail)") { openURL(url) }
            } label: {
                HStack {
                    Text("Support")
                    Spacer()
                    Text(supportMail).foregroundStyle(.indigo)
                    Image(systemName: "envelope.fill").font(.caption).foregroundStyle(.indigo)
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }
}

