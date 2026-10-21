import SwiftUI

/// On-screen piano keyboard for hearing the currently-loaded patch before
/// committing it to a slot — press and hold a key, same as pressing a real
/// one. Two octaves visible at once, with ◁/▷ to shift range; the full
/// MIDI note range is reachable, just not all shown at once.
public struct AuditionKeyboard: View {

    @Binding var baseNote: Int
    let onNoteOn: (Int) -> Void
    let onNoteOff: (Int) -> Void

    private let octaveCount = 2
    private let whiteKeyWidth: CGFloat = 26
    private let whiteKeyHeight: CGFloat = 60
    private let blackKeyWidth: CGFloat = 16
    private let blackKeyHeight: CGFloat = 36

    // One octave, white keys in order C D E F G A B: semitone offset, and
    // whether a black key sits immediately after it (none after E or B).
    private let whiteSemitones = [0, 2, 4, 5, 7, 9, 11]
    private let blackFollows = [true, true, false, true, true, true, false]

    private var whiteKeyCount: Int { 7 * octaveCount }
    private var keyboardWidth: CGFloat { CGFloat(whiteKeyCount) * (whiteKeyWidth + 1) }
    private var maxBaseNote: Int { 127 - 11 - 12 * (octaveCount - 1) }

    public init(baseNote: Binding<Int>, onNoteOn: @escaping (Int) -> Void, onNoteOff: @escaping (Int) -> Void) {
        self._baseNote = baseNote
        self.onNoteOn = onNoteOn
        self.onNoteOff = onNoteOff
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button(action: { baseNote = max(0, baseNote - 12) }) {
                Image(systemName: "chevron.left")
            }
            .disabled(baseNote - 12 < 0)
            .pointerCursor()
            .help("Shift the keyboard down an octave")

            ZStack(alignment: .topLeading) {
                HStack(spacing: 1) {
                    ForEach(0..<whiteKeyCount, id: \.self) { i in
                        PianoKeyButton(
                            note: whiteNote(at: i),
                            isBlack: false,
                            onPress: onNoteOn,
                            onRelease: onNoteOff
                        )
                        .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                    }
                }
                ForEach(0..<whiteKeyCount, id: \.self) { i in
                    if blackFollows[i % 7] {
                        PianoKeyButton(
                            note: whiteNote(at: i) + 1,
                            isBlack: true,
                            onPress: onNoteOn,
                            onRelease: onNoteOff
                        )
                        .frame(width: blackKeyWidth, height: blackKeyHeight)
                        .offset(x: CGFloat(i) * (whiteKeyWidth + 1) + whiteKeyWidth - blackKeyWidth / 2)
                    }
                }
            }
            .frame(width: keyboardWidth, height: whiteKeyHeight, alignment: .topLeading)

            Button(action: { baseNote = min(maxBaseNote, baseNote + 12) }) {
                Image(systemName: "chevron.right")
            }
            .disabled(baseNote + 12 > maxBaseNote)
            .pointerCursor()
            .help("Shift the keyboard up an octave")
        }
    }

    private func whiteNote(at i: Int) -> Int {
        baseNote + (i / 7) * 12 + whiteSemitones[i % 7]
    }
}

/// One key: press-and-hold via a zero-distance drag so a plain click still
/// registers as press+immediate release, and a `isDown` guard means the
/// gesture's repeating `onChanged` calls fire the note on exactly once.
private struct PianoKeyButton: View {
    let note: Int
    let isBlack: Bool
    let onPress: (Int) -> Void
    let onRelease: (Int) -> Void

    @State private var isDown = false

    var body: some View {
        Rectangle()
            .fill(fillColor)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isDown else { return }
                        isDown = true
                        onPress(note)
                    }
                    .onEnded { _ in
                        isDown = false
                        onRelease(note)
                    }
            )
            .pointerCursor()
    }

    private var fillColor: Color {
        if isBlack {
            return isDown ? Color(white: 0.4) : Color.black
        }
        return isDown ? PatchTheme.accent.opacity(0.5) : Color.white
    }
}

#Preview {
    AuditionKeyboard(baseNote: .constant(60), onNoteOn: { _ in }, onNoteOff: { _ in })
        .padding()
        .background(Color.black)
}
