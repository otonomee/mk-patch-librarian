import Foundation

// MARK: - Hover help (v15 §3.5)
//
// One plain sentence per parameter, in player vocabulary — signal flow and
// sound, never chart offsets (v15 §1a). Wording is chart- or
// manual-grounded: value tables from docs/microkorg-s-midi-implementation-
// 2026.txt, behavior from the microKORG S Owner's Manual E
// (docs/OwnersManual.txt — EG/trigger on pp.22/32, OSC CTRL 1/2 on pp.18–25,
// pitch on pp.17/23, vocoder on pp.33–37, arpeggiator on pp.44–45).
//
// Keys are exactly the non-reserved `EditorByteCoverage` entry names —
// `EditorHelpTests` pins the set both ways, so a new registry entry without
// help fails the suite. Vocoder (TABLE 3) controls are not registry entries;
// their help is passed inline at the call site.
enum EditorHelp {

    static let byParam: [String: String] = [
        // TABLE 1 — program level
        "name": "The program's name, shown in the bank browser.",
        "voiceMode": "Single = one timbre. Layer = two timbres stacked. Vocoder = process a mic through the synth.",
        "triggerLength": "How many steps the trigger pattern has (1–8).",
        "triggerPattern": "Which trigger steps play a note — checked steps sound.",
        "delaySync": "Match the echo repeats to the song's tempo instead of the free delay-time knob.",
        "delayTimeBase": "The note value the echo repeats in, when Tempo Sync is on.",
        "delayTime": "How long until the echo comes back, when Tempo Sync is off.",
        "delayDepth": "How much echo is mixed into the sound — higher is washy.",
        "delayType": "The echo flavor: Stereo, Cross, or L/R.",
        "modFxSpeed": "How fast the modulation effect sweeps.",
        "modFxDepth": "How strong the modulation effect is.",
        "modFxType": "The modulation effect: Chorus/Flanger, Ensemble, or Phaser.",
        "eqHiFreq": "Which frequencies count as the high band.",
        "eqHiGain": "Boost (+) or cut (−) the high band.",
        "eqLowFreq": "Which frequencies count as the low band.",
        "eqLowGain": "Boost (+) or cut (−) the low band.",
        "arpTempo": "The arpeggiator's speed in beats per minute.",
        "arpEnabled": "Turn the arpeggiator on: held notes become a rhythm pattern.",
        "arpLatch": "Keep the pattern playing after you let go of the keys.",
        "arpTarget": "Which timbre the arpeggiator plays: both, T1, or T2 (Layer programs).",
        "arpKeySync": "Restart the pattern from step 1 on every new note.",
        "arpType": "The order notes play: Up, Down, Alt1, Alt2, Random, or Trigger.",
        "arpRange": "How many octaves the pattern spans.",
        "arpGate": "How long each step's note lasts, as a percent of the step.",
        "arpResolution": "The note value of each step (1/24 … 1/4).",
        "arpSwing": "Shifts every even-numbered step later (+) or earlier (−) for shuffle.",
        "kbdOctave": "Shifts the whole keyboard's pitch up or down by octaves.",

        // TABLE 2 — voice / pitch / oscillators
        "assignMode": "Mono = one note at a time, Poly = normal, Unison = all voices stacked on one note.",
        "triggerModeMulti": "Whether the envelopes and LFO restart on every key while others are held (Multi), or only on the first (Single). Mono/Unison only.",
        "eg1Reset": "Filter EG restarts from zero on every new note (off = each note continues from the current level).",
        "eg2Reset": "Amp EG restarts from zero on every new note (off = each note continues from the current level).",
        "unisonDetune": "How far apart the stacked unison voices are pitched, in cents.",
        "pitchTune": "Fine-tunes the oscillators in cents.",
        "bendRange": "How many semitones the pitch wheel bends at full throw.",
        "pitchTranspose": "Moves the timbre up or down in semitones.",
        "vibratoIntensity": "How deep the vibrato gets when the MOD wheel is pushed all the way.",
        "osc1Wave": "Oscillator 1's starting waveform — the raw material of the sound.",
        "osc1Control1": "Shapes the selected wave: pulse width on Pulse, saw morph on Saw, cross-mod depth on Sin (Cross). No effect on DWGS.",
        "osc1Control2": "How much LFO 1 wobbles what Control 1 shaped (PWM depth on Pulse).",
        "dwgsWave": "Which of the 64 DWGS waveforms oscillator 1 plays (only when the wave is DWGS).",
        "osc2Wave": "Oscillator 2's waveform: Saw, Square, or Tri.",
        "osc2Mod": "How oscillator 2 interacts with oscillator 1: Ring, Sync, or both.",
        "osc2Semitone": "Moves oscillator 2 up or down in semitones — intervals and chords.",
        "osc2Tune": "Fine-tunes oscillator 2 against oscillator 1.",
        "portamento": "Glide speed between notes; 0 is off, higher glides longer.",
        "osc1Level": "How loud oscillator 1 is in the mix.",
        "osc2Level": "How loud oscillator 2 is in the mix.",
        "noiseLevel": "How much noise is mixed in — breath and grit.",

        // TABLE 2 — filter / amp / envelopes
        "filterType": "The filter shape: 24LPF (deepest lowpass), 12LPF, 12BPF, or 12HPF.",
        "filterCutoff": "How much of the buzz gets through — lower is darker.",
        "filterResonance": "Emphasizes frequencies right at the cutoff — higher whistles and squelches.",
        "filterEG1Intensity": "How much the Filter EG sweeps the cutoff; negative sweeps downward.",
        "filterKeyboardTrack": "Opens the cutoff more for high notes (+) or low notes (−).",
        "ampLevel": "The timbre's volume.",
        "panpot": "Where the timbre sits between left and right.",
        "ampDistortion": "Adds drive to the timbre's sound.",
        "ampKeyboardTrack": "Makes high notes louder (+) or quieter (−).",
        "eg1Attack": "How long the filter takes to open after a key press.",
        "eg1Decay": "How long the filter takes to settle from its peak to the sustain level.",
        "eg1Sustain": "How open the filter stays while the key is held.",
        "eg1Release": "How long the filter takes to return after the key is released.",
        "eg2Attack": "How long the sound takes to fade in after a key press.",
        "eg2Decay": "How long the volume takes to settle from its peak to the sustain level.",
        "eg2Sustain": "How loud the sound stays while the key is held.",
        "eg2Release": "How long the sound rings out after the key is released.",

        // TABLE 2 — LFOs
        "lfo1Wave": "LFO 1's shape: Saw, Squ, Tri, or S/H (random steps).",
        "lfo1Frequency": "How fast LFO 1 moves.",
        "lfo1TempoSync": "Lock LFO 1's speed to the song's tempo note values.",
        "lfo1SyncNote": "The note value LFO 1 cycles in, when Tempo Sync is on.",
        "lfo1KeySync": "When LFO 1 restarts: never (Off), on the first note (Timbre), or every note (Voice).",
        "lfo2Wave": "LFO 2's shape: Saw, Squ(+), Sin, or S/H (random steps).",
        "lfo2Frequency": "How fast LFO 2 moves.",
        "lfo2TempoSync": "Lock LFO 2's speed to the song's tempo note values.",
        "lfo2SyncNote": "The note value LFO 2 cycles in, when Tempo Sync is on.",
        "lfo2KeySync": "When LFO 2 restarts: never (Off), on the first note (Timbre), or every note (Voice).",

        // TABLE 2 — virtual patch 1...4
        "patch1Source": "What drives Patch 1: an EG, an LFO, velocity, keyboard position, P.Bend, or Mod.",
        "patch1Destination": "What Patch 1 moves: pitch, osc levels, cutoff, amp, pan, or LFO 2 speed.",
        "patch1Intensity": "How far Patch 1 moves its destination; negative moves it the other way.",
        "patch2Source": "What drives Patch 2: an EG, an LFO, velocity, keyboard position, P.Bend, or Mod.",
        "patch2Destination": "What Patch 2 moves: pitch, osc levels, cutoff, amp, pan, or LFO 2 speed.",
        "patch2Intensity": "How far Patch 2 moves its destination; negative moves it the other way.",
        "patch3Source": "What drives Patch 3: an EG, an LFO, velocity, keyboard position, P.Bend, or Mod.",
        "patch3Destination": "What Patch 3 moves: pitch, osc levels, cutoff, amp, pan, or LFO 2 speed.",
        "patch3Intensity": "How far Patch 3 moves its destination; negative moves it the other way.",
        "patch4Source": "What drives Patch 4: an EG, an LFO, velocity, keyboard position, P.Bend, or Mod.",
        "patch4Destination": "What Patch 4 moves: pitch, osc levels, cutoff, amp, pan, or LFO 2 speed.",
        "patch4Intensity": "How far Patch 4 moves its destination; negative moves it the other way.",
    ]

    /// Resolve a control's tooltip: explicit `help` wins, else the registry
    /// sentence for `param`, else none.
    static func text(param: String?, inline: String?) -> String {
        if let inline { return inline }
        guard let param else { return "" }
        return byParam[param] ?? ""
    }
}
