# Nikita (mobile)

The Flipper iOS app's port of the desktop **nikita-qflipper** assistant: an LLM
agent with tool-calling, running on the Moonshot **Kimi** API, that drives the
connected Flipper Zero over Bluetooth.

This package is self-contained (Foundation only) and decoupled from the BLE
stack: it talks to the device through the `NikitaDeviceBridge` protocol, which
the app target implements (`iOS/UI/Nikita/LiveDeviceBridge.swift`) on top of
`Core.Dependencies`.

## What it can do

Because an iPhone reaches the Flipper only over **BLE** — no USB, no text CLI,
no shell of its own — the toolbox is the desktop's BLE shape:

| Tool | Backed by |
|---|---|
| `list_files` `read_file` `save_file` `make_dir` `delete_file` `rename_file` `file_info` | `StorageAPI` (RPC storage) |
| `read_screen` | `GUIAPI` framebuffer → ASCII |
| `press_button` (up/down/left/right/ok/back) | `GUIAPI.pressButton` |
| `run_app` (open/close) | `ApplicationAPI.start` / `.exit` |
| `remember` `list_memory` `forget` | local `nikita-memory.txt` |

There is deliberately **no** `run_cli` and **no** `computer_*`: neither the
Flipper CLI nor a host filesystem is reachable from the phone over Bluetooth.

## Setup

Nikita is off until the user adds a Moonshot API key in its settings
(Hub → Nikita → Settings). The key is stored in the iOS Keychain and sent only
to `api.moonshot.ai`. Model defaults to `kimi-k2.6`; `kimi-k3` is selectable.

## Files

- `KimiClient.swift` — OpenAI-compatible `/chat/completions`, non-streamed.
- `NikitaAgent.swift` — the turn loop: prompt → model → tool calls → results → repeat.
- `Tools.swift` — the offered tool schemas + access-filter gating.
- `SystemPrompt.swift` — the mobile persona/manual.
- `Settings.swift` — Keychain key, model, per-family access filters.
- `Memory.swift` — durable user facts.
- `DeviceBridge.swift` — the protocol the app target implements.
