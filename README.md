# RetroSolve

A proof-of-concept chess repertoire tool built in Flutter, experimenting with graph-based backpropagation and local engine evaluations for Standard Chess and popular chess variants.

## Overview

Unlike standard PGN viewers that treat repertoires as sequential lines, this tool maps positions into a cyclic transposition graph. By assigning evaluations to individual nodes, it uses a min-max algorithm to backpropagate scores up the tree. This ensures that root opening moves computationally reflect the evaluations of their transposed end-states.

## Technical Details

- **Transposition Graph Solver:** Implemented using Tarjan's Strongly Connected Component (SCC) decomposition ([`lib/graph/graph.dart`](file:///C:/vscode/retro-solve/lib/graph/graph.dart)). It robustly handles complex transposition cycles, correctly identifying draw loops (0.0), and performs topological backward value iteration using a minimax algorithm to dynamically propagate deep child evaluations up the tree, seamlessly overwriting shallow engine static scores.
- **Engine Integration:** Hooks directly into UCI engines (Fairy-Stockfish) to evaluate standard chess and variant positions. Configurable via `Config.engineBinaryName` in [`lib/config.dart`](file:///C:/vscode/retro-solve/lib/config.dart). Automatically detects and loads matching variant NNUE networks (`.nnue`) from the base directory, falling back gracefully to Classical evaluation if a net is omitted.
- **Tablebase-Aware Search & Probing:** Supports Antichess Endgame Tablebases (EGTBs) both in-engine during tree search (finding forced mate lines in milliseconds) and via a local offline HTTP sidecar server.
- **Automated Exploration:** Features a recursive, engine-driven search strategy that automatically traverses unexplored engine-suggested moves, evaluates them at depth 16, and incrementally back-solves evaluations into the transposition graph.
- **Persistence (SQLite):** Utilizes a robust, variant-specific SQLite database to durably store nodes and graph edges, allowing incremental updates, instant loading, and eliminating the visual blocking of bulk flat-file exports.

---

## Engine & NNUE Setup

### 1. Fairy-Stockfish Engine Executables

RetroSolve supports both standard Fairy-Stockfish builds and custom tablebase-aware builds. The active binary is configured in [`lib/config.dart`](file:///C:/vscode/retro-solve/lib/config.dart) via `Config.engineBinaryName`:

```dart
// lib/config.dart
static String engineBinaryName = 'fairySF_egtb_avx2.exe';
```

Two engine executables are provided in the project root:

1. **`fairySF_egtb_avx2.exe` (Default / Recommended for Antichess):**
   - Modified build based on [tolius/fairy-stockfish-egtb](https://github.com/tolius/fairy-stockfish-egtb).
   - Built with DTW Antichess tablebase support (`DTZ101_AS_DRAW = false`, `ALWAYS_SAVE_DTZ = true`).
   - Automatically probes local `.an0` tablebases in `data/tablebases/antichess` via `SyzygyPath`, finding deep forced mates (+M20..+M80) in milliseconds.
2. **`fairy-stockfish_x86-64-modern.exe` (Fallback / General Upstream):**
   - Standard official Fairy-Stockfish development release from [Fairy-Stockfish GitHub Actions](https://github.com/fairy-stockfish/Fairy-Stockfish/actions/workflows/release.yml).
   - If `Config.engineBinaryName` is not found, the service automatically falls back to this binary.

### 2. NNUE Evaluation Networks

Fairy-Stockfish uses Neural Network Efficiently Updatable (NNUE) evaluation files for enhanced positional evaluation across supported variants. 

You can download official variant NNUE evaluation files from the [Fairy-Stockfish NNUE Page](https://fairy-stockfish.github.io/nnue/) or the [Fairy-Stockfish NNUE Google Drive Directory](https://drive.google.com/drive/folders/1m5PpiI3Kjzk_ow7F5RkwKnbO0Td-qb9J).

Place the `.nnue` file(s) directly in the project base directory:

| Variant | Recommended NNUE Net | Download Link |
| :--- | :--- | :--- |
| **King of the Hill** | `kingofthehill-978b86d0e6a4.nnue` | [Download](https://fairy-stockfish.github.io/nnue/) |
| **3-Check** | `3check-cb5f517c228b.nnue` | [Download](https://fairy-stockfish.github.io/nnue/) |
| **Crazyhouse** | `crazyhouse-8ebf84784ad2.nnue` | [Download](https://fairy-stockfish.github.io/nnue/) |
| **Antichess** | `antichess-dd3cbe53cd4e.nnue` | [Download](https://fairy-stockfish.github.io/nnue/) |
| **Atomic** | `atomic-2cf13ff256cc.nnue` | [Download](https://fairy-stockfish.github.io/nnue/) |
| **Horde** | `horde-28173ddccabe.nnue` | [Download](https://fairy-stockfish.github.io/nnue/) |
| **Racing Kings** | `racingkings-636b95f085e3.nnue` | [Download](https://fairy-stockfish.github.io/nnue/) |

> **Note:** If an NNUE file is not present in the project directory for a given variant, RetroSolve will automatically fall back to Classical (handcrafted) evaluation mode.

---

## Endgame Tablebases (EGTB) & Sidecar Server

RetroSolve integrates local Antichess endgame tablebases (up to 4 pieces, 714 `.an0` tables located in `data/tablebases/antichess/`) in two ways:

### 1. In-Engine Syzygy Probing
When running Antichess, `FairyStockfishService` automatically configures the engine with:
```
setoption name SyzygyPath value <path_to_data/tablebases/antichess>
setoption name SyzygyProbeLimit value 4
```
This enables `fairySF_egtb_avx2.exe` to look up DTW scores during search trees, resolving deep lines to exact terminal mates almost instantly.

### 2. Local Tablebase Sidecar Server
For instant GUI board queries without querying online APIs (e.g. Lichess), start the local tablebase sidecar daemon:

```bash
python tool/tablebase_server.py
```

- **Port:** `http://127.0.0.1:8080`
- **Supported variants:**
  - **Antichess:** $\le 4$ pieces offline via `antichess_tb_api.dll` and `data/tablebases/antichess/*.an0`.
  - **Atomic / Standard:** $\le 6$ pieces via local Syzygy `.rtbw` / `.rtbz` if configured.
- **Config toggles ([`lib/config.dart`](file:///C:/vscode/retro-solve/lib/config.dart)):**
  - `Config.enableLocalTablebase = true`: Queries the local sidecar server.
  - `Config.enableRemoteTablebase = true`: Fallback to online Lichess Tablebase API (only when local sidecar is disabled or returns 404).

---

## Running the Application

Start the tablebase sidecar (optional, recommended for offline play):
```bash
python tool/tablebase_server.py
```

Launch the RetroSolve desktop application:
```bash
flutter run -d windows
```

Run test suite:
```bash
flutter test --no-pub
```
