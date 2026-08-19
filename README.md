<h1 align="center">Glide</h1>

<p align="center">
An on-device writing assistant for macOS — autocomplete and rewrite, in every app.
</p>

---

Glide watches the focused text field in any macOS app and helps in two ways:

- **Complete** — predicts a short continuation at the cursor and offers it as ghost text you accept with **Tab**.
- **Rewrite** — cleans up the sentence you just typed (grammar, spelling, clumsy phrasing) and offers the fix in place, also on **Tab**.

Both run **on device**. Nothing is sent anywhere unless you explicitly turn on a cloud model.

## Status

| Capability | State |
|---|---|
| Tab-autocomplete across apps | shipping (inherited from KeyType) |
| Sentence rewrite on pause | in progress |
| Grammar / spelling pass | in progress |
| Tone rewrite palette | planned |
| Reply assist (Gmail / Outlook) | planned |

## Installation

Download the latest `Glide.dmg` from [Releases](https://github.com/redclayai/glide/releases), drag it to `/Applications`, and grant Accessibility permission when prompted. Requires macOS 14+ on Apple Silicon.

## Development

Requirements: macOS 14+, a recent Xcode, and the vendored llama.cpp xcframework (see `docs/05-decisions.md`, ADR-007 — it lives outside git at `Packages/ModelRuntime/Vendor/`).

```sh
open Glide.xcworkspace
```

Build/run the **Glide** scheme, or install a side-by-side dev build:

```sh
Scripts/build-dev-app.sh
```

Per-package builds:

```sh
swift build --package-path Packages/AutocompleteCore
swift test  --package-path Packages/TextInsertion
```

Start with `docs/00-overview.md` — the `docs/` folder is the authoritative brief.

## Repo layout

```
Glide/
├── Glide.xcworkspace/        ← open this in Xcode
├── Glide.xcodeproj/
├── Glide/                    ← app target (menu-bar shell)
├── docs/                     ← project brief & playbooks (00–09)
└── Packages/                 ← local SwiftPM packages (the real logic)
    ├── AutocompleteCore/         shared domain types & protocols
    ├── MacContextCapture/        AX focus + caret + text-field snapshot
    ├── Prompting/                sectioned, budgeted prompt builder
    ├── ModelRuntime/             llama.cpp wrapper
    ├── ConstrainedGeneration/    logit masking, trie admissibility, search
    ├── TokenProfiles/            ACPF profile reader + offline builder
    ├── CompletionUI/             overlay rendering (inline ghost text)
    ├── TextInsertion/            insertion & replacement strategies
    └── AppCompatibility/         per-app / per-domain override policy
```

## Built on KeyType

Glide is a fork of [**KeyType**](https://github.com/johnbean393/KeyType) by Xi Nai Lai — an
open-source, on-device tab-autocomplete utility for macOS, MIT licensed. The entire
capture → prompt → model → constrained decode → overlay → insert pipeline is KeyType's work.
Glide adds the rewrite path on top of it.

If you only want autocomplete, use KeyType directly — it's excellent, and upstream.

## License

MIT — see [LICENSE](LICENSE). Upstream copyright is retained alongside modifications.
