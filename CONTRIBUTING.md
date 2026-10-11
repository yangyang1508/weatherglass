# Contributing

Thank you for helping! Bug reports, ideas and pull requests are all welcome.

## Report a bug

Open an issue and tell us:

- your macOS version and Mac (Apple silicon or Intel), and how many displays you use;
- what you did, what you expected, and what happened;
- a screen recording if you can. Weatherglass can record itself only (see below), so you do not have to show your screen.

## Build and test

```bash
swift build
swift test                                  # tests for WeatherglassCore
swift run Weatherglass --preview snow       # rain, storm, snow, blizzard, drizzle, fog, wind, hail
swift run Weatherglass --demo storm --settings weatherglass.dev
```

- `--settings <name>` keeps your test settings apart from your real ones.
- `--demo` shows a made-up desktop. `scripts/record-demo.sh <weather>` records it to `docs/media` and
  captures only Weatherglass's own windows.
- `scripts/build-app.sh` makes `dist/Weatherglass.app`.

## Where things are

- `Sources/WeatherglassCore`: logic without AppKit (Open-Meteo, weather mapping, snow model). Add tests here.
- `Sources/Weatherglass`: the app. `Stage.swift` runs the overlays; `Effects/` has one file per effect.

## Pull requests

- Keep each pull request to one change.
- Run `swift test` before you push. CI builds and tests every pull request.
- For a new effect, check the cost: Weatherglass should stay at a few percent of one CPU core.
- Write comments and user-facing text in short, plain English.
