import XCTest
@testable import PBAPI

/// DeviceLocator: candidate ordering for finding a DIN-connected synth.
final class DeviceLocatorTests: XCTestCase {

    private func port(
        name: String,
        mfr: String? = nil,
        model: String? = nil,
        isSource: Bool = false,
        isDestination: Bool = true
    ) -> MIDIPortInfo {
        MIDIPortInfo(
            deviceRef: 1,
            entityRef: 2,
            portRef: UInt32.random(in: 1...UInt32.max),
            name: name,
            manufacturer: mfr,
            model: model,
            isSource: isSource,
            isDestination: isDestination
        )
    }

    func testIsKorgNamedMatchesAcrossNameManufacturerModel() {
        XCTAssertTrue(DeviceLocator.isKorgNamed(port(name: "microKORG")))
        XCTAssertTrue(DeviceLocator.isKorgNamed(port(name: "Port 1", mfr: "Korg")))
        XCTAssertTrue(DeviceLocator.isKorgNamed(port(name: "Port 1", model: "microKORG XL")))
        // Case-insensitive, substring (catches "microKORG", "MS2000/R"...).
        XCTAssertTrue(DeviceLocator.isKorgNamed(port(name: "MICROKORG")))
        XCTAssertFalse(DeviceLocator.isKorgNamed(port(name: "UM-ONE", mfr: "Roland")))
        XCTAssertFalse(DeviceLocator.isKorgNamed(port(name: "IAC Driver Bus 1", mfr: "Apple Inc.")))
    }

    func testPrioritizePutsKorgNamedDestinationsFirst() {
        let umone = port(name: "UM-ONE", mfr: "Roland")
        let iac = port(name: "IAC Driver Bus 1", mfr: "Apple Inc.")
        let mk = port(name: "microKORG", mfr: "Korg")

        let ordered = DeviceLocator.prioritize([umone, iac, mk])
        XCTAssertEqual(ordered.first, mk, "A Korg-named endpoint must be probed/trusted first")
        XCTAssertEqual(Set(ordered.map(\.portRef)), Set([umone, iac, mk].map(\.portRef)),
                       "No endpoints may be dropped")
    }

    func testPrioritizeExcludesSources() {
        let src = port(name: "UM-ONE", isSource: true, isDestination: false)
        let dest = port(name: "UM-ONE", isDestination: true)
        let ordered = DeviceLocator.prioritize([src, dest])
        XCTAssertEqual(ordered.count, 1)
        XCTAssertTrue(ordered[0].isDestination)
    }

    func testPrioritizeOfEmptyInput() {
        XCTAssertTrue(DeviceLocator.prioritize([]).isEmpty)
    }

    /// CoreMIDI portRefs are unique per endpoint; the de-dupe guard must not
    /// collapse distinct endpoints that share a name (e.g. two "iPhone" rows).
    func testPrioritizeKeepsSameNamedDistinctEndpoints() {
        let a = port(name: "iPhone")
        let b = port(name: "iPhone")
        XCTAssertEqual(DeviceLocator.prioritize([a, b]).count, 2)
    }

    // MARK: Preferred port (Settings window pin)

    func testPrioritizePutsPreferredNameFirstAheadOfKorgNamed() {
        let iac = port(name: "IAC Driver Bus 1")
        let umone = port(name: "UM-ONE", mfr: "Roland")
        let mk = port(name: "microKORG", mfr: "Korg")
        let ordered = DeviceLocator.prioritize([iac, mk, umone], preferredName: "UM-ONE")
        XCTAssertEqual(ordered.map(\.name), ["UM-ONE", "microKORG", "IAC Driver Bus 1"])
    }

    func testPrioritizeWithMissingPreferredNameKeepsAutomaticOrder() {
        let iac = port(name: "IAC Driver Bus 1")
        let mk = port(name: "microKORG", mfr: "Korg")
        XCTAssertEqual(DeviceLocator.prioritize([iac, mk], preferredName: "Gone"),
                       DeviceLocator.prioritize([iac, mk]))
    }

    func testPreferredNamePersistsInDefaults() {
        let defaults = UserDefaults(suiteName: "DeviceLocatorTests-\(UUID())")!
        DeviceLocator.defaults = defaults
        XCTAssertNil(DeviceLocator.preferredDestinationName)
        DeviceLocator.preferredDestinationName = "UM-ONE"
        XCTAssertEqual(defaults.string(forKey: DeviceLocator.preferredDestinationKey), "UM-ONE")
        DeviceLocator.preferredDestinationName = nil
        XCTAssertNil(defaults.string(forKey: DeviceLocator.preferredDestinationKey))
    }

