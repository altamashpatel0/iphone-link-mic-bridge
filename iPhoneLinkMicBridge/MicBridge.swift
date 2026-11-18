import Foundation
import AVFAudio
import Network
import Combine

/// Receives 48 kHz mono PCM16 from the Windows host and exposes it as app audio.
/// On iOS 18.2+, spoken-audio injection can add this app audio to supported calls.
///
/// IMPORTANT:
/// - This companion app does not modify the existing iPhone -> PC audio path.
/// - It does not replace the iPhone's physical microphone.
/// - UDP reception happens off the main thread; audio scheduling/state updates are
///   marshalled onto the MainActor.
@MainActor
final class MicBridge: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var injectionAvailable = false
    @Published private(set) var injectionEnabled = false
    @Published private(set) var callActive = false
    @Published private(set) var packetsReceived: UInt64 = 0
    @Published private(set) var packetsDropped: UInt64 = 0
    @Published private(set) var message = "Ready"

    private let networkQueue = DispatchQueue(
        label: "com.iphone-link.mic-bridge.network",
        qos: .userInteractive
    )
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 1,
        interleaved: true
    )!
    private var audioConfigured = false

    // Keep a small startup jitter buffer. 3 x 20 ms gives the network a little
    // room without creating the large latency that an unbounded queue can cause.
    private let prebufferPacketCount = 3
    private var prebuffer: [AVAudioPCMBuffer] = []
    private var playbackStarted = false

    private var expectedSequence: UInt32?
    private var lastPacketTime = Date.distantPast

    init() {
        if #available(iOS 18.2, *) {
            observeMicrophoneInjectionAvailability()
        }
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - Audio

    private func configureAudioPlayback() throws {
        guard !audioConfigured else { return }

        let session = AVAudioSession.sharedInstance()
        // Playback-only is intentional. The companion app must not take ownership
        // of the physical iPhone microphone route.
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true, options: [])

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        audioEngine.mainMixerNode.outputVolume = 1.0
        try audioEngine.start()

        prebuffer.removeAll(keepingCapacity: true)
        playbackStarted = false
        playerNode.play()
        audioConfigured = true
        message = "Audio receiver ready"
    }

    private func deactivateAudioPlayback() {
        prebuffer.removeAll(keepingCapacity: true)
        playbackStarted = false
        playerNode.stop()
        audioEngine.stop()
        audioEngine.reset()
        audioConfigured = false
    }

    // MARK: - Microphone injection

    @available(iOS 18.2, *)
    private func observeMicrophoneInjectionAvailability() {
        let session = AVAudioSession.sharedInstance()
        injectionAvailable = session.isMicrophoneInjectionAvailable
        callActive = session.isMicrophoneInjectionAvailable

        Task { @MainActor [weak self] in
            guard let self else { return }
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.microphoneInjectionCapabilitiesChangeNotification
            ) {
                let available = notification.userInfo?
                    [AVAudioSessionMicrophoneInjectionIsAvailableKey] as? Bool ?? false

                self.injectionAvailable = available
                self.callActive = available

                if !available && self.injectionEnabled {
                    self.injectionEnabled = false
                    try? AVAudioSession.sharedInstance()
                        .setPreferredMicrophoneInjectionMode(.none)
                    self.message = "Supported call ended; microphone injection disabled"
                }
            }
        }
    }

    @available(iOS 18.2, *)
    func setInjectionEnabled(_ enabled: Bool) async {
        if !enabled {
            do {
                try AVAudioSession.sharedInstance()
                    .setPreferredMicrophoneInjectionMode(.none)
                injectionEnabled = false
                message = callActive
                    ? "Injection off"
                    : "Injection off (no active supported call)"
            } catch {
                message = "Could not disable injection: \(error.localizedDescription)"
            }
            return
        }

        // Apple's system-level Add Audio in Calls service must be enabled first.
        let permission = AVAudioApplication.shared.microphoneInjectionPermission
        switch permission {
        case .serviceDisabled:
            injectionEnabled = false
            message = "Enable Settings → Accessibility → Audio & Visual → Add Audio in Calls"

        case .undetermined:
            let result = await AVAudioApplication.requestMicrophoneInjectionPermission()
            if result == .granted {
                enableInjection()
            } else {
                injectionEnabled = false
                message = "Microphone injection permission denied"
            }

        case .granted:
            enableInjection()

        case .denied:
            injectionEnabled = false
            message = "Microphone injection permission denied; change it in Settings"

        @unknown default:
            injectionEnabled = false
            message = "Unknown microphone injection permission state"
        }
    }

    @available(iOS 18.2, *)
    private func enableInjection() {
        guard AVAudioSession.sharedInstance().isMicrophoneInjectionAvailable else {
            injectionEnabled = false
            message = "No supported active call is available for microphone injection"
            return
        }

        do {
            try AVAudioSession.sharedInstance()
                .setPreferredMicrophoneInjectionMode(.spokenAudio)
            injectionEnabled = true
            message = "PC microphone injection ON"
        } catch {
            injectionEnabled = false
            message = "Injection setup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Network

    func connect(port: UInt16 = 9878) {
        stopNetwork()

        do {
            try configureAudioPlayback()
        } catch {
            message = "Audio setup failed: \(error.localizedDescription)"
            return
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            message = "Invalid UDP port"
            return
        }

        do {
            let listener = try NWListener(using: .udp, on: endpointPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }

                    switch state {
                    case .ready:
                        self.connected = true
                        self.message = "Listening for PC microphone on UDP \(port)"

                    case .failed(let error):
                        self.connected = false
                        self.message = "UDP listener failed: \(error.localizedDescription)"

                    case .cancelled:
                        self.connected = false

                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }

                let id = ObjectIdentifier(connection)
                self.connections[id] = connection

                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }

                    if case .failed = state {
                        Task { @MainActor in
                            self.connections.removeValue(forKey: id)
                        }
                    }
                }

                connection.start(queue: self.networkQueue)
                self.receiveLoop(connection, id: id)
            }

            listener.start(queue: networkQueue)
        } catch {
            message = "UDP listener failed: \(error.localizedDescription)"
        }
    }

    func stopNetwork() {
        listener?.cancel()
        listener = nil

        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()

        connected = false
        expectedSequence = nil
        lastPacketTime = .distantPast
        prebuffer.removeAll(keepingCapacity: true)
        playbackStarted = false

        if #available(iOS 18.2, *), injectionEnabled {
            try? AVAudioSession.sharedInstance()
                .setPreferredMicrophoneInjectionMode(.none)
            injectionEnabled = false
        }

        if audioConfigured {
            deactivateAudioPlayback()
        }

        message = "Receiver stopped"
    }

    private func receiveLoop(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }

            if let error {
                Task { @MainActor in
                    self.message = "UDP receive error: \(error.localizedDescription)"
                    self.connections.removeValue(forKey: id)
                }
                return
            }

            if let data, !data.isEmpty {
                // NWConnection invokes this callback on networkQueue. handlePacket()
                // is MainActor-isolated, so explicitly hop to the MainActor.
                Task { @MainActor [weak self] in
                    self?.handlePacket(data)
                }
            }

            self.receiveLoop(connection, id: id)
        }
    }

    // MARK: - Packet handling

    private func handlePacket(_ data: Data) {
        // Header: magic(4), version(1), channels(1), frames(2),
        // sampleRate(4), seq(4), timestamp(4)
        guard data.count >= 20 else { return }
        guard data.prefix(4) == Data([0x56, 0x43, 0x4D, 0x31]) else { return }
        guard data[4] == 1, data[5] == 1 else { return }

        let frames = Int(UInt16(data[6]) << 8 | UInt16(data[7]))
        let sampleRate =
            UInt32(data[8]) << 24 |
            UInt32(data[9]) << 16 |
            UInt32(data[10]) << 8 |
            UInt32(data[11])
        let sequence =
            UInt32(data[12]) << 24 |
            UInt32(data[13]) << 16 |
            UInt32(data[14]) << 8 |
            UInt32(data[15])

        guard frames > 0, sampleRate == 48_000 else { return }

        let payload = data.dropFirst(20)
        guard payload.count == frames * 2 else { return }

        // UDP is ordered per flow, but packets can still be lost. When a forward
        // sequence gap is detected, insert silence for each missing 20 ms packet
        // so playback time does not collapse and drift earlier.
        if let expected = expectedSequence, sequence != expected {
            let gap = sequence &- expected
            if gap < 0x8000_0000 {
                let boundedGap = min(gap, 50) // cap at 1 second of inserted silence
                packetsDropped &+= UInt64(gap)
                for _ in 0..<boundedGap {
                    scheduleSilence(frames: frames)
                }
            }
        }
        expectedSequence = sequence &+ 1
        packetsReceived &+= 1
        lastPacketTime = Date()

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        payload.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress,
                  let destination = buffer.int16ChannelData?[0] else { return }
            memcpy(destination, source, frames * 2)
        }

        scheduleAudioBuffer(buffer)
    }

    private func scheduleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioConfigured else { return }

        // Prebuffer only at startup. After playback starts, schedule each packet
        // immediately so latency remains close to the network + 20 ms packet size.
        if !playbackStarted {
            prebuffer.append(buffer)
            guard prebuffer.count >= prebufferPacketCount else { return }

            for item in prebuffer {
                playerNode.scheduleBuffer(item, completionHandler: nil)
            }
            prebuffer.removeAll(keepingCapacity: true)
            playbackStarted = true
            message = injectionEnabled
                ? "Receiving PC microphone — injection ON"
                : "Receiving PC microphone"
            return
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func scheduleSilence(frames: Int) {
        guard audioConfigured else { return }

        guard let silence = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return }
        silence.frameLength = AVAudioFrameCount(frames)

        if let channel = silence.int16ChannelData?[0] {
            channel.initialize(repeating: 0, count: frames)
        }

        scheduleAudioBuffer(silence)
    }
}
