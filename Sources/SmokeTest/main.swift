import Foundation
import CoreMIDI
import PBAPI
import Models

// Hardware smoke test (docs §4):
//   1. Enumerate every CoreMIDI endpoint and flag MicroKORG source+destination.
//   2. If a MicroKORG destination is present, run SysExHandler.loadCurrentProgram
//      and hexdump the raw reply bytes.
//
// Usage:
//   SmokeTest           enumerate, then attempt the current-program dump
//   SmokeTest --list    enumeration only (no SysEx sent)
//   SmokeTest --probe                send the read-only 0x10 request to every
//                       destination and hexdump whatever replies (finds a DIN-connected synth)
//   SmokeTest --probe --target um-one  narrow the probe to one endpoint
//   SmokeTest --locator   exercise the editor's exact Load/Save path:
//                       DeviceLocator + loadCurrentProgram + idempotent write-back
//   SmokeTest --writeack  measure 0x11 -> 0x21/0x22 (refuses to write unless the
//                       edit buffer is byte-identical to a bank slot — no-op write)
//   SmokeTest --writeack --noop   measure the 0x21 success path with zero net
//                       change: edit:=slot -> 0x11 (byte-identical) -> restore+verify
//   SmokeTest --writeack --noop --slot N   same, but force the write target to
//                       slot index N (probes the S chart's two-byte program
//                       number; never use slot 1 — a mis-parse lands on C.11)
//   SmokeTest --global   read-only global dump (0x0E): Memory Protect, Local Ctrl, ...

let listOnly = CommandLine.arguments.contains("--list")
let probeMode = CommandLine.arguments.contains("--probe")
let locatorMode = CommandLine.arguments.contains("--locator")
let bankMode = CommandLine.arguments.contains("--bank")

/// Optional `--target <substring>` narrows --probe to matching destinations.
func targetFilter() -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: "--target"),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1].lowercased()
}

// MARK: 1. Enumeration

guard MIDIOutputPort.initialize() else {
    FileHandle.standardError.write("FAIL: CoreMIDI init failed\n".data(using: .utf8)!)
    exit(1)
}

let endpoints = MIDIOutputPort.getConnectedDevices()

print("=== CoreMIDI endpoints (\(endpoints.count)) ===")
for (i, port) in endpoints.enumerated() {
    let dir = port.isDestination ? "dest" : (port.isSource ? "src  " : "?    ")
    let mfr = port.manufacturer ?? "-"
    let model = port.model ?? "-"
    print(String(format: "[%2d] %@  portRef=0x%08X deviceRef=0x%08X  %@ / %@  \"%@\"",
                 i, dir, port.portRef, port.deviceRef, mfr, model, port.name))
}

func isMicroKORG(_ p: MIDIPortInfo) -> Bool {
    p.name.lowercased().contains("microkorg")
        || p.model?.lowercased().contains("microkorg") == true
        || p.manufacturer?.lowercased().contains("korg") == true
}

let mkDests = endpoints.filter { $0.isDestination && isMicroKORG($0) }
let mkSrcs = endpoints.filter { $0.isSource && isMicroKORG($0) }

print("--- match check ---")
print("MicroKORG destinations: \(mkDests.map { $0.displayName })")
print("MicroKORG sources:      \(mkSrcs.map { $0.displayName })")

guard !listOnly else { exit(0) }

// MARK: 2. Current-program round trip

/// Send the read-only 0x10 request to one destination and hexdump the RAW reply
/// (before parsing), then report what the parser makes of it.
func requestProgram(to dest: MIDIPortInfo, timeout: TimeInterval) -> Bool {
    print("\n=== loadCurrentProgram → 0x10 request, expect 0x40 ===")
    print("Sending to: \(dest.displayName) (portRef 0x\(String(dest.portRef, radix: 16)))")
    MIDIOutputPort.select(device: dest)

    let semaphore = DispatchSemaphore(value: 0)
    var passed = false

    MIDIOutputPort.sendSysEx(
        deviceID: dest.portRef,
        channel: 0,
        data: KorgSysEx.requestCurrentProgram(),
        timeout: timeout
    ) { result in
        switch result {
        case .failure(let error):
            print("FAIL: \(error.localizedDescription)")
        case .success(let raw):
            print("RAW REPLY: \(raw.count) bytes")
            // Persist the exact bytes for offline analysis.
            let saveURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("smoke-reply.syx")
            try? Data(raw).write(to: saveURL)
            print("saved -> \(saveURL.path)")
            for chunk in Swift.stride(from: 0, to: raw.count, by: 16) {
                let end = min(chunk + 16, raw.count)
                let hex = raw[chunk..<end].map { String(format: "%02X", $0) }.joined(separator: " ")
                print(String(format: "%08X  %@", chunk, hex))
            }
            do {
                let parsed = try KorgSysEx.parse(raw)
                print("PARSE: command 0x\(String(parsed.command.rawValue, radix: 16)), \(parsed.data.count) decoded bytes")
                // Only a real 0x40 dump counts: a loopback bus echoes our own
                // 0x10 request, which parses fine but is not a device reply.
                if parsed.command == .currentProgramDump {
                    let name = KorgSysEx.programName(from: parsed.data)
                    print("PROGRAM NAME: \"\(name)\"")
                    passed = true
                } else {
                    print("not a program dump (echo?) — ignored")
                }
            } catch {
                print("PARSE FAIL: \(error.localizedDescription)")
            }
        }
        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .now() + timeout + 5)
    return passed
}

// MARK: 3. Locator + editor-equivalent round trip (Load/Save path)

