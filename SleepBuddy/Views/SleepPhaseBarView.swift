import SwiftUI

struct SleepPhaseBarView: View {
    let phases: [SleepPhase]
    let totalDuration: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(phases.sorted { $0.startDate < $1.startDate }, id: \.startDate) { phase in
                    Rectangle()
                        .fill(phase.phaseType.color)
                        .frame(width: geometry.size.width * CGFloat(phase.duration / totalDuration))
                }
            }
        }
    }
}
