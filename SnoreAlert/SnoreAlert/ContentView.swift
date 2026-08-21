import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var monitor: SnoreAudioMonitor

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                    confidenceRow
                }

                Section {
                    Button {
                        if monitor.isListening {
                            monitor.stop()
                        } else {
                            Task { await monitor.start() }
                        }
                    } label: {
                        Label(monitor.isListening ? "Stop" : "Start nocne pocuvanie", systemImage: monitor.isListening ? "stop.fill" : "moon.zzz.fill")
                    }

                    Button {
                        monitor.sendTestNotification()
                    } label: {
                        Label("Test vibracie na Garmin", systemImage: "applewatch.radiowaves.left.and.right")
                    }
                    .disabled(!monitor.isListening)
                }

                Section("Nastavenia") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Citlivost")
                            Spacer()
                            Text(settings.sensitivity, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: sensitivityBinding, in: 0.45...0.92, step: 0.01)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Interval notifikacii")
                            Spacer()
                            Text("\(Int(settings.repeatInterval)) s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: repeatIntervalBinding, in: 2...10, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Zastavit po tichu")
                            Spacer()
                            Text("\(Int(settings.stopDelay)) s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: stopDelayBinding, in: 2...12, step: 1)
                    }
                }

                Section("Dnesne udalosti") {
                    if monitor.events.isEmpty {
                        Text("Zatial nic zachytene.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(monitor.events) { event in
                            VStack(alignment: .leading) {
                                Text(event.startedAt, style: .time)
                                    .font(.headline)
                                Text("Trvanie \(Int(event.duration)) s, maximum \(Int(event.peakConfidence * 100)) %")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("SnoreAlert")
        }
    }

    private var statusRow: some View {
        HStack {
            Image(systemName: monitor.isSnoring ? "waveform.badge.exclamationmark" : "waveform")
                .foregroundStyle(monitor.isSnoring ? .orange : .blue)

            VStack(alignment: .leading) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var confidenceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Istota detekcie")
                Spacer()
                Text("\(Int(monitor.confidence * 100)) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(monitor.confidence))

            HStack {
                Text("\(Int(monitor.decibels)) dB")
                Spacer()
                Text("Low band \(Int(monitor.lowBandRatio * 100)) %")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch monitor.state {
        case .idle:
            return "Pripravene"
        case .starting:
            return "Spustam pocuvanie"
        case .listening:
            return monitor.isSnoring ? "Chrapanie zachytene" : "Pocuvam"
        case .failed:
            return "Nepodarilo sa spustit"
        }
    }

    private var statusSubtitle: String {
        switch monitor.state {
        case .idle:
            return "Pred spanim stlac Start a zamkni iPhone."
        case .starting:
            return "Kontrolujem mikrofon a notifikacie."
        case .listening:
            return monitor.isSnoring ? "Posielam tiche notifikacie do hodiniek." : "Mikrofon bezi aj pri zamknutom displeji."
        case .failed(let message):
            return message
        }
    }

    private var sensitivityBinding: Binding<Float> {
        Binding(
            get: { settings.sensitivity },
            set: { settings.sensitivity = $0 }
        )
    }

    private var repeatIntervalBinding: Binding<Double> {
        Binding(
            get: { settings.repeatInterval },
            set: { settings.repeatInterval = $0 }
        )
    }

    private var stopDelayBinding: Binding<Double> {
        Binding(
            get: { settings.stopDelay },
            set: { settings.stopDelay = $0 }
        )
    }
}

#Preview {
    let settings = AppSettings()
    ContentView()
        .environmentObject(settings)
        .environmentObject(SnoreAudioMonitor(settings: settings))
}