if locatorMode {
    // Exactly the sequence EditorView's Load/Save buttons use:
    // DeviceLocator.findDestination -> loadCurrentProgram -> sendCurrentProgram.
    // The write-back sends the SAME bytes just read, so it is idempotent.
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    DeviceLocator.findDestination(timeout: 1.5) { result in
        // Completions arrive on background queues; a CLI needs no main hops.
        switch result {
        case .failure(let error):
            print("LOCATOR FAIL: \(error.localizedDescription)")
            exitCode = 2
            semaphore.signal()
        case .success(let dest):
            print("LOCATOR OK: \(dest.displayName) (portRef 0x\(String(dest.portRef, radix: 16)))")
            PBAPI.SysExHandler.loadCurrentProgram(deviceID: dest.portRef, timeout: 5.0) { load in
                switch load {
                case .failure(let error):
                    print("LOAD FAIL: \(error.localizedDescription)")
                    exitCode = 3
                    semaphore.signal()
                case .success(let data):
                    let name = KorgSysEx.programName(from: data)
                    print("LOAD OK: \(data.count) bytes, program \"\(name)\"")
                    // Idempotent write-back: echo the identical program
                    // into the edit buffer (no slot commit).
                    PBAPI.SysExHandler.sendCurrentProgram(deviceID: dest.portRef, data: data) { save in
                        switch save {
                        case .success:
                            print("SAVE OK: identical program echoed to edit buffer")
                        case .failure(let error):
                            print("SAVE FAIL: \(error.localizedDescription)")
                            exitCode = 4
                        }
                        semaphore.signal()
                    }
                }
            }
        }
    }
    _ = semaphore.wait(timeout: .now() + 20)
    exit(exitCode)
}

// MARK: 3b. Generic raw request probe — send arbitrary SysEx, capture all replies
//
//   SmokeTest --req "F0 42 30 58 1C 00 00 F7" ["F04230580F F7" ...]
//
// Sends each hex string (whitespace tolerated) to the located synth in order,
// capturing the raw reply stream per request. Used to test bank-dump
// hypotheses (H2 addressed 1C, H3 0x0F) without a rebuild per experiment.

func parseHexBytes(_ s: String) -> [UInt8] {
    let hex = s.filter { !$0.isWhitespace }
    var out: [UInt8] = []
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        if let b = UInt8(hex[idx..<next], radix: 16) { out.append(b) }
        idx = next
    }
    return out
}

/// Frame-split a raw capture and explain every frame (command, decoded size,
/// 4C address prefix + program name) without the strict size checks of parse().
func analyzeCapture(_ raw: [UInt8], index: Int) {
    print("RAW CAPTURE: \(raw.count) bytes")
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("req-\(index)-capture.syx")
    try? Data(raw).write(to: url)
    print("saved -> \(url.path)")

    var frames: [[UInt8]] = []
    var current: [UInt8] = []
    for byte in raw {
        if byte == 0xF0 { current = [0xF0] }
        else if byte == 0xF7 && !current.isEmpty {
            current.append(0xF7)
            frames.append(current)
            current = []
        } else if !current.isEmpty {
            current.append(byte)
        }
    }
    if !current.isEmpty { frames.append(current) }
    print("frames: \(frames.count)")

    for (i, frame) in frames.enumerated() {
        guard frame.count >= 6 else {
            print("  frame \(i): too short (\(frame.count) bytes)")
            continue
        }
        let cmd = frame[4]
        let body = Array(frame[5..<(frame.count - 1)])
        let decoded = body.isEmpty ? [] : KorgSysEx.decode8to7(body)
        let hdr = frame.prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("  frame \(i): \(frame.count) raw B [\(hdr)...] cmd 0x\(String(cmd, radix: 16)), \(decoded.count) decoded")
        if cmd == 0x4C && decoded.count >= 2 {
            print("    4C address: \(String(format: "%02X %02X", decoded[0], decoded[1]))")
            if decoded.count >= 14 {
                let name = KorgSysEx.programName(from: Array(decoded[2..<14]))
                print("    program name: \"\(name)\"")
            }
        } else if cmd == 0x50 && decoded.count > 14 {
            let name = KorgSysEx.programName(from: Array(decoded[0..<12]))
            print("    ALL DATA dump, first program: \"\(name)\"")
        } else if cmd == 0x24 || cmd == 0x26 {
            print("    device ERROR/NAK reply")
        }
    }
}

