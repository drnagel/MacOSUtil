# Contributing

Thanks for helping make MacOSUtil better! The easiest and most useful way to contribute is the **catalog**: settings, apps and Setup Assistant profiles, all in plain JSON under [`Catalog/`](Catalog).

## Adding a setting

1. Pick the category file in `Catalog/tweaks/` (or create a new one: `70-name.json`).
2. Add an entry. The `id` must start with the category id:

   ```json
   {
     "id": "dock.autohide",
     "title": { "en": "Automatically hide the Dock", "es": "Ocultar el Dock automáticamente" },
     "description": { "en": "…", "es": "…" },
     "tested": "27",
     "risk": "low",
     "actions": [
       { "type": "defaults", "domain": "com.apple.dock", "key": "autohide", "valueType": "bool", "value": true }
     ],
     "restart": ["Dock"]
   }
   ```

   | Field | Meaning |
   |---|---|
   | `title`, `description` | Both `en` and `es` are required. Describe the effect, not the key. |
   | `tested` | Latest macOS major version you checked it on. |
   | `risk` | `low` (default), `medium` or `high` — shown as a badge. |
   | `actions` | Only `defaults` actions exist. `valueType` is `bool`, `int`, `float` or `string`. Add `"currentHost": true` for per-host preferences. |
   | `restart` | Processes to relaunch once after applying (`Finder`, `Dock`, `SystemUIServer`…). |
   | `logout` | `true` if the change only fully applies after logging out. |
   | `macos` | Optional `{ "min": "15", "max": "27" }` hard limits. |

3. Try it on your Mac: apply it from the app, check that it does what the description says, then *Restore All* and check it's back.

Some options can't be changed from outside System Settings. For those, add a `links` entry that opens the exact pane (`x-apple.systempreferences:` URLs only).

## Adding an app

Add it to a category in `Catalog/apps.json` with its Homebrew cask token (`brew info --cask <token>` must work) or a Mac App Store id plus `appName`. Prefer well-maintained, widely used apps; open source is a plus.

## Validate

```bash
swift build
.build/debug/MacOSUtil --catalog validate Catalog
```

The same check runs on every pull request: structure, unique ids, settings links, profile references and translations.

## Interface translations

Interface texts are keyed by the Spanish text in the source code and translated in [`Localization/en.json`](Localization/en.json). If you add a text to the UI, wrap non-SwiftUI strings in `L("…")` and add its English translation; `Scripts/build.sh` fails if one is missing.

## Signed catalog

After merging, the maintainer bumps the catalog version and signs it with `Scripts/publish-catalog.sh`, which writes `dist/catalog.json` and `dist/catalog.json.sig`. The app only accepts catalog updates signed with the maintainer's key.
