# RetroSolve

A proof-of-concept chess repertoire tool built in Flutter, experimenting with graph-based backpropagation and local engine evaluations for Standard Chess and King of the Hill (KOTH).

## Overview

Unlike standard PGN viewers that treat repertoires as sequential lines, this tool maps positions into a cyclic transposition graph. By assigning evaluations to individual nodes, it uses a min-max algorithm to backpropagate scores up the tree. This ensures that root opening moves computationally reflect the evaluations of their transposed end-states.

## Technical Details

- **Transposition Graph Solver:** Implemented using Tarjan's Strongly Connected Component (SCC) decomposition (`lib/graph/graph.dart`). It robustly handles complex transposition cycles, correctly identifying draw loops (0.0), and performs topological backward value iteration using a minimax algorithm to dynamically propagate deep child evaluations up the tree, seamlessly overwriting shallow engine static scores.
- **Engine Integration:** Hooks directly into `fairy-stockfish_x86-64-modern.exe` via the UCI protocol to evaluate standard and variant positions. Requires a compatible NNUE net (e.g., `kingofthehill*.nnue`) configured in the root directory.
- **Automated Exploration:** Features a recursive, engine-driven search strategy that automatically traverses unexplored engine-suggested moves, evaluates them at depth 16, and incrementally back-solves evaluations into the transposition graph.
- **Persistence (SQLite):** Utilizes a robust, variant-specific SQLite database to durably store nodes and graph edges, allowing incremental updates, instant loading, and eliminating the visual blocking of bulk flat-file exports.

## Setup

Place the required binaries in your base directory alongside your `data/KOTH.txt` file:
- `fairy-stockfish_x86-64-modern.exe` (To get the latest development version:
  1. Go to [Fairy-Stockfish GitHub Actions](https://github.com/fairy-stockfish/Fairy-Stockfish/actions/workflows/release.yml)
  2. Make sure you are logged into GitHub
  3. Select the most recent run against the `master` branch
  4. Select **Artifacts** (scroll down if necessary)
  5. Download and unzip the appropriate archive
  6. Choose the appropriate `.exe` and copy it to the project base directory)
- `kingofthehill-*.nnue`


**Run:**
```bash
flutter run -d windows
```

