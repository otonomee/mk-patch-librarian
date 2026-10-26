# App Review Screen Recording — Walkthrough Script

For Apple's Guideline 2.1 request: a screen recording on a physical device, starting with launch, showing the typical user flow.

## Before you hit record

- Quit any running copy of the app first.
- Plug in the MIDI interface (UM-ONE) and power on the microKORG — do this *before* you start recording so the first launch can show a real connection, not a "searching" state sitting there for a minute.
- Close Slack/Messages/anything that could pop a notification mid-recording.
- Open QuickTime Player → File → New Screen Recording → **record the whole screen**, not a selected window. The app window doesn't exist yet at this point (you haven't launched it), so there's nothing to click-select — QuickTime can only snap to a specific window's bounds *after* that window is already open, which would miss the actual launch moment Apple wants to see. Full screen is the simplest correct choice; a bit of desktop around the window in the final video is fine.
- Click Record, *then* launch the app from Applications/Dock as your first on-camera action.

## Beats to hit, in order

1. **Launch.** Open MK Patch Librarian from Applications or Dock. Let the Bank Browser render and the footer resolve to "Connected to microKORG" before moving on — don't cut this short, it's the first thing a reviewer sees.
2. **Browse the grid.** Scroll through a bank or two. Nothing needs narration here, just show it's a real, responsive grid of real patch data from the synth.
3. **Open a patch.** Click any patch cell. Let the full editor load — oscillators, filter, envelopes, the works. Scroll through a couple of sections so it's clear this isn't a single static screen.
4. **Audition it.** Click a key or two on the on-screen keyboard. (The synth will actually make sound here — that's fine, expected, and proves the MIDI link is live both directions.)
5. **Back to the browser**, then open **Settings** (⌘,). Show the MIDI connection status live, and the synth's own global settings loaded from the hardware (channel, tune, etc.). Don't click Save — just show it's real, populated data, not placeholders.
6. **Import flow.** Back in the browser, click "Import Sound Bank…", pick any `.prg`/`.set`/`.syx` file from the picker, and show the Source Queue / Destination Map screen populate. Click "Done" without actually committing the import — no need to overwrite anything live, showing the screen is enough.

That's the whole flow. No login anywhere, because there isn't one — nothing to skip, nothing to fake.

## Length

Apple doesn't give a hard limit, but shorter and complete beats longer and padded. 60–90 seconds covers everything above without feeling rushed. Don't narrate over it unless you want to — the flow speaks for itself.

## After recording

- QuickTime saves as `.mov` — that's fine to attach directly in App Store Connect's reply, no conversion needed.
- Watch it back once before attaching. Confirm the footer actually says "Connected" at some point in frame — that's the detail a reviewer is specifically checking for given the rejection reason.
