<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/tokenbar-banner-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/tokenbar-banner-light.png">
    <img alt="TokenBar" src="docs/assets/tokenbar-banner-light.png" width="600">
  </picture>
</p>

<p align="center">
  <strong>Know what your AI tools cost. Right from your menu bar.</strong>
</p>

<p align="center">
  <a href="https://github.com/saphid/TokenBar/releases"><img src="https://img.shields.io/github/v/release/saphid/TokenBar?style=for-the-badge&color=blue" alt="Release"></a>
  <a href="https://github.com/saphid/TokenBar/blob/main/LICENSE"><img src="https://img.shields.io/github/license/saphid/TokenBar?style=for-the-badge" alt="License"></a>
  <a href="https://github.com/saphid/TokenBar/stargazers"><img src="https://img.shields.io/github/stars/saphid/TokenBar?style=for-the-badge" alt="Stars"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.10-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.10">
</p>

---

TokenBar is a lightweight macOS menu bar app that tracks token usage and spending across your AI coding tools. It auto-detects installed providers and shows real-time usage stats at a glance.

This fork fixes opening and reopening the settings window on macOS, adds
Grok Bot and Antigravity usage providers, and keeps a compact menu bar icon
when the full provider strip would be too wide.

<p align="center">
  <img src="docs/assets/screenshot.png" alt="TokenBar screenshot" width="500">
</p>

## Features

- **Menu bar native** -- lives in your macOS menu bar, always one click away
- **Auto-detection** -- scans your system for installed AI tools on first launch
- **Real-time usage tracking** -- monitors token consumption and cost via provider APIs
- **Multi-provider** -- supports the tools developers actually use (see list below)
- **Keychain storage** -- API keys are stored in macOS Keychain, never in plain text
- **Zero dependencies** -- pure Swift, no Electron, no web views

## Supported Providers

### Usage Tracking (API-connected)

| Provider | What's tracked |
|----------|---------------|
| **Cursor** | Plan usage, token consumption |
| **Claude Code** | Token usage via Anthropic API |
| **OpenAI / ChatGPT** | Spend, token usage, budget tracking |
| **GitHub Copilot** | Seat usage, completions |
| **Codex** | Multi-org usage tracking |
| **Kilo Code** | Token consumption |
| **OpenCode** | Usage stats |
| **Grok Bot** | Weekly plan usage and reset time |
| **Antigravity** | Separate model-group quotas and reset times via the official `agy` CLI |

### Auto-Detection (presence monitoring)

Aider, Amazon Q, Cline, Cody, Continue, Gemini, Minimax, Ollama, OpenRouter, Tabnine, Windsurf, Zai

TokenBar checks for installed apps, CLI tools, and VS Code/Cursor/Windsurf extensions to detect which providers you have.

## Install

### From source (recommended)

```bash
git clone https://github.com/ErdonChen/TokenBar.git
cd TokenBar
make install
```

This builds a release binary, bundles it into `TokenBar.app`, and copies it to `/Applications`.

### Development

```bash
git clone https://github.com/ErdonChen/TokenBar.git
cd TokenBar
make run
```

### Requirements

- macOS 14 (Sonoma) or later
- Swift 5.10+
- Xcode Command Line Tools (`xcode-select --install`)

## How It Works

```
┌─────────────────────────────────────────────────┐
│                  macOS Menu Bar                  │
│                   ┌───────┐                      │
│                   │ 42.5% │ ← TokenBar           │
│                   └───┬───┘                      │
├───────────────────────┼─────────────────────────┤
│                       │                          │
│    ┌──────────────────▼──────────────────┐       │
│    │          ProviderManager            │       │
│    │  Orchestrates providers, polling,   │       │
│    │  config persistence, detection      │       │
│    └──────┬──────────┬──────────┬───────┘       │
│           │          │          │                │
│    ┌──────▼───┐ ┌────▼────┐ ┌──▼───────┐       │
│    │  Cursor  │ │ OpenAI  │ │ Claude   │  ...   │
│    │ Provider │ │Provider │ │ Code     │        │
│    └──────────┘ └─────────┘ └──────────┘        │
│           │          │          │                │
│    ┌──────▼──────────▼──────────▼───────┐       │
│    │         Provider APIs              │       │
│    │   (polling on configurable         │       │
│    │    intervals, usage endpoints)     │       │
│    └────────────────────────────────────┘       │
│                                                  │
│    ┌────────────────────────────────────┐       │
│    │    macOS Keychain (API keys)       │       │
│    │    UserDefaults (config, prefs)    │       │
│    └────────────────────────────────────┘       │
└─────────────────────────────────────────────────┘
```

## Configuration

On first launch, TokenBar scans your system and enables detected providers automatically. Open **Settings** (click the menu bar icon → gear) to:

- Add or remove providers
- Enter API keys (stored in Keychain)
- Set monthly budgets
- Configure display preferences
- Reorder providers

The Settings UI uses a sidebar + detail panel layout (macOS System Settings style) -- no nested dialogs.

Grok Bot uses its existing local sign-in to read its own dashboard service.
macOS may ask you to allow TokenBar to access Grok Bot's Safe Storage keychain
item. If live access is unavailable, a recent app usage cache is shown with its
original update time; cached data is explicitly labelled.

Antigravity requires the [official `agy` CLI](https://antigravity.google/docs/cli/headless/)
and an existing Antigravity sign-in. TokenBar runs the read-only `agy -p /usage`
command; it does not send a model prompt. Its separate model pools are displayed
individually, so exhausting one group does not mark every model as unavailable.

Click the TokenBar gauge icon in the macOS menu bar to view usage cards. If many
providers are enabled, the icon stays compact to avoid disappearing behind the
display notch or other menu bar items. Reopening TokenBar also opens Settings,
where selecting a provider shows its current data.

## Project Structure

```
Sources/
├── TokenBar/              # App entry point
└── TokenBarLib/
    ├── Domain/            # Models, config schema, provider registry
    ├── Providers/
    │   ├── Trackable/     # API-connected providers (Cursor, OpenAI, etc.)
    │   └── DetectionOnly/ # Presence-detected providers (Aider, Ollama, etc.)
    └── Views/             # SwiftUI views (Settings, menu bar popover)
Tests/
└── TokenBarTests/         # Unit tests
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

**Adding a new provider**: Implement the `RegisteredProvider` protocol and add it to `ProviderRegistry.all`. For detection-only providers, define the file paths, commands, or extension patterns to check. For trackable providers, implement the API polling logic in a `UsageProvider`.

## License

MIT -- see [LICENSE](LICENSE) for details.

## Acknowledgments

Built with Swift and SwiftUI. No external dependencies.
