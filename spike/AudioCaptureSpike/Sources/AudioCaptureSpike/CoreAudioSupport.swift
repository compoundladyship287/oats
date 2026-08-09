import AudioToolbox
import CoreAudio
import Foundation

enum CaptureError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case message(String)

    var description: String {
        switch self {
        case let .coreAudio(what, status):
            return "\(what) failed — OSStatus \(status) '\(fourCharCode(status))'"
        case let .message(text):
            return text
        }
    }
}

/// Core Audio reports most errors as four-char codes packed into an OSStatus.
/// Printing the raw integer alone makes these near-impossible to search for.
func fourCharCode(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    return printable ? String(bytes: bytes, encoding: .ascii) ?? "????" : "----"
}

func check(_ what: String, _ status: OSStatus) throws {
    guard status == noErr else { throw CaptureError.coreAudio(what, status) }
}

func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func defaultOutputDeviceID() throws -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        "AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultOutputDevice)",
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    )
    guard deviceID != kAudioObjectUnknown else {
        throw CaptureError.message("No default output device — is anything plugged in?")
    }
    return deviceID
}

func deviceUID(_ deviceID: AudioObjectID) throws -> String {
    var addr = address(kAudioDevicePropertyDeviceUID)
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    try check(
        "AudioObjectGetPropertyData(kAudioDevicePropertyDeviceUID)",
        withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
        }
    )
    return uid as String
}

/// `CATapDescription` identifies processes by Core Audio *process object ID*,
/// not by PID — passing a raw PID silently builds a tap that excludes nothing.
@available(macOS 14.0, *)
func processObjectID(for pid: pid_t) throws -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pidValue = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        "AudioObjectGetPropertyData(kAudioHardwarePropertyTranslatePIDToProcessObject)",
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
    )
    return objectID
}

func deviceName(_ deviceID: AudioObjectID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
    }
    return status == noErr ? (name as String) : "<unknown device>"
}