if let reqIdx = CommandLine.arguments.firstIndex(of: "--req") {
    let hexArgs = CommandLine.arguments.suffix(from: reqIdx + 1).filter { arg in
        !arg.hasPrefix("--")
            && !arg.isEmpty
            && arg.filter { !$0.isWhitespace }.allSatisfy { $0.isHexDigit }
    }
    guard !hexArgs.isEmpty else {
        FileHandle.standardError.write(
            "usage: SmokeTest --req \"F0 42 30 58 1C 00 00 F7\" [...more hex strings...]\n"
                .data(using: .utf8)!)
        exit(64)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    // The synth sits behind a UM-ONE on DIN, and the UM-ONE itself IS visible
    // by name — match it directly to skip the 13-endpoint probe sequence,
    // which can flake on its 1.5 s per-endpoint timeout. Locator as fallback.
    let umone = MIDIOutputPort.getConnectedDevices().first {
        $0.isDestination && $0.displayName.lowercased().contains("um-one")
    }

    let located: (Result<MIDIPortInfo, Error>) -> Void = { result in
        switch result {
        case .failure(let error):
            print("LOCATOR FAIL: \(error.localizedDescription)")
            exitCode = 2
            semaphore.signal()
        case .success(let dest):
            // Connects the matching source so replies actually arrive.
            MIDIOutputPort.select(device: dest)
            print("REQ probe -> \(dest.displayName)")
            // Sequential so replies from different requests cannot interleave.
            func sendNext(_ i: Int) {
                guard i < hexArgs.count else { semaphore.signal(); return }
                let bytes = parseHexBytes(hexArgs[i])
                print("\n### request \(i): \(hexArgs[i]) (\(bytes.count) bytes)")
                MIDIOutputPort.sendAndCapture(
                    deviceID: dest.portRef,
                    data: bytes,
                    timeout: 45.0,
                    quietInterval: 4.0   // full dumps stream for ~12s; stop on 4s quiet
                ) { capture in
                    switch capture {
                    case .failure(let error):
                        print("CAPTURE FAIL: \(error.localizedDescription)")
                        exitCode = 3
                        semaphore.signal()
                    case .success(let raw):
                        analyzeCapture(raw, index: i)
                        sendNext(i + 1)
                    }
                }
            }
            sendNext(0)
        }
    }

    if let direct = umone {
        print("REQ target (direct match): \(direct.displayName)")
        located(.success(direct))
    } else {
        DeviceLocator.findDestination(timeout: 3.0, completion: located)
    }
    let budget = Double(hexArgs.count) * 55.0 + 30.0
    _ = semaphore.wait(timeout: .now() + budget)
    exit(exitCode)
}

// MARK: 3c. App-equivalent bank load — exercises SysExHandler.loadBank exactly

if CommandLine.arguments.contains("--loadbank") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    DeviceLocator.findDestination(timeout: 2.5) { result in
        switch result {
        case .failure(let error):
            print("LOCATOR FAIL: \(error.localizedDescription)")
            exitCode = 2
            semaphore.signal()
        case .success(let dest):
            print("LOADBANK via SysExHandler -> \(dest.displayName)")
            PBAPI.SysExHandler.loadBank(deviceID: dest.portRef, timeout: 45) { reply in
                switch reply {
                case .failure(let error):
                    print("LOADBANK FAIL: \(error.localizedDescription)")
                    exitCode = 3
                case .success(let bank):
                    print("LOADBANK OK: \(bank.count) bytes")
                    let names = try? KorgSysEx.programNames(inBank: bank)
                    print("NAMES: \(names?.count ?? 0), first: \(names.map { $0[0 ... 3].joined(separator: ", ") } ?? "n/a")")
                    let p0 = try? KorgSysEx.program(0, inBank: bank)
                    print("PROGRAM 0: \(p0?.count ?? 0) bytes, \"\(p0.map { KorgSysEx.programName(from: $0) } ?? "?")\"")
                }
                semaphore.signal()
            }
        }
    }
    _ = semaphore.wait(timeout: .now() + 60)
    exit(exitCode)
}

// MARK: 3d. Safe write-ack probe — measures 0x11 -> 0x21/0x22 live
//
// A write overwrites a real program, so this mode only sends 0x11 when the
// write cannot change data:
//   - Memory Protect ON (read via 0x0E, TABLE 6 byte5 B0): the synth must
//     reject with 0x22 WRITE ERROR -> measures the rejection path, zero risk.
//   - Protect OFF: requires a slot byte-identical to the edit buffer (found
//     by reading 0x10 + 0x0F), so the write rewrites a slot with its own
//     data — a no-op. Otherwise it refuses and prints a diff diagnosis.

