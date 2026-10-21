import SwiftUI
import PBAPI
import UIControllers
import UIViews

/// MK Patch Librarian - MicroKORG patch librarian and editor
///
/// A free, open-source editor/librarian for Korg microKORG and other
/// synthesizers via MIDI.
@main
struct MKSoundEditorApp: App {

    @StateObject private var mainWindowController = MainWindowController()

    init() {
        // Initialize the CoreMIDI subsystem. This is safe to call even when no
        // hardware is attached; it just won't find a destination to auto-select.
        if MIDIOutputPort.initialize() {
            let devices = MIDIOutputPort.getConnectedDevices()
            print("MIDI initialized. \(devices.count) endpoint(s) found.")
            for device in devices {
                print("  - \(device.displayName)")
            }
        } else {
            print("Warning: MIDI initialization failed (no CoreMIDI client)")
        }

        print("MK Patch Librarian started")
    }

    var body: some Scene {
        WindowGroup {
            mainWindowController.asView()
        }
        .windowStyle(.titleBar)
        // The editor is a two-column control grid (v15 §3.1); the old
        // 600×700 default forced the single-column fallback.
        .defaultSize(width: 1100, height: 820)

        Settings {
            SettingsView(isMIDIBusy: mainWindowController.bankLoading)
        }
    }
}
