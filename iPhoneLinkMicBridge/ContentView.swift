import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = MicBridge()
    @State private var port = "9878"

    var body: some View {
        NavigationStack {
            Form {
                Section("PC Microphone → iPhone") {
                    Text("The PC sends 48 kHz mono PCM16 over the local network. The existing iPhone → PC audio path is not modified.")
                        .font(.footnote)

                    TextField("UDP port", text: $port)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(bridge.connected ? "Stop PC Mic Receiver" : "Start PC Mic Receiver") {
                        if bridge.connected {
                            bridge.stopNetwork()
                        } else if let p = UInt16(port), p > 0 {
                            bridge.connect(port: p)
                        }
                    }

                    if bridge.connected {
                        Label("Listening on UDP \(port)", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                    }
                }

                Section("Microphone Injection") {
                    if #available(iOS 18.2, *) {
                        Toggle("Add PC mic to supported calls", isOn: Binding(
                            get: { bridge.injectionEnabled },
                            set: { value in
                                Task { await bridge.setInjectionEnabled(value) }
                            }
                        ))
                        .disabled(!bridge.connected)

                        Label(
                            bridge.callActive
                                ? "Supported call / injection stream detected"
                                : "No supported active call detected",
                            systemImage: bridge.callActive
                                ? "phone.connection.fill"
                                : "phone.slash"
                        )

                        Text(bridge.injectionAvailable
                             ? "Injection is currently available."
                             : "Start a supported Phone/FaceTime/VoIP call first, then enable injection.")
                            .font(.footnote)

                        Text("If iOS says the service is disabled, enable Settings → Accessibility → Audio & Visual → Add Audio in Calls → Allow Apps to Add Audio in Calls.")
                            .font(.footnote)
                    } else {
                        Text("Microphone injection requires iOS 18.2 or later.")
                            .font(.footnote)
                    }
                }

                Section("Live Status") {
                    Label(
                        bridge.connected ? "PC mic receiver connected" : "PC mic receiver stopped",
                        systemImage: bridge.connected
                            ? "checkmark.circle.fill"
                            : "xmark.circle"
                    )

                    Text(bridge.message)

                    HStack {
                        Text("Packets received")
                        Spacer()
                        Text("\(bridge.packetsReceived)")
                            .monospacedDigit()
                    }

                    HStack {
                        Text("Packets dropped")
                        Spacer()
                        Text("\(bridge.packetsDropped)")
                            .monospacedDigit()
                    }
                }

                Section("Test") {
                    Text("First test the receiver with the iPhone app open. Then start PC Microphone → iPhone in the Windows app. Packets received should increase continuously while you speak.")
                        .font(.footnote)

                    Text("Apple's microphone injection API adds app audio to supported call/VoIP microphone streams; it is not a universal virtual microphone for every iPhone app or game.")
                        .font(.footnote)
                }
            }
            .navigationTitle("iPhone Link Mic")
        }
    }
}
