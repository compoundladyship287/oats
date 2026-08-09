import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing, using a Core Audio process tap
/// (macOS 14.2+). This is the "no bot joins the call" mechanism: we read the
/// system's own output stream rather than integrating with any meeting app.
///
/// Deliberate choices, each of which is a documented way to get silent failure:
///  - A raw IOProc reads the tap. `AVAudioEngine` cannot be pointed at the
///    aggregate device: setting `kAudioOutputUnitProperty_CurrentDevice`
///    returns `noErr` and is then ignored, yielding an eternally silent stream.
///  - The real output device is the aggregate's *main* sub-device and the tap
///    rides along as a sub-tap. Making the tap the main device also returns
///    `noErr` and also produces zero samples.
///  - The tap excludes our own PID, so we never record our own playback.
///  - `muteBehavior = .unmuted` keeps audio audible to the user while we record.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.oats.systemaudiotap", qos: .userInitiated)

    private(set) var format: AVAudioFormat?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    // Continuity accounting. The device timestamp tells us exactly how many
    // frames Core Audio believes have elapsed, so any shortfall between
    // callbacks is audio we never received — the difference between "the tap
    // works" and "the tap works without holes in it".
    private(set) var callbackCount = 0
    private(set) var deliveredFrames: Double = 0
    private(set) var missingFrames: Double = 0
    private var nextExpectedSampleTime: Double = -1

    /// Set up the tap and aggregate device. Does not start audio flowing.
    func prepare() throws {
        let outputDevice = try defaultOutputDeviceID()
        let outputUID = try deviceUID(outputDevice)
        print("  output device: \(deviceName(outputDevice)) [\(outputUID)]")

        // Tap everything except ourselves, in stereo.
        let ownProcessObject = try processObjectID(for: getpid())
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcessObject]
        )
        description.uuid = UUID()
        description.muteBehavior = CATapMuteBehavior.unmuted
        description.isPrivate = true  // don't advertise this tap to other apps
        description.isMixdown = true  // single stereo stream rather than per-process

        try check(
            "AudioHardwareCreateProcessTap",
            AudioHardwareCreateProcessTap(description, &tapID)
        )
        guard tapID != kAudioObjectUnknown else {
            throw CaptureError.message("Process tap was created but returned an unknown object ID")
        }
        print("  tap object id: \(tapID)")

        // Ask the tap what it will hand us before we build anything around it.
        var formatAddr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            "AudioObjectGetPropertyData(kAudioTapPropertyFormat)",
            AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &asbdSize, &asbd)
        )
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.message("Tap reported a stream format AVAudioFormat can't represent")
        }
        format = tapFormat
        print(
            "  tap format: \(Int(tapFormat.sampleRate)) Hz, \(tapFormat.channelCount) ch, "
                + "\(tapFormat.commonFormat == .pcmFormatFloat32 ? "float32" : "other"), "
                + "\(tapFormat.isInterleaved ? "interleaved" : "non-interleaved")"
        )

        let aggregateUID = UUID().uuidString
        let describeAggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Oats Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        try check(
            "AudioHardwareCreateAggregateDevice",
            AudioHardwareCreateAggregateDevice(describeAggregate as CFDictionary, &aggregateID)
        )
        print("  aggregate device id: \(aggregateID)")
    }

    /// Start delivering buffers. `handler` runs on a real-time audio thread —
    /// it must not allocate, lock, or block.
    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let format else {
            throw CaptureError.message("start() called before prepare()")
        }
        onBuffer = handler

        try check(
            "AudioDeviceCreateIOProcIDWithBlock",
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
                [weak self] _, inInputData, inInputTime, _, _ in
                guard let self, let handler = self.onBuffer else { return }
                guard
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        bufferListNoCopy: inInputData,
                        deallocator: nil
                    )
                else { return }

                let frames = Double(buffer.frameLength)
                let sampleTime = inInputTime.pointee.mSampleTime
                if self.nextExpectedSampleTime >= 0 {
                    let gap = sampleTime - self.nextExpectedSampleTime
                    if gap > 1 { self.missingFrames += gap }
                }
                self.nextExpectedSampleTime = sampleTime + frames
                self.callbackCount += 1
                self.deliveredFrames += frames

                handler(buffer)
            }
        )
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, ioProcID))
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        onBuffer = nil
    }

    deinit { stop() }
}
