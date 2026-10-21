import Foundation
import CoreMIDI
import PBAPI

/// MIDI Utility functions and helpers.
/// Thin convenience layer over PBAPI's MIDIOutputPort.
public enum MIDIUtils {

    /// Get all connected MIDI endpoints (sources and destinations).
    public static func getDevices() -> [MIDIPortInfo] {
        return MIDIOutputPort.getConnectedDevices()
    }

    /// Get only destination endpoints (devices we can send to).
    public static func getDestinations() -> [MIDIPortInfo] {
        return MIDIOutputPort.getConnectedDevices().filter { $0.isDestination }
    }

    /// Get device name from an endpoint ref.
    public static func getDeviceName(_ portID: UInt32) -> String? {
        return MIDIOutputPort.getConnectedDevices().first { $0.portID == portID }?.name
    }

    /// Check if any destination device is connected and ready.
    public static func isConnected() -> Bool {
        return !getDestinations().isEmpty
    }

    /// Send a SysEx message and deliver the reply (or a timeout) via completion.
    public static func sendWithResponse(
        deviceID: UInt32,
        channel: Int,
        data: [UInt8],
        timeout: TimeInterval = 5.0,
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        MIDIOutputPort.sendSysEx(
            deviceID: deviceID,
            channel: channel,
            data: data,
            timeout: timeout,
            completion: completion
        )
    }

    /// Format SysEx message for sending: header + length + payload + F7.
    public static func formatSysEx(
        header: [UInt8],
        dataLength: Int,
        data: [UInt8]
    ) -> [UInt8] {
        let footer: [UInt8] = [0xF7]
        return header + [UInt8(dataLength)] + data + footer
    }

    /// Parse SysEx response (simplified): strip header/footer, return payload as string.
    public static func parseSysExResponse(_ response: [UInt8]) -> String? {
        guard response.count > 2, response.first == 0xF0 else { return nil }

        let startIndex = response.index(response.startIndex, offsetBy: 1)
        let endIndex = response.index(before: response.endIndex) // Before F7

        let data = Array(response[startIndex..<endIndex])

        if !data.isEmpty {
            return String(data: Data(data), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}
