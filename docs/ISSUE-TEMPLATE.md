# Reporting a problem

Copy the template at the bottom into your report. The two attachments
that make a report actionable land in one or two clicks:

- **A replay clip.** Open rewind (F4), A/B-select the moment, press
  **export replay** — the `.ctrace` written to `replays/` beside
  `engine/` is fully standalone (it embeds the project, code, and
  inputs) and replays bit-exactly on any machine: drag it into any
  editor to check it captured the problem.
- **A crash report.** A crash writes a `.ccrash` into the diagnostics
  folder (the console/log names the exact path when it happens); it
  embeds the last minute of history. For a hard native crash on
  Windows, also attach the newest minidump and diagnostics log from
  the same folder.

Screenshots welcome; for visual issues they beat prose.

## Template

    engine version:   (the VERSION file in the install; git rev if source)
    platform:         (Windows native / Linux / WSL2 + distro)
    install kind:     (portable archive / source build / exported player)
    project:          (bundled demo name, own project, or template + steps)

    what happened:

    what you expected:

    steps to reproduce:
      1.
      2.

    attachments:      (.ctrace replay / .ccrash / screenshots)

    how often:        (always / sometimes / once)