    // MARK: Resolution (fake transport)

    private var probeLog: [String] = []
    private let probeLock = NSLock()

    private func installFakes(endpoints: [MIDIPortInfo], answering synthName: String) {
        DeviceLocator.defaults = UserDefaults(suiteName: "DeviceLocatorTests-\(UUID())")!
        DeviceLocator.enumerate = { endpoints }
        DeviceLocator.probe = { [weak self] candidate, _, done in
            self?.probeLock.lock()
            self?.probeLog.append(candidate.name)
            self?.probeLock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                done(candidate.name == synthName)
            }
        }
        // Other suites construct MainWindowController, whose init starts a
        // real search; with the fakes now installed it drains quickly. Let it
        // finish so this test doesn't join it.
        let deadline = Date().addingTimeInterval(15)
        while DeviceLocator.isSearching && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        DeviceLocator.resetCache()
        probeLock.lock()
        probeLog.removeAll()
        probeLock.unlock()
    }

    override func tearDown() {
        DeviceLocator.enumerate = MIDIOutputPort.getConnectedDevices
        DeviceLocator.probe = DeviceLocator.liveProbe
        DeviceLocator.defaults = .standard
        DeviceLocator.resetCache()
        super.tearDown()
    }

    func testConcurrentResolutionsShareOneProbePass() {
        let iac = port(name: "IAC Driver Bus 1")
        let umone = port(name: "UM-ONE")
        installFakes(endpoints: [iac, umone], answering: "UM-ONE")
        DeviceLocator.resetCache()

        let first = expectation(description: "first")
        let second = expectation(description: "second")
        DeviceLocator.findDestination { result in
            XCTAssertEqual(try? result.get().name, "UM-ONE"); first.fulfill()
        }
        DeviceLocator.findDestination { result in
            XCTAssertEqual(try? result.get().name, "UM-ONE"); second.fulfill()
        }
        wait(for: [first, second], timeout: 5)
        XCTAssertEqual(probeLog, ["IAC Driver Bus 1", "UM-ONE"],
                       "a second caller must join the in-flight search, not start its own")
    }

    func testPinnedEndpointIsProbedFirst() {
        let iac = port(name: "IAC Driver Bus 1")
        let phone = port(name: "iPhone")
        let umone = port(name: "UM-ONE")
        installFakes(endpoints: [iac, phone, umone], answering: "UM-ONE")
        DeviceLocator.preferredDestinationName = "UM-ONE"
        DeviceLocator.resetCache()

        let done = expectation(description: "resolved")
        DeviceLocator.findDestination { result in
            XCTAssertEqual(try? result.get().name, "UM-ONE"); done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(probeLog, ["UM-ONE"])
    }

    /// Measured live: the first probe sent to the UM-ONE in a session gets
    /// no reply; the next one does. A pinned port is retried once before the
    /// search moves on, instead of paying a full sweep of every other port.
    func testPinnedEndpointGetsAnImmediateSecondTry() {
        let iac = port(name: "IAC Driver Bus 1")
        let umone = port(name: "UM-ONE")
        installFakes(endpoints: [iac, umone], answering: "UM-ONE")
        var umoneProbes = 0
        DeviceLocator.probe = { [weak self] candidate, _, done in
            self?.probeLog.append(candidate.name)
            if candidate.name == "UM-ONE" { umoneProbes += 1 }
            DispatchQueue.global().async { done(candidate.name == "UM-ONE" && umoneProbes > 1) }
        }
        DeviceLocator.preferredDestinationName = "UM-ONE"

        let done = expectation(description: "resolved")
        DeviceLocator.findDestination { result in
            XCTAssertEqual(try? result.get().name, "UM-ONE"); done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(probeLog, ["UM-ONE", "UM-ONE"])
    }

    func testWrongPinFallsBackToAutomaticSearch() {
        let iac = port(name: "IAC Driver Bus 1")
        let umone = port(name: "UM-ONE")
        installFakes(endpoints: [iac, umone], answering: "UM-ONE")
        DeviceLocator.preferredDestinationName = "IAC Driver Bus 1"
        DeviceLocator.resetCache()

        let done = expectation(description: "resolved")
        DeviceLocator.findDestination { result in
            XCTAssertEqual(try? result.get().name, "UM-ONE"); done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