if CommandLine.arguments.contains("--writeack") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    /// `--writeack --noop`: measure the 0x21 SUCCESS path with zero net
    /// change (see noopSteps below). Requires Protect OFF.
    let noopRequested = CommandLine.arguments.contains("--noop")

    /// `--slot N` with `--noop`: force the write target to slot index N
    /// instead of the closest-match slot. Needed to probe the S chart's
    /// two-byte program number: a byte-identical rewrite to a chosen slot
    /// either acks 0x21 (legacy `11 00 pp` parse confirmed) or is rejected
    /// 0x22 (format mismatch, nothing written) — both zero-risk, but only
    /// for slots whose mis-parse cannot land on a stored program (avoid
    /// index 1: a two-byte mis-parse of `pp=1` reads as program 128 = C.11).
    let forcedSlot: Int? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--slot"),
              i + 1 < CommandLine.arguments.count,
              let n = Int(CommandLine.arguments[i + 1]),
              n >= 0, n < KorgSysEx.programsPerBank else { return nil }
        return n
    }()

    func slotLabel(_ index: Int) -> String {
        ProgramSlot.panelLabel(flat: index)
    }

    /// All 128 slots ranked by byte distance from `editData` (0 = identical).
    func rankSlots(bankData: [UInt8], editData: [UInt8]) -> [(index: Int, diffs: Int)] {
        var ranked: [(index: Int, diffs: Int)] = []
        for index in 0..<KorgSysEx.programsPerBank {
            let start = index * KorgSysEx.programDataSize
            let slotBytes = Array(
                bankData[start..<(start + KorgSysEx.programDataSize)])
            ranked.append((index, zip(slotBytes, editData).filter { $0 != $1 }.count))
        }
        return ranked.sorted { $0.diffs < $1.diffs }
    }

    /// Measure 0x21 with zero net change anywhere:
    ///   1. edit buffer := a stored slot's own bytes (0x40 — edit buffer only)
    ///   2. 0x11 write to that slot — byte-identical rewrite of what the slot
    ///      already holds, so the synth should ack 0x21 (chart §13)
    ///   3. edit buffer := the user's original bytes (0x40)
    ///   4. re-read (0x10) and verify the restore byte-for-byte
    /// No stored program ever changes; the edit buffer ends where it began.
    func noopSteps(dest: MIDIPortInfo, original: [UInt8], bankData: [UInt8]) {
        let target: (index: Int, diffs: Int)
        if let forced = forcedSlot {
            let start = forced * KorgSysEx.programDataSize
            let slotBytes = Array(
                bankData[start..<(start + KorgSysEx.programDataSize)])
            target = (forced, zip(slotBytes, original).filter { $0 != $1 }.count)
        } else {
            target = rankSlots(bankData: bankData, editData: original)[0]
        }
        let start = target.index * KorgSysEx.programDataSize
        let slotBytes = Array(bankData[start..<(start + KorgSysEx.programDataSize)])
        let label = slotLabel(target.index)

        /// Push 254 bytes into the edit buffer, then settle briefly so the
        /// synth's 0x23 (chart §6) cannot be mistaken for the 0x11's ack.
        func pushEdit(_ data: [UInt8], as tag: String, failCode: Int32,
                      then next: @escaping () -> Void) {
            PBAPI.SysExHandler.sendCurrentProgram(deviceID: dest.portRef, data: data) { result in
                switch result {
                case .failure(let error):
                    print("\(tag) FAIL: \(error.localizedDescription)")
                    exitCode = failCode
                    semaphore.signal()
                case .success:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: next)
                }
            }
        }

        print("Target slot \(label) (index \(target.index)): edit buffer := its stored bytes,")
        print("so the 0x11 rewrite stores exactly what the slot already holds (no-op).")
        pushEdit(slotBytes, as: "EDIT SET", failCode: 6) {
            PBAPI.SysExHandler.writeCurrentProgram(
                deviceID: dest.portRef,
                programIndex: target.index
            ) { written in
                let writeOK: Bool
                switch written {
                case .success:
                    print("WRITE ACK OK: slot \(label) -> WRITE COMPLETED (0x21)")
                    print("— success path measured live")
                    writeOK = true
                case .failure(let error):
                    print("WRITE ACK FAIL: \(error.localizedDescription)")
                    writeOK = false
                }
                // Restore the user's edit buffer unconditionally.
                pushEdit(original, as: "EDIT RESTORE", failCode: 8) {
                    PBAPI.SysExHandler.loadCurrentProgram(deviceID: dest.portRef, timeout: 5.0) { verify in
                        let restoreOK: Bool
                        switch verify {
                        case .failure(let error):
                            print("RESTORE VERIFY FAIL: \(error.localizedDescription) —")
                            print("the edit buffer may still hold slot \(label)!")
                            restoreOK = false
                        case .success(let now):
                            if now == original {
                                print("RESTORE VERIFIED: edit buffer byte-identical to the original")
                                restoreOK = true
                            } else {
                                let diffs = zip(now, original).filter { $0 != $1 }.count
                                print("RESTORE MISMATCH: \(diffs) byte(s) differ from the original")
                                restoreOK = false
                            }
                        }
                        if writeOK && restoreOK {
                            print("NOOP PROBE OK: 0x21 measured, no stored data changed")
                        }
                        exitCode = (writeOK && restoreOK) ? 0 : (restoreOK ? 7 : 8)
                        semaphore.signal()
                    }
                }
            }
        }
    }

    /// Decide whether 0x11 is safe to send, then send it through the app's
    /// exact write path (ack-gated) and interpret the outcome.
    func writeIfSafe(dest: MIDIPortInfo, protectOn: Bool, editData: [UInt8], bankData: [UInt8]) {
        // diffs == 0 means a byte-identical rewrite (a no-op).
        let ranked = rankSlots(bankData: bankData, editData: editData)
        guard let best = ranked.first else {
            print("REFUSING TO WRITE: bank ranking empty (unexpected bank size)")
            exitCode = 5
            semaphore.signal()
            return
        }
        let label = slotLabel(best.index)
        let identical = best.diffs == 0

        let expectRejection: Bool
        if protectOn {
            expectRejection = true
            print("Memory Protect is ON — the chart says the synth must answer 0x11 with")
            print("0x22 WRITE ERROR, so no data changes. Closest slot: \(label) (index")
            print("\(best.index), differs in \(best.diffs)/254 bytes from the edit buffer).")
            print("Expecting 0x22 WRITE ERROR (measuring the rejection path)...")
        } else if identical {
            expectRejection = false
            print("Slot \(label) (index \(best.index)) is byte-identical to the edit buffer —")
            print("the write rewrites it with its own data (no-op).")
            print("Expecting 0x21 WRITE COMPLETED...")
        } else {
            // Protect OFF and no no-op target: refuse, but diagnose first.
            print("REFUSING TO WRITE: Protect is OFF and the edit buffer matches none of")
            print("the 128 slots, so 0x11 would overwrite a different program.")
            print("Edit buffer: \"\(KorgSysEx.programName(from: editData))\"")
            for candidate in ranked.prefix(5) {
                let start = candidate.index * KorgSysEx.programDataSize
                let name = KorgSysEx.programName(
                    from: Array(bankData[start..<start + KorgSysEx.nameLength]))
                print("  closest: index \(candidate.index) \"\(name)\" "
                    + "differs in \(candidate.diffs)/254 bytes")
            }
            let start = best.index * KorgSysEx.programDataSize
            let slotBytes = Array(
                bankData[start..<(start + KorgSysEx.programDataSize)])
            let offsets = zip(slotBytes, editData)
                .enumerated()
                .filter { $0.element.0 != $0.element.1 }
                .map { $0.offset }
            print("  differing offsets vs index \(best.index): "
                + offsets.prefix(20).map { String($0) }.joined(separator: ", "))
            exitCode = 5
            semaphore.signal()
            return
        }

        // The app's exact write path (ack-gated).
        PBAPI.SysExHandler.writeCurrentProgram(
            deviceID: dest.portRef,
            programIndex: best.index
        ) { written in
            switch written {
            case .success:
                if expectRejection {
                    print("UNEXPECTED: write reported success while Protect is ON —")
                    print("verify slot \(label) on the panel!")
                    exitCode = 7
                } else {
                    print("WRITE ACK OK: slot \(label) -> WRITE COMPLETED (0x21)")
                }
            case .failure(let error):
                if expectRejection, (error as? KorgSysExError) == .writeRejected {
                    print("WRITE ACK MEASURED: slot \(label) rejected — 0x22 WRITE ERROR,")
                    print("reported as a failure by SysExHandler, as charted (§14).")
                    exitCode = 0
                } else {
                    print("WRITE ACK FAIL: \(error.localizedDescription)")
                    exitCode = 6
                }
            }
            semaphore.signal()
        }
    }

    func located(_ result: Result<MIDIPortInfo, Error>) {
        switch result {
        case .failure(let error):
            print("LOCATOR FAIL: \(error.localizedDescription)")
            exitCode = 2
            semaphore.signal()
        case .success(let dest):
            // Connects the matching source so the ack actually arrives.
            MIDIOutputPort.select(device: dest)
            print("WRITEACK -> \(dest.displayName)")

            // 0. Memory Protect (read-only): decides which write is safe.
            PBAPI.SysExHandler.loadGlobal(deviceID: dest.portRef, timeout: 5.0) { global in
                let protectOn: Bool
                switch global {
                case .failure(let error):
                    print("GLOBAL WARN: \(error.localizedDescription) — assuming Protect OFF")
                    protectOn = false
                case .success(let data):
                    let settings = GlobalSettings(data: data)
                    protectOn = settings?.memoryProtect ?? false
                    print("Memory Protect: \(protectOn ? "ON" : "OFF")"
                        + (protectOn ? " (rejection path, zero data risk)"
                                     : " (only a byte-identical no-op write allowed)"))
                }

                // --noop measures the 0x21 SUCCESS path, which Protect would
                // turn into 0x22 — bail out before the slow bank read.
                if noopRequested && protectOn {
                    print("ABORT: --noop needs Protect OFF (it is ON); the write would be rejected.")
                    print("Turn PROTECT off, then re-run.")
                    exitCode = 5
                    semaphore.signal()
                    return
                }

                // 1. Edit buffer (read-only).
                PBAPI.SysExHandler.loadCurrentProgram(deviceID: dest.portRef, timeout: 5.0) { edit in
                    switch edit {
                    case .failure(let error):
                        print("EDIT BUFFER FAIL: \(error.localizedDescription)")
                        exitCode = 3
                        semaphore.signal()
                    case .success(let editData):
                        // 2. Full bank (read-only, ~12 s at MIDI baud).
                        PBAPI.SysExHandler.loadBank(deviceID: dest.portRef, timeout: 45) { bank in
                            switch bank {
                            case .failure(let error):
                                print("BANK FAIL: \(error.localizedDescription)")
                                exitCode = 4
                                semaphore.signal()
                            case .success(let bankData):
                                if noopRequested {
                                    noopSteps(dest: dest, original: editData,
                                              bankData: bankData)
                                } else {
                                    writeIfSafe(dest: dest, protectOn: protectOn,
                                                editData: editData, bankData: bankData)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Same UM-ONE direct-match shortcut as --req (the DIN synth is never
    // named "Korg"; the 13-endpoint probe can flake on its per-endpoint timeout).
    if let direct = MIDIOutputPort.getConnectedDevices().first(where: {
        $0.isDestination && $0.displayName.lowercased().contains("um-one")
    }) {
        print("WRITEACK target (direct match): \(direct.displayName)")
        located(.success(direct))
    } else {
        DeviceLocator.findDestination(timeout: 3.0, completion: located)
    }
    _ = semaphore.wait(timeout: .now() + 90)
    exit(exitCode)
}

// MARK: 3e. Global dump — read-only (0x0E -> 0x51), prints TABLE 6 state
//
// Reports Memory Protect (byte 5 bit 0): with Protect ON the chart says the
// synth must answer 0x11 with 0x22 WRITE ERROR, which makes a live write-ack
// probe zero-risk. Also verifies the S honors 0x0E at all (it deviates from
// the chart elsewhere — see 0x1C).

if CommandLine.arguments.contains("--global") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    func located(_ result: Result<MIDIPortInfo, Error>) {
        switch result {
        case .failure(let error):
            print("LOCATOR FAIL: \(error.localizedDescription)")
            exitCode = 2
            semaphore.signal()
        case .success(let dest):
            MIDIOutputPort.select(device: dest)
            print("GLOBAL -> \(dest.displayName)")
            PBAPI.SysExHandler.loadGlobal(deviceID: dest.portRef, timeout: 5.0) { reply in
                switch reply {
                case .failure(let error):
                    print("GLOBAL FAIL: \(error.localizedDescription)")
                    exitCode = 3
                case .success(let data):
                    guard let global = GlobalSettings(data: data) else {
                        print("GLOBAL FAIL: \(data.count) bytes (expected \(KorgSysEx.globalDataSize))")
                        exitCode = 4
                        semaphore.signal()
                        return
                    }
                    print("GLOBAL OK: \(data.count) bytes")
                    let head = data.prefix(20)
                        .map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("bytes 0..19:  \(head)")
                    print("Memory Protect (byte5 B0): \(global.memoryProtect ? "ON" : "OFF")")
                    print("Local Ctrl    (byte5 B2): \(global.localControl ? "ON" : "OFF")")
                    print("SysEx Filter  (byte16 B7): \(global.sysExFilterEnabled ? "Ena" : "Dis")  [chart: must be Ena]")
                    print("Master Tune: \(global.masterTune) cents, Transpose: \(global.transpose), "
                        + "Clock: \(global.clock), MIDI Ch: \(global.midiChannel + 1)")
                    for row in stride(from: 0, to: data.count, by: 20) {
                        let hex = data[row..<min(row + 20, data.count)]
                            .map { String(format: "%02X", $0) }.joined(separator: " ")
                        print(String(format: "%3d: ", row) + hex)
                    }
                }
                semaphore.signal()
            }
        }
    }

    if let direct = MIDIOutputPort.getConnectedDevices().first(where: {
        $0.isDestination && $0.displayName.lowercased().contains("um-one")
    }) {
        located(.success(direct))
    } else {
        DeviceLocator.findDestination(timeout: 3.0, completion: located)
    }
    _ = semaphore.wait(timeout: .now() + 15)
    exit(exitCode)
}

// MARK: 3e2. Bank-select reachability — can SysEx reach C and D? (read-only)
//
//   SmokeTest --bankselect <lsb> <pc> [<msb>]
//
// Sends CC0=<msb> (default 0), CC32=<lsb>, then Program Change <pc> on the
// synth's MIDI channel, then reads the edit buffer (0x10) and prints its
// program name. Changes only the selected program — nothing is written.
// Expect "Synth Harp" for lsb=1 pc=0 (C.11 on Korg's Voice Name List).

if let bsIdx = CommandLine.arguments.firstIndex(of: "--bankselect"),
   bsIdx + 2 < CommandLine.arguments.count,
   let lsb = Int(CommandLine.arguments[bsIdx + 1]),
   let pc = Int(CommandLine.arguments[bsIdx + 2]) {
    /// Optional 4th token overrides the bank MSB (CC0); default 0.
    let msbValue = bsIdx + 3 < CommandLine.arguments.count
        ? (Int(CommandLine.arguments[bsIdx + 3]) ?? 0) : 0
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    func located(_ result: Result<MIDIPortInfo, Error>) {
        switch result {
        case .failure(let error):
            print("LOCATOR FAIL: \(error.localizedDescription)")
            exitCode = 2
            semaphore.signal()
        case .success(let dest):
            MIDIOutputPort.select(device: dest)
            print("BANKSELECT -> \(dest.displayName)  CC0=\(msbValue) CC32=\(lsb) PC=\(pc)")

            // CC0, CC32, PC — sent as three short messages with a gap so the
            // synth latches bank select before the program change.
            let steps: [[UInt8]] = [
                [0xB0, 0x00, UInt8(clamping: msbValue)], // CC0  = bank MSB
                [0xB0, 0x20, UInt8(clamping: lsb)],      // CC32 = bank LSB
                [0xC0, UInt8(clamping: pc)],             // Program Change
            ]
            func sendStep(_ i: Int) {
                guard i < steps.count else {
                    // Let the panel settle, then read the edit buffer.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        MIDIOutputPort.sendAndCapture(
                            deviceID: dest.portRef,
                            data: KorgSysEx.requestCurrentProgram(),
                            timeout: 8.0,
                            quietInterval: 1.0
                        ) { capture in
                            switch capture {
                            case .failure(let error):
                                print("EDIT BUFFER FAIL: \(error.localizedDescription)")
                                exitCode = 3
                            case .success(let raw):
                                analyzeCapture(raw, index: 90)
                                // Decode every frame and print program names.
                                var frames: [[UInt8]] = []
                                var current: [UInt8] = []
                                for byte in raw {
                                    if byte == 0xF0 { current = [0xF0] }
                                    else if byte == 0xF7 && !current.isEmpty {
                                        current.append(0xF7)
                                        frames.append(current)
                                        current = []
                                    } else if !current.isEmpty {
                                        current.append(byte)
                                    }
                                }
                                for frame in frames where frame.count >= 6 {
                                    let decoded = KorgSysEx.decode8to7(
                                        Array(frame[5..<(frame.count - 1)]))
                                    if decoded.count >= 12 {
                                        let name = KorgSysEx.programName(
                                            from: Array(decoded[0..<12]))
                                        print("EDIT BUFFER (cmd 0x\(String(frame[4], radix: 16))): "
                                            + "\"\(name)\"")
                                        if name == "Synth Harp" {
                                            print("RESULT: reachable — Korg lists Synth Harp at C.11")
                                        }
                                        // Characterize unnamed regions: name bytes
                                        // (spaces vs zeros) + the audible path.
                                        let nameHex = decoded[0..<12]
                                            .map { String(format: "%02X", $0) }
                                            .joined(separator: " ")
                                        let t = 38
                                        print("  name bytes: \(nameHex)")
                                        print(String(format:
                                            "  byte16=%02X osc1wave=%d cut=%d ampLvl=%d",
                                            decoded[16], decoded[t + 7],
                                            decoded[t + 20], decoded[t + 25]))
                                    } else {
                                        print("frame cmd 0x\(String(frame[4], radix: 16)): "
                                            + "\(decoded.count) decoded")
                                    }
                                }
                            }
                            semaphore.signal()
                        }
                    }
                    return
                }
                MIDIOutputPort.sendMIDIPacket(
                    deviceID: dest.portRef, channel: 0, message: steps[i]
                ) { result in
                    if case .failure(let error) = result {
                        print("SEND FAIL (step \(i)): \(error.localizedDescription)")
                        exitCode = 4
                        semaphore.signal()
                        return
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        sendStep(i + 1)
                    }
                }
            }
            sendStep(0)
        }
    }

    if let direct = MIDIOutputPort.getConnectedDevices().first(where: {
        $0.isDestination && $0.displayName.lowercased().contains("um-one")
    }) {
        located(.success(direct))
    } else {
        DeviceLocator.findDestination(timeout: 3.0, completion: located)
    }
    _ = semaphore.wait(timeout: .now() + 20)
    exit(exitCode)
}

// MARK: 3e3. Slot compare — baseline .syx vs a fresh bank read (read-only)
//
//   SmokeTest --slotcmp <index> <baseline.syx>
//
// Decodes the baseline all-data capture (e.g. req-3-capture.syx, taken
// before any app write), pulls slot <index> from it and from a fresh 0x0F
// bank read, and prints every differing byte. Settles "did the save
// actually write?" without touching the synth.

if let scIdx = CommandLine.arguments.firstIndex(of: "--slotcmp"),
   scIdx + 2 < CommandLine.arguments.count,
   let slot = Int(CommandLine.arguments[scIdx + 1]) {
    let basePath = CommandLine.arguments[scIdx + 2]
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0

    /// Frame-split a capture, decode the 0x50 frame, return the 32512-byte bank.
    func bankFromCapture(path: String) throws -> [UInt8] {
        let raw = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        var frames: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in raw {
            if byte == 0xF0 { current = [0xF0] }
            else if byte == 0xF7 && !current.isEmpty {
                current.append(0xF7)
                frames.append(current)
                current = []
            } else if !current.isEmpty {
                current.append(byte)
            }
        }
        guard let frame = frames.first(where: { $0.count > 5 && $0[4] == 0x50 }) else {
            throw KorgSysExError.wrongDataSize(expected: KorgSysEx.allDataSize,
                                                got: raw.count)
        }
        let decoded = KorgSysEx.decode8to7(Array(frame[5..<(frame.count - 1)]))
        return try KorgSysEx.bank(fromAllData: decoded)
    }

    guard (0..<128).contains(slot) else { exit(64) }
    do {
        let baseline = try bankFromCapture(path: basePath)
        let baseSlot = try KorgSysEx.program(slot, inBank: baseline)
        print("BASELINE \(basePath) slot \(slot) (panel \(ProgramSlot.panelLabel(flat: slot))) "
            + "\"\(KorgSysEx.programName(from: baseSlot))\"")

        DeviceLocator.findDestination(timeout: 3.0) { result in
            switch result {
            case .failure(let error):
                print("LOCATOR FAIL: \(error.localizedDescription)")
                code = 2
                sema.signal()
            case .success(let dest):
                MIDIOutputPort.select(device: dest)
                PBAPI.SysExHandler.loadBank(deviceID: dest.portRef, timeout: 45) { bank in
                    switch bank {
                    case .failure(let error):
                        print("BANK FAIL: \(error.localizedDescription)")
                        code = 3
                    case .success(let data):
                        let fresh = try? KorgSysEx.program(slot, inBank: data)
                        guard let fresh else { code = 4; sema.signal(); return }
                        print("FRESH     now              slot \(slot) "
                            + "\"\(KorgSysEx.programName(from: fresh))\"")
                        let diffs = zip(baseSlot, fresh).enumerated()
                            .filter { $1.0 != $1.1 }
                        if diffs.isEmpty {
                            print("IDENTICAL — the save did NOT change slot \(slot)")
                        } else {
                            print("\(diffs.count)/254 bytes differ:")
                            for entry in diffs.prefix(30) {
                                let (old, new) = entry.element
                                print(String(format: "  offset %3d: %02X -> %02X",
                                             entry.offset, old, new))
                            }
                        }
                    }
                    sema.signal()
                }
            }
        }
    } catch {
        print("BASELINE FAIL: \(error.localizedDescription)")
        code = 5
        sema.signal()
    }
    _ = sema.wait(timeout: .now() + 70)
    exit(code)
}

// MARK: 3f. Inspect one slot — read-only "does this patch make sound?" dump
//
//   SmokeTest --inspect 10     # panel A.23 (flat 10; the app's old "A11")

if let iIdx = CommandLine.arguments.firstIndex(of: "--inspect"),
   iIdx + 1 < CommandLine.arguments.count,
   let slot = Int(CommandLine.arguments[iIdx + 1]) {
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    guard (0..<128).contains(slot) else { exit(64) }
    DeviceLocator.findDestination(timeout: 3.0) { result in
        switch result {
        case .failure(let error):
            print("LOCATOR FAIL: \(error.localizedDescription)")
            code = 2
            sema.signal()
        case .success(let dest):
            MIDIOutputPort.select(device: dest)
            PBAPI.SysExHandler.loadBank(deviceID: dest.portRef, timeout: 45) { bank in
                switch bank {
                case .failure(let error):
                    print("BANK FAIL: \(error.localizedDescription)")
                    code = 3
                    sema.signal()
                case .success(let data):
                    guard let p = try? KorgSysEx.program(slot, inBank: data) else {
                        code = 4
                        sema.signal()
                        return
                    }
                    let label = ProgramSlot.panelLabel(flat: slot)
                    let t = 38 // timbre-1 base
                    print("SLOT \(label) (index \(slot)) \"\(KorgSysEx.programName(from: p))\"")
                    print(String(format: "byte16=%02X  midiCh=%d  assign=%d  detune=%d", p[16], p[t], p[t+1] >> 6, p[t+2]))
                    print("pitch tune=\(p[t+3]) bend=\(p[t+4]) transpose=\(p[t+5]) vib=\(p[t+6]) porta=\(p[t+15])")
                    print("osc1 wave=\(p[t+7]) dwgs=\(p[t+10]) ctrl1=\(p[t+8]) ctrl2=\(p[t+9]) lvl=\(p[t+16]) | osc2 wave=\(p[t+12] & 3) mod=\((p[t+12] >> 4) & 3) semi=\(p[t+13]) tune=\(p[t+14]) lvl=\(p[t+17]) | noise=\(p[t+18])")
                    print("filter type=\(p[t+19]) cutoff=\(p[t+20]) res=\(p[t+21])")
                    print("EG1 a/d/s/r=\(p[t+30])/\(p[t+31])/\(p[t+32])/\(p[t+33]) int=\(Int8(bitPattern: p[t+22]))")
                    print("EG2 a/d/s/r=\(p[t+34])/\(p[t+35])/\(p[t+36])/\(p[t+37])")
                    print(String(format: "amp lvl=%d pan=%d byte27=%02X velSense=%d kbdTrk=%d", p[t+25], p[t+26], p[t+27], p[t+28], p[t+29]))
                    for slot in 0..<4 {
                        let d = t + 44 + slot * 2
                        print(String(format: "patch%d dest=%d src=%d int=%d", slot + 1, p[d] >> 4, p[d] & 0x0F, Int8(bitPattern: p[d+1])))
                    }
                    print(String(format: "lfo1 wave=%d freq=%d | lfo2 wave=%d freq=%d", p[t+38] & 3, p[t+39], p[t+41] & 3, p[t+42]))
                }
                sema.signal()
            }
        }
    }
    _ = sema.wait(timeout: .now() + 60)
    exit(code)
}

// MARK: 4. Bank dump capture — why does the 128-program load fail?

if bankMode {
    // Capture the RAW reply stream (all frames, not just the first) and show
    // exactly what the synth sent: frame count, per-frame sizes, decode result.
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    DeviceLocator.findDestination(timeout: 1.5) { result in
        switch result {
        case .failure(let error):
            print("LOCATOR FAIL: \(error.localizedDescription)")
            exitCode = 2
            semaphore.signal()
        case .success(let dest):
            print("Bank request -> \(dest.displayName)")
            MIDIOutputPort.sendAndCapture(
                deviceID: dest.portRef,
                data: KorgSysEx.requestAllData(),   // 0x0F: the S's full-bank request
                timeout: 40.0,
                quietInterval: 4.0   // inter-frame gaps may be long; don't stop early
            ) { capture in
                switch capture {
                case .failure(let error):
                    print("CAPTURE FAIL: \(error.localizedDescription)")
                    exitCode = 3
                    semaphore.signal()
                case .success(let raw):
                    print("RAW CAPTURE: \(raw.count) bytes (expect 37392 for one 0x50 frame)")
                    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("bank-capture.syx")
                    try? Data(raw).write(to: url)
                    print("saved -> \(url.path)")

                    // Frame structure: split on F0, ending at each F7.
                    var frames: [[UInt8]] = []
                    var current: [UInt8] = []
                    for byte in raw {
                        if byte == 0xF0 { current = [0xF0] }
                        else if byte == 0xF7 && !current.isEmpty {
                            current.append(0xF7)
                            frames.append(current)
                            current = []
                        } else if !current.isEmpty {
                            current.append(byte)
                        }
                    }
                    if !current.isEmpty { frames.append(current) }
                    print("frames found: \(frames.count)")

                    for (i, frame) in frames.enumerated() {
                        do {
                            let parsed = try KorgSysEx.parse(frame)
                            print(String(
                                format: "  frame %2d: %5d bytes -> cmd 0x%02X, %d decoded",
                                i, frame.count, parsed.command.rawValue, parsed.data.count))
                            if parsed.command == .allDataDump {
                                let bank = try KorgSysEx.bank(fromAllData: parsed.data)
                                let names = try KorgSysEx.programNames(inBank: bank)
                                print("  BANK PARSE OK: \(names.count) names, first: \(names[0 ... 3])")
                            } else if parsed.command == .programDump {
                                let names = try KorgSysEx.programNames(inBank: parsed.data)
                                print("  BANK PARSE OK (classic 4C): \(names.count) names, first: \(names[0 ... 3])")
                            }
                        } catch {
                            print(String(
                                format: "  frame %2d: %5d bytes -> parse FAIL: %@",
                                i, frame.count, error.localizedDescription))
                        }
                    }
                    exitCode = 0
                    semaphore.signal()
                }
            }
        }
    }
    _ = semaphore.wait(timeout: .now() + 45)
    exit(exitCode)
}

// The MicroKORG normally sits behind a USB MIDI interface on 5-pin DIN, so its
// own name never appears in CoreMIDI. Probe whenever asked, or automatically
// when nothing matched by name: 0x10 is read-only, inert on non-Korg devices.
let shouldProbe = probeMode || mkDests.isEmpty

if shouldProbe {
    // Probe every destination (or just --target matches) for a 0x40 reply.
    let filter = targetFilter()
    let candidates = endpoints.filter {
        $0.isDestination
            && (filter == nil
                || $0.displayName.lowercased().contains(filter!)
                || $0.name.lowercased().contains(filter!))
    }
    var hits: [MIDIPortInfo] = []
    for dest in candidates {
        print("\n########## \(dest.displayName) — \(dest.name) ##########")
        if requestProgram(to: dest, timeout: 2.0) {
            hits.append(dest)
        }
    }
    print("\n=== probe summary ===")
    let names = hits.map { $0.displayName }.joined(separator: ", ")
    print("Responding destinations: \(hits.isEmpty ? "none" : names)")
    exit(hits.isEmpty ? 2 : 0)
}

if mkSrcs.isEmpty {
    print("WARNING: destination present but no matching source — SysEx replies will not arrive.")
}

_ = requestProgram(to: mkDests[0], timeout: 5.0)
exit(0)
