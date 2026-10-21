# microKORG S — panel-operation facts (sourced; no guessing)

Source: `docs/OwnersManual.pdf` (microKORG S Owner's Manual E, 2016-09-01,
80 pages; text at `docs/OwnersManual.txt`, extracted with PDFKit — page
markers `===== PAGE N =====` are PDF pages). Citations give the manual's
printed page and the txt line. **Panel claims in code comments, handoffs, or
user-facing text must cite this file or the manual — never memory.** A prior
session improvised "hold SHIFT + TIMBRE SELECT" style instructions from
memory; every one of those guesses was wrong. Facts live here now.

## Timbres in Layer mode (p.14; txt 1173–1217)

- **TIMBRE SELECT is a dedicated panel key** (between the display and the
  program buttons; has its own LEDs — TIMBRE SELECT 1/2). Press it once:
  switches which timbre you edit, corresponding LED lights. No SHIFT.
  (txt 1186–1188)
- **Edit Sync**: hold TIMBRE SELECT ≥ 2 s → both LEDs light; edits apply to
  BOTH timbres at once. Display shows T1's value; T1's value is the starting
  point of any knob move. Press TIMBRE SELECT once to cancel (back to T1).
  Edit Sync is NOT saved with the program. (txt 1189–1196, 1199)
- **Solo**: hold SHIFT + TIMBRE SELECT → only the edited timbre sounds (its
  LED blinks). Press again (shift held) to solo+select the other timbre.
  Plain TIMBRE SELECT cancels Solo. Solo is NOT saved. Works even while
  Edit Sync is on. (txt 1197–1212)
- **Swap/Copy timbres** are in EDIT SELECT 2 → SYNTH section (p.59), not on
  the TIMBRE SELECT key. (txt 1213–1217)

## What "a timbre" is, on the panel (p.14; txt 1174–1179)

- A timbre = EDIT SELECT 1 VOICE (except SYNTH/VOCODER and SINGLE/LAYER)
  through LFO2, PLUS EDIT SELECT 2 PATCH 1–4.
- The VOICE section's **SYNTH/VOCODER and SINGLE/LAYER parameters apply to
  the whole program** (both timbres).
- Matches the byte layout the editor uses: voice mode = program-level
  byte 16 (TABLE 1); everything else per-timbre (TABLE 2, base 38/146).

## Setting voice mode on the panel (p.14; txt 1180–1182)

- EDIT SELECT 1 knob → VOICE, **knob 2** selects SINGLE/LAYER.
- Vocoder programs do not allow timbre switching. (txt 862)

## Performance Edit — the program buttons are live controls (pp.14–15; txt 690–749)

- Press the lit PROGRAM NUMBER key: the 5 edit knobs become
  1 CUTOFF, 2 RESONANCE, 3 FILTER EG + AMP EG ATTACK, 4 EG RELEASE, 5 TEMPO.
- Cancel: press the lit program key again, or turn EDIT SELECT 1/2, or
  SHIFT + BANK SIDE.

## Saving (WRITE key) (p.62–63 area; txt 4446–4487)

- Press WRITE → current program number blinks → select destination program
  number → press WRITE again to commit. SHIFT cancels (its LED lights as
  the cancel key).
- WRITE with write-protect on: display blinks "Protect" — turn protect off
  in SHIFT functions (p.63). (This is the Protect ON used for safe write
  tests; matches the repo's MIDI-level write-protection facts.)
- Edits are volatile: lost on power-off or program change unless written.
- Never power off during a write.

## SYNTH section functions (EDIT SELECT 2 → SYNTH) (p.59; txt 4545–4593)

- **COPY TIMBRE** (key 1): copy a timbre's settings from another program.
- **SWAP TIMBRE** (SHIFT + key 2, confirm on blinking key 2): exchange T1/T2
  settings within the current program. Layer programs only — Single gives
  an error. (txt 4558–4577)
- **INIT PROGRAM** (SHIFT + key 3, confirm): initializes the selected
  program — **and sets it as a Single program**. (txt 4578–4583) Relevant
  to `MicroKORGProgram.blank()`: the synth's own init is Single mode.

## Open questions (do not guess; measure or find the page)

- What exact parameter values INIT PROGRAM writes (the manual doesn't say;
  measure with `SmokeTest --inspect` after a panel init, or compare the
  factory D-bank program which v10 measured as a saw/cutoff-127 init).
- Edit Sync's effect on PATCH 1–4 (per-timbre, so presumably synced like
  everything else) — not stated explicitly.
- Panel behavior differences vs the original microKORG (this manual is the
  S; the original's manual is the PDF at the cdn.korg.com URL in
  HANDOFF-v12.md §2) — when citing the original, say so.
