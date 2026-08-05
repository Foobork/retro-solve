# RetroSolve

A proof-of-concept chess repertoire tool built in Flutter, experimenting with graph-based backpropagation and local engine evaluations for Standard Chess and popular chess variants.

## Overview

Unlike standard PGN viewers that treat repertoires as sequential lines, this tool maps positions into a cyclic transposition graph. By assigning evaluations to individual nodes, it uses a min-max algorithm to backpropagate scores up the tree. This ensures that root opening moves computationally reflect the evaluations of their transposed end-states.

## Technical Details

- **Transposition Graph Solver:** Implemented using Tarjan's Strongly Connected Component (SCC) decomposition ([`lib/graph/graph.dart`](file:///C:/vscode/retro-solve/lib/graph/graph.dart)). It robustly handles complex transposition cycles, correctly identifying draw loops (0.0), and performs topological backward value iteration using a minimax algorithm to dynamically propagate deep child evaluations up the tree, seamlessly overwriting shallow engine static scores.
- **Engine Integration:** Hooks directly into `fairy-stockfish_x86-64-modern.exe` via the UCI protocol to evaluate standard chess and variant positions. Automatically detects and loads matching variant NNUE networks (`.nnue`) from the base directory, falling back gracefully to Classical evaluation if a net is omitted.
- **Automated Exploration:** Features a recursive, engine-driven search strategy that automatically traverses unexplored engine-suggested moves, evaluates them at depth 16, and incrementally back-solves evaluations into the transposition graph.
- **Persistence (SQLite):** Utilizes a robust, variant-specific SQLite database to durably store nodes and graph edges, allowing incremental updates, instant loading, and eliminating the visual blocking of bulk flat-file exports.

## Engine & NNUE Setup

Place `fairy-stockfish_x86-64-modern.exe` and the desired `.nnue` network files directly in the project base directory.

### 1. Fairy-Stockfish Engine

Download the latest development build:
1. Visit [Fairy-Stockfish GitHub Actions](https://github.com/fairy-stockfish/Fairy-Stockfish/actions/workflows/release.yml) (GitHub login required).
2. Select the most recent run on the `master` branch.
3. Under **Artifacts** (at the bottom of the page), download and extract the Windows archive.
4. Copy `fairy-stockfish_x86-64-modern.exe` into the project base directory.

### 2. NNUE Evaluation Networks

Fairy-Stockfish uses Neural Network Efficiently Updatable (NNUE) evaluation files for enhanced positional evaluation across supported variants. 

You can download official variant NNUE evaluation files from the [Fairy-Stockfish NNUE Page](https://fairy-stockfish.github.io/nnue/) or the [Fairy-Stockfish NNUE Google Drive Directory](https://drive.google.com/drive/folders/1m5PpiI3Kjzk_ow7F5RkwKnbO0Td-qb9J).

Save the corresponding `.nnue` file(s) in the project base directory:

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

## Running the Application

```bash
flutter run -d windows
```
