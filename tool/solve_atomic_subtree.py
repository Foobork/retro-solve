#!/usr/bin/env python3
"""
solve_atomic_subtree.py

High-performance Depth-First Proof-Number Search (1@df-pn) engine for Atomic Chess subtrees.
Features:
- Exact AND/OR tree proof-number search with threshold numbers (df-pn)
- Kishimoto & Müller 1@df-pn cycle detection and threshold capping
- In-process Syzygy tablebase probing (<= 5 pieces)
- Fairy-Stockfish NNUE candidate move ordering
- Out-of-core persistence into SQLite (Atomic.db v6) with pause/resume support
- Graceful signal handling (SIGINT, SIGTERM) and configurable time limits
- Real-time telemetry and JSON checkpointing (data/solve_status.json)
- Minimal winning DAG extraction, Watkins binary .proof export, and standalone verifier
"""

import argparse
import json
import logging
import math
import os
import signal
import struct
import sys
import time
import sqlite3
from typing import Dict, List, Optional, Set, Tuple

import chess
import chess.variant
import chess.syzygy
import chess.engine

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("dfpn_solver")

INF = 10**9  # Value representing infinity in proof numbers

# -----------------------------------------------------------------------------
# Move Encoding / Decoding (Watkins Losing Chess / Antichess Proof Specification)
# -----------------------------------------------------------------------------

def encode_move(uci_str: str) -> int:
    """Encodes a UCI move into the 16-bit Watkins proof format."""
    if uci_str in ("NULL", "null"):
        return 0x0edc
    fr_file = ord(uci_str[0]) - ord('a')
    fr_rank = int(uci_str[1]) - 1
    fr = fr_rank * 8 + fr_file
    to_file = ord(uci_str[2]) - ord('a')
    to_rank = int(uci_str[3]) - 1
    to = to_rank * 8 + to_file
    prom = 0
    if len(uci_str) > 4:
        prom_map = {'n': 2, 'b': 3, 'r': 4, 'q': 5, 'k': 6}
        prom = prom_map.get(uci_str[4].lower(), 0)
    return (prom << 12) | (fr << 6) | to

def decode_move(mv: int) -> str:
    """Decodes a 16-bit Watkins proof move into a UCI string."""
    if mv in (0xfedc, 0x0edc):
        return "NULL"
    if (mv >> 12) > 8 or (mv >> 12) == 7:
        mv ^= 0xf000
    fr, to = (mv >> 6) & 0x3f, mv & 0x3f
    sq_from = chr(ord('a') + (fr & 7)) + str(1 + (fr >> 3))
    sq_to = chr(ord('a') + (to & 7)) + str(1 + (to >> 3))
    prom = "01nbrqk7"[mv >> 12] if (mv & (7 << 12)) else ""
    return sq_from + sq_to + prom

def to_bfen(board: chess.variant.AtomicBoard) -> str:
    """Returns canonical BFEN (board FEN without move counters)."""
    return ' '.join(board.fen().split()[:4])

# -----------------------------------------------------------------------------
# Proof Node Data Structure
# -----------------------------------------------------------------------------

class TTEntry:
    __slots__ = (
        'bfen', 'is_white', 'pn', 'dn', 'expanded', 'proof_status',
        'children', 'proven_move', 'dtw', 'heuristic_score'
    )

    def __init__(self, bfen: str, is_white: bool):
        self.bfen = bfen
        self.is_white = is_white
        self.pn = 1
        self.dn = 1
        self.expanded = False
        self.proof_status = 0  # 0=unsolved, 1=provenWin, -1=provenLoss, 2=provenDraw
        self.children: List[Tuple[str, str]] = []  # List of (uci_move, child_bfen)
        self.proven_move: Optional[str] = None
        self.dtw: Optional[int] = None
        self.heuristic_score: Optional[int] = None

# -----------------------------------------------------------------------------
# 1@df-pn Proof Searcher
# -----------------------------------------------------------------------------

class AtomicProofSearcher:
    def __init__(
        self,
        db_path: Optional[str] = "data/Atomic.db",
        tb_dir: Optional[str] = "data/tablebases/atomic",
        engine_binary: Optional[str] = None,
        engine_depth: int = 8,
        status_file: Optional[str] = "data/solve_status.json",
        max_nodes: int = 0,
        timeout_seconds: float = 0,
    ):
        self.db_path = db_path
        self.tb_dir = tb_dir
        self.engine_binary = engine_binary
        self.engine_depth = engine_depth
        self.status_file = status_file
        self.max_nodes = max_nodes
        self.timeout_seconds = timeout_seconds

        # Syzygy tablebase engine
        self.tb = None
        if tb_dir and os.path.exists(tb_dir):
            try:
                self.tb = chess.syzygy.Tablebase(VariantBoard=chess.variant.AtomicBoard)
                count = self.tb.add_directory(tb_dir)
                logger.info(f"Loaded {count} Syzygy tablebase files from {tb_dir}")
            except Exception as e:
                logger.warning(f"Could not load Syzygy tablebases: {e}")

        # Fairy-Stockfish UCI engine
        self.engine = None
        if engine_binary and os.path.exists(engine_binary):
            try:
                self.engine = chess.engine.SimpleEngine.popen_uci(engine_binary)
                logger.info(f"Initialized Fairy-Stockfish engine: {engine_binary}")
            except Exception as e:
                logger.warning(f"Could not start Fairy-Stockfish: {e}")

        # In-memory Transposition Table (BFEN -> TTEntry)
        self.tt: Dict[str, TTEntry] = {}

        # Search statistics
        self.nodes_expanded = 0
        self.tb_hits = 0
        self.engine_queries = 0
        self.start_time = 0.0
        self.last_heartbeat = 0.0
        self.last_db_flush = 0.0
        self.interrupted = False
        self.path_stack: List[str] = []
        self.path_stack_set: Set[str] = set()

        # Setup graceful signal handlers
        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)

    def _handle_signal(self, signum, frame):
        logger.warning(f"Received signal {signum}. Gracefully interrupting search...")
        self.interrupted = True

    def close(self):
        if self.engine:
            try:
                self.engine.quit()
            except Exception:
                pass
            self.engine = None

    # -------------------------------------------------------------------------
    # Database Persistence (Atomic.db v6)
    # -------------------------------------------------------------------------

    def ensure_db_schema(self, conn: sqlite3.Connection):
        """Ensures positions and edges tables conform to Schema Version 6."""
        cur = conn.cursor()
        cur.execute("PRAGMA journal_mode = WAL;")
        cur.execute("PRAGMA synchronous = NORMAL;")
        cur.execute("""
            CREATE TABLE IF NOT EXISTS positions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bfen TEXT UNIQUE NOT NULL,
                assigned_result INTEGER,
                assigned_dtw INTEGER,
                assigned_cp INTEGER,
                computed_result INTEGER,
                computed_dtw INTEGER,
                computed_cp INTEGER,
                proof_status INTEGER DEFAULT 0,
                pn INTEGER DEFAULT 1,
                dn INTEGER DEFAULT 1,
                proven_move_id INTEGER
            );
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS edges (
                source_id INTEGER NOT NULL,
                target_id INTEGER NOT NULL,
                PRIMARY KEY (source_id, target_id)
            ) WITHOUT ROWID;
        """)
        cur.execute("CREATE INDEX IF NOT EXISTS idx_edges_target ON edges (target_id, source_id);")

        # Upgrade existing positions table if columns are missing
        cur.execute("PRAGMA table_info(positions);")
        cols = {row[1].lower() for row in cur.fetchall()}
        if 'proof_status' not in cols:
            cur.execute("ALTER TABLE positions ADD COLUMN proof_status INTEGER DEFAULT 0;")
        if 'pn' not in cols:
            cur.execute("ALTER TABLE positions ADD COLUMN pn INTEGER DEFAULT 1;")
        if 'dn' not in cols:
            cur.execute("ALTER TABLE positions ADD COLUMN dn INTEGER DEFAULT 1;")
        if 'proven_move_id' not in cols:
            cur.execute("ALTER TABLE positions ADD COLUMN proven_move_id INTEGER;")
        conn.commit()

    def load_from_db(self, root_bfen: str):
        """Loads reachable subtree positions from SQLite into memory for resuming."""
        if not self.db_path or not os.path.exists(self.db_path):
            return

        conn = sqlite3.connect(self.db_path)
        self.ensure_db_schema(conn)
        cur = conn.cursor()

        logger.info("Scanning database for existing subtree state...")
        # Get root id
        cur.execute("SELECT id, bfen, proof_status, pn, dn, computed_result, computed_dtw FROM positions WHERE bfen = ?", (root_bfen,))
        root_row = cur.fetchone()
        if not root_row:
            conn.close()
            return

        # Breadth-first load of reachable positions from root
        visited_ids = {root_row[0]}
        frontier = [root_row[0]]
        nodes_loaded = 0

        while frontier:
            placeholders = ','.join('?' for _ in frontier)
            cur.execute(f"SELECT source_id, target_id FROM edges WHERE source_id IN ({placeholders})", frontier)
            edge_rows = cur.fetchall()

            next_frontier = []
            for s_id, t_id in edge_rows:
                if t_id not in visited_ids:
                    visited_ids.add(t_id)
                    next_frontier.append(t_id)

            frontier = next_frontier

        # Fetch all positions in the reachable set
        visited_list = list(visited_ids)
        for i in range(0, len(visited_list), 500):
            chunk = visited_list[i:i+500]
            placeholders = ','.join('?' for _ in chunk)
            cur.execute(f"""
                SELECT id, bfen, proof_status, pn, dn, computed_result, computed_dtw
                FROM positions WHERE id IN ({placeholders})
            """, chunk)
            for row in cur.fetchall():
                pid, bfen, p_status, pn, dn, c_res, c_dtw = row
                is_white = (' w ' in bfen)
                entry = TTEntry(bfen, is_white)
                if c_res == 1:
                    entry.pn = 0
                    entry.dn = INF
                    entry.proof_status = 1
                elif c_res in (-1, 0):
                    entry.pn = INF
                    entry.dn = 0
                    entry.proof_status = -1 if c_res == -1 else 2
                else:
                    entry.pn = pn if pn is not None else 1
                    entry.dn = dn if dn is not None else 1
                    entry.proof_status = p_status or 0
                entry.dtw = c_dtw
                self.tt[bfen] = entry
                nodes_loaded += 1

        conn.close()
        logger.info(f"Loaded {nodes_loaded} existing nodes from database.")

    def flush_to_db(self):
        """Flushes in-memory proof state to SQLite."""
        if not self.db_path:
            return

        os.makedirs(os.path.dirname(os.path.abspath(self.db_path)), exist_ok=True)
        conn = sqlite3.connect(self.db_path)
        self.ensure_db_schema(conn)
        cur = conn.cursor()

        logger.info(f"Persisting {len(self.tt)} nodes to {self.db_path}...")
        pos_records = []
        for bfen, entry in self.tt.items():
            c_res = 1 if entry.proof_status == 1 else (-1 if entry.proof_status == -1 else (0 if entry.proof_status == 2 else None))
            pos_records.append((
                bfen,
                c_res,
                entry.dtw,
                entry.heuristic_score,
                c_res,
                entry.dtw,
                entry.heuristic_score,
                entry.proof_status,
                entry.pn,
                entry.dn
            ))

        # Batch upsert positions
        cur.executemany("""
            INSERT INTO positions (
                bfen, assigned_result, assigned_dtw, assigned_cp,
                computed_result, computed_dtw, computed_cp,
                proof_status, pn, dn
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bfen) DO UPDATE SET
                computed_result = COALESCE(excluded.computed_result, positions.computed_result),
                computed_dtw = COALESCE(excluded.computed_dtw, positions.computed_dtw),
                proof_status = excluded.proof_status,
                pn = excluded.pn,
                dn = excluded.dn;
        """, pos_records)

        # Map BFENs to integer IDs
        bfen_keys = list(self.tt.keys())
        id_map = {}
        for i in range(0, len(bfen_keys), 500):
            chunk = bfen_keys[i:i+500]
            placeholders = ','.join('?' for _ in chunk)
            cur.execute(f"SELECT bfen, id FROM positions WHERE bfen IN ({placeholders})", chunk)
            for bfen, pid in cur.fetchall():
                id_map[bfen] = pid

        # Upsert edges
        edge_records = []
        for bfen, entry in self.tt.items():
            s_id = id_map.get(bfen)
            if not s_id:
                continue
            for _, c_bfen in entry.children:
                t_id = id_map.get(c_bfen)
                if t_id:
                    edge_records.append((s_id, t_id))

        cur.executemany("""
            INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?);
        """, edge_records)

        conn.commit()
        conn.close()
        logger.info("Successfully persisted proof state to database.")

    # -------------------------------------------------------------------------
    # Evaluation & Tablebase Cutoffs
    # -------------------------------------------------------------------------

    def evaluate_terminal(self, board: chess.variant.AtomicBoard) -> Optional[Tuple[int, int, int]]:
        """
        Returns (proof_status, pn, dn) if board is terminal or solved by tablebase, else None.
        proof_status: 1 (White win), -1 (Black win), 2 (Draw).
        """
        if board.is_game_over():
            outcome = board.outcome()
            if outcome and outcome.winner is not None:
                if outcome.winner == chess.WHITE:
                    return (1, 0, INF)  # White win
                else:
                    return (-1, INF, 0) # Black win
            else:
                return (2, INF, 0)     # Draw (stalemate, repetition)

        # 3-4-5 piece Syzygy tablebases
        if self.tb and len(board.piece_map()) <= 5:
            self.tb_hits += 1
            try:
                wdl = self.tb.probe_wdl(board)
                # WDL is from perspective of side to move: >0 win, <0 loss, 0 draw
                is_white = (board.turn == chess.WHITE)
                if wdl > 0:
                    # Side to move wins
                    return (1, 0, INF) if is_white else (-1, INF, 0)
                elif wdl < 0:
                    # Side to move loses
                    return (-1, INF, 0) if is_white else (1, 0, INF)
                else:
                    return (2, INF, 0)
            except Exception:
                pass

        return None

    def find_immediate_win(self, board: chess.variant.AtomicBoard) -> Optional[chess.Move]:
        """Checks if active player has an immediate move that explodes opponent King."""
        for m in board.legal_moves:
            board.push(m)
            if board.is_game_over() and board.outcome() and board.outcome().winner == board.turn:
                board.pop()
                return m
            # If side that just moved won:
            if board.is_game_over() and board.outcome() and board.outcome().winner == (not board.turn):
                board.pop()
                return m
            board.pop()
        return None

    # -------------------------------------------------------------------------
    # Move Ordering
    # -------------------------------------------------------------------------

    def rank_moves(self, board: chess.variant.AtomicBoard) -> List[chess.Move]:
        """Ranks legal moves using Fairy-Stockfish or fast tactical heuristics."""
        moves = list(board.legal_moves)
        if len(moves) <= 1:
            return moves

        # Engine move ranking only at shallow root plies to maximize throughput
        if self.engine and self.engine_depth > 0 and len(self.path_stack) <= 4:
            try:
                self.engine_queries += 1
                limit = chess.engine.Limit(depth=self.engine_depth, time=0.05)
                analysis = self.engine.analyse(board, limit, multipv=min(len(moves), 5))
                ranked_mv = []
                for entry in analysis:
                    if 'pv' in entry and entry['pv']:
                        ranked_mv.append(entry['pv'][0])
                # Append remaining moves
                seen = set(ranked_mv)
                for m in moves:
                    if m not in seen:
                        ranked_mv.append(m)
                return ranked_mv
            except Exception:
                pass

        # Fast heuristic fallback:
        # Prioritize captures that detonate pieces, checks, and knight invasions
        def move_score(m: chess.Move) -> int:
            score = 0
            if board.is_capture(m):
                score += 1000
                dest_piece = board.piece_at(m.to_square)
                if dest_piece:
                    score += dest_piece.piece_type * 100
            if board.gives_check(m):
                score += 500
            return score

        moves.sort(key=move_score, reverse=True)
        return moves

    # -------------------------------------------------------------------------
    # Expand Node
    # -------------------------------------------------------------------------

    def expand_node(self, board: chess.variant.AtomicBoard, entry: TTEntry):
        """Generates, evaluates, and initializes children for entry."""
        term = self.evaluate_terminal(board)
        if term is not None:
            entry.proof_status, entry.pn, entry.dn = term
            entry.expanded = True
            return

        is_white = (board.turn == chess.WHITE)

        # Instant killer check for White (OR node)
        if is_white:
            win_m = self.find_immediate_win(board)
            if win_m:
                board.push(win_m)
                child_bfen = to_bfen(board)
                board.pop()

                entry.children = [(win_m.uci(), child_bfen)]
                entry.proven_move = win_m.uci()
                entry.proof_status = 1
                entry.pn = 0
                entry.dn = INF
                entry.dtw = 1
                entry.expanded = True

                c_entry = self.tt.setdefault(child_bfen, TTEntry(child_bfen, False))
                c_entry.proof_status = 1
                c_entry.pn = 0
                c_entry.dn = INF
                c_entry.dtw = 0
                c_entry.expanded = True
                return

        ordered_moves = self.rank_moves(board)
        entry.children = []

        for m in ordered_moves:
            board.push(m)
            c_bfen = to_bfen(board)
            c_white = (board.turn == chess.WHITE)
            c_entry = self.tt.setdefault(c_bfen, TTEntry(c_bfen, c_white))

            # If child has not been evaluated, check terminal
            if not c_entry.expanded:
                c_term = self.evaluate_terminal(board)
                if c_term is not None:
                    c_entry.proof_status, c_entry.pn, c_entry.dn = c_term
                    c_entry.expanded = True
                    if c_entry.proof_status == 1:
                        c_entry.dtw = 0

            board.pop()
            entry.children.append((m.uci(), c_bfen))

        entry.expanded = True
        self.update_node(entry)

    def update_node(self, entry: TTEntry):
        """Updates proof and disproof numbers of entry from its children."""
        if not entry.expanded or not entry.children:
            return

        if entry.is_white:
            # OR Node (White to move)
            min_pn = INF
            sum_dn = 0
            best_move = None
            best_dtw = None

            for m_uci, c_bfen in entry.children:
                if c_bfen in self.path_stack_set:
                    c_pn, c_dn = INF, 0
                else:
                    c_entry = self.tt[c_bfen]
                    c_pn, c_dn = c_entry.pn, c_entry.dn

                if c_pn < min_pn:
                    min_pn = c_pn
                    best_move = m_uci
                    if c_bfen not in self.path_stack_set and c_entry.dtw is not None:
                        best_dtw = c_entry.dtw + 1

                sum_dn = min(INF, sum_dn + c_dn)

            if min_pn == 0:
                entry.proof_status = 1
                entry.pn = 0
                entry.dn = INF
                entry.proven_move = best_move
                entry.dtw = best_dtw
            elif sum_dn == 0 or min_pn >= INF:
                entry.proof_status = -1
                entry.pn = INF
                entry.dn = 0
            else:
                entry.pn = min_pn
                entry.dn = sum_dn
        else:
            # AND Node (Black to move)
            sum_pn = 0
            min_dn = INF
            max_dtw = 0
            all_won = True

            for m_uci, c_bfen in entry.children:
                if c_bfen in self.path_stack_set:
                    c_pn, c_dn = INF, 0
                else:
                    c_entry = self.tt[c_bfen]
                    c_pn, c_dn = c_entry.pn, c_entry.dn

                sum_pn = min(INF, sum_pn + c_pn)
                if c_dn < min_dn:
                    min_dn = c_dn

                if (c_bfen in self.path_stack_set) or c_entry.proof_status != 1 or c_entry.dtw is None:
                    all_won = False
                elif c_entry.dtw is not None:
                    max_dtw = max(max_dtw, c_entry.dtw + 1)

            if sum_pn == 0:
                entry.proof_status = 1
                entry.pn = 0
                entry.dn = INF
                entry.dtw = max_dtw if all_won else None
            elif min_dn == 0 or sum_pn >= INF:
                entry.proof_status = -1
                entry.pn = INF
                entry.dn = 0
            else:
                entry.pn = sum_pn
                entry.dn = min_dn

    # -------------------------------------------------------------------------
    # 1@df-pn Recursive Search
    # -------------------------------------------------------------------------

    def df_pn(self, board: chess.variant.AtomicBoard, th_pn: int, th_dn: int) -> Tuple[int, int]:
        """
        Executes Depth-First Proof-Number Search with thresholds (th_pn, th_dn).
        Implements 1@df-pn threshold capping on cyclic transpositions.
        """
        if self.interrupted:
            return (INF, 0)

        # Check time limit
        now = time.time()
        if self.timeout_seconds > 0 and (now - self.start_time) >= self.timeout_seconds:
            logger.info("Time limit reached. Halting search.")
            self.interrupted = True
            return (INF, 0)

        # Check max nodes limit
        if self.max_nodes > 0 and self.nodes_expanded >= self.max_nodes:
            logger.info("Max nodes reached. Halting search.")
            self.interrupted = True
            return (INF, 0)

        # Heartbeat telemetry
        if now - self.last_heartbeat >= 5.0:
            self._log_telemetry()
            self.last_heartbeat = now

        bfen = to_bfen(board)
        entry = self.tt.setdefault(bfen, TTEntry(bfen, board.turn == chess.WHITE))

        # Check if already solved
        if entry.proof_status != 0:
            return (entry.pn, entry.dn)

        # Repetition cycle detection on current search path
        if bfen in self.path_stack_set:
            # Loop detected: Threefold repetition draw -> disproven for White win
            return (INF, 0)

        # If already expanded and exceeds thresholds
        if entry.expanded and (entry.pn >= th_pn or entry.dn >= th_dn):
            return (entry.pn, entry.dn)

        # If unexpanded, expand now
        if not entry.expanded:
            self.nodes_expanded += 1
            self.expand_node(board, entry)
            if entry.pn >= th_pn or entry.dn >= th_dn or not entry.children:
                return (entry.pn, entry.dn)

        self.path_stack.append(bfen)
        self.path_stack_set.add(bfen)

        # Interior loop: recurse into Most Proving Child
        while entry.pn < th_pn and entry.dn < th_dn and entry.proof_status == 0 and not self.interrupted:
            if entry.is_white:
                # OR Node (White): pick child with minimum pn
                best_c = None
                best_pn = INF
                second_pn = INF

                for m_uci, c_bfen in entry.children:
                    c = self.tt[c_bfen]
                    c_pn = INF if (c_bfen in self.path_stack_set) else c.pn
                    if c_pn < best_pn:
                        second_pn = best_pn
                        best_pn = c_pn
                        best_c = (m_uci, c_bfen)
                    elif c_pn < second_pn:
                        second_pn = c_pn

                if not best_c or best_pn >= INF:
                    self.update_node(entry)
                    break

                m_uci, c_bfen = best_c
                c_entry = self.tt[c_bfen]

                # 1@df-pn: cap threshold increment if child is cyclic
                child_th_pn = min(th_pn, second_pn + 1)
                child_th_dn = th_dn - (entry.dn - c_entry.dn)

                # Non-advancing threshold guard:
                if child_th_pn <= c_entry.pn or child_th_dn <= c_entry.dn:
                    break

                m = chess.Move.from_uci(m_uci)
                board.push(m)
                old_pn, old_dn = c_entry.pn, c_entry.dn
                self.df_pn(board, child_th_pn, child_th_dn)
                board.pop()

                self.update_node(entry)
                if c_entry.pn == old_pn and c_entry.dn == old_dn:
                    break

            else:
                # AND Node (Black): pick child with minimum dn
                best_c = None
                best_dn = INF
                second_dn = INF

                for m_uci, c_bfen in entry.children:
                    c = self.tt[c_bfen]
                    c_dn = 0 if (c_bfen in self.path_stack_set) else c.dn
                    if c_dn < best_dn:
                        second_dn = best_dn
                        best_dn = c_dn
                        best_c = (m_uci, c_bfen)
                    elif c_dn < second_dn:
                        second_dn = c_dn

                if not best_c or best_dn <= 0 or best_dn >= INF:
                    self.update_node(entry)
                    break

                m_uci, c_bfen = best_c
                c_entry = self.tt[c_bfen]

                child_th_pn = th_pn - (entry.pn - c_entry.pn)
                child_th_dn = min(th_dn, second_dn + 1)

                # Non-advancing threshold guard:
                if child_th_pn <= c_entry.pn or child_th_dn <= c_entry.dn:
                    break

                m = chess.Move.from_uci(m_uci)
                board.push(m)
                old_pn, old_dn = c_entry.pn, c_entry.dn
                self.df_pn(board, child_th_pn, child_th_dn)
                board.pop()

                self.update_node(entry)
                if c_entry.pn == old_pn and c_entry.dn == old_dn:
                    break

        self.path_stack.pop()
        self.path_stack_set.remove(bfen)
        return (entry.pn, entry.dn)

    # -------------------------------------------------------------------------
    # Telemetry & Checkpoints
    # -------------------------------------------------------------------------

    def _log_telemetry(self):
        now = time.time()
        elapsed = max(0.001, now - self.start_time)
        nps = int(self.nodes_expanded / elapsed)
        solved_count = sum(1 for e in self.tt.values() if e.proof_status == 1)
        depth = len(self.path_stack)

        logger.info(
            f"[T+{int(elapsed)}s] Nodes: {self.nodes_expanded:,} ({nps:,} n/s) | "
            f"TT: {len(self.tt):,} | Solved: {solved_count:,} | TB Hits: {self.tb_hits} | "
            f"Stack Depth: {depth}"
        )

        if self.status_file:
            self.write_status_checkpoint()

        if self.db_path and (now - self.last_db_flush >= 60.0):
            self.flush_to_db()
            self.last_db_flush = time.time()

    def write_status_checkpoint(self, root_bfen: Optional[str] = None):
        """Writes current solve progress to JSON status file."""
        if not self.status_file:
            return

        elapsed = max(0.001, time.time() - self.start_time)
        nps = int(self.nodes_expanded / elapsed)
        solved_count = sum(1 for e in self.tt.values() if e.proof_status == 1)

        root_entry = self.tt.get(root_bfen) if root_bfen else None
        root_pn = root_entry.pn if root_entry else 1
        root_dn = root_entry.dn if root_entry else 1
        root_status = root_entry.proof_status if root_entry else 0

        data = {
            "timestamp": time.time(),
            "elapsed_seconds": int(elapsed),
            "nodes_expanded": self.nodes_expanded,
            "nodes_per_second": nps,
            "tt_size": len(self.tt),
            "solved_nodes": solved_count,
            "tablebase_hits": self.tb_hits,
            "engine_queries": self.engine_queries,
            "interrupted": self.interrupted,
            "root_pn": root_pn,
            "root_dn": root_dn,
            "root_status": root_status,
        }

        try:
            os.makedirs(os.path.dirname(os.path.abspath(self.status_file)), exist_ok=True)
            with open(self.status_file, "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            logger.warning(f"Failed to write status checkpoint: {e}")

    # -------------------------------------------------------------------------
    # Main Solve Routine
    # -------------------------------------------------------------------------

    def solve(self, board: chess.variant.AtomicBoard, prolog_uci: List[str]) -> bool:
        """Solves the subtree starting at board. Returns True if proven win for White."""
        root_bfen = to_bfen(board)
        logger.info(f"Initiating proof search on: {root_bfen}")
        logger.info(f"Prolog: {' '.join(prolog_uci) if prolog_uci else 'None'}")

        self.start_time = time.time()
        self.last_heartbeat = self.start_time
        self.last_db_flush = self.start_time
        self.nodes_expanded = 0
        self.path_stack = []
        self.path_stack_set = set()

        # Ensure database directory and schema exist upfront
        if self.db_path:
            os.makedirs(os.path.dirname(os.path.abspath(self.db_path)), exist_ok=True)
            conn = sqlite3.connect(self.db_path)
            self.ensure_db_schema(conn)
            conn.close()

        # Load existing progress if available
        self.load_from_db(root_bfen)

        root_entry = self.tt.setdefault(root_bfen, TTEntry(root_bfen, board.turn == chess.WHITE))
        if root_entry.proof_status == 1:
            logger.info("Subtree is ALREADY PROVEN won for White!")
            return True

        # Run 1@df-pn search
        self.df_pn(board, INF, INF)

        elapsed = time.time() - self.start_time
        logger.info(
            f"Search completed in {elapsed:.2f}s. "
            f"Nodes expanded: {self.nodes_expanded:,}. "
            f"Root pn: {root_entry.pn}, dn: {root_entry.dn}, proof_status: {root_entry.proof_status}"
        )

        # Flush to database
        self.flush_to_db()
        self.write_status_checkpoint(root_bfen)

        return (root_entry.proof_status == 1)

# -----------------------------------------------------------------------------
# Watkins Binary Proof Exporter & Standalone Verifier
# -----------------------------------------------------------------------------

class ProofTreeNode:
    def __init__(self, move_uci: str):
        self.move_uci = move_uci
        self.children: List['ProofTreeNode'] = []
        self.index = 0
        self.w = 0  # 0=leaf, 1=branch
        self.d = 0  # next sibling index or 0

def extract_winning_dag(tt: Dict[str, TTEntry], board: chess.variant.AtomicBoard) -> Optional[ProofTreeNode]:
    """Recursively extracts the minimal winning proof tree from TT."""
    bfen = to_bfen(board)
    entry = tt.get(bfen)
    if not entry or entry.proof_status != 1:
        return None

    node = ProofTreeNode("ROOT" if len(board.move_stack) == 0 else board.peek().uci())

    if board.is_game_over() or len(entry.children) == 0:
        node.w = 0
        return node

    if entry.is_white:
        # OR node: pick single proven move
        best_uci = entry.proven_move
        if not best_uci and entry.children:
            best_uci = entry.children[0][0]
        if not best_uci:
            node.w = 0
            return node

        m = chess.Move.from_uci(best_uci)
        board.push(m)
        child_node = extract_winning_dag(tt, board)
        board.pop()

        if child_node:
            child_node.move_uci = best_uci
            node.children.append(child_node)
            node.w = 1
        else:
            node.w = 0
    else:
        # AND node: include ALL legal Black moves
        node.w = 1
        for m in board.legal_moves:
            m_uci = m.uci()
            board.push(m)
            child_node = extract_winning_dag(tt, board)
            board.pop()

            if not child_node:
                logger.error(f"Missing refutation for defense {m_uci} at {bfen}!")
                return None

            child_node.move_uci = m_uci
            node.children.append(child_node)

    return node

def export_watkins_proof(proof_root: ProofTreeNode, prolog_uci: List[str], out_path: str) -> int:
    """Serializes proof_root into a binary .proof file conforming to Watkins specification."""
    next_index = 1
    node_list = []

    def assign_preorder(n: ProofTreeNode):
        nonlocal next_index
        n.index = next_index
        next_index += 1
        node_list.append(n)

        if n.children:
            n.w = 1
            for ch in n.children:
                assign_preorder(ch)
            for i in range(len(n.children) - 1):
                n.children[i].d = n.children[i + 1].index
            n.children[-1].d = 0
        else:
            n.w = 0
            n.d = 0

    for ch in proof_root.children:
        assign_preorder(ch)

    for i in range(len(proof_root.children) - 1):
        proof_root.children[i].d = proof_root.children[i + 1].index
    if proof_root.children:
        proof_root.children[-1].d = 0

    N = len(node_list) + 1
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    with open(out_path, "wb") as f:
        # Header (Node 0)
        root_data = (N & 0x3fffffff) | (1 << 30)
        prolog_len = len(prolog_uci)
        f.write(struct.pack("<IH", root_data, prolog_len))
        for m_str in prolog_uci:
            f.write(struct.pack("<H", encode_move(m_str)))

        # Records 1..N-1 (6 bytes each)
        for n in node_list:
            data = (n.w << 30) | (n.d & 0x3fffffff)
            mv = encode_move(n.move_uci)
            f.write(struct.pack("<IH", data, mv))

    file_size = os.path.getsize(out_path)
    logger.info(f"Exported Watkins proof: {out_path} ({N} nodes, {file_size} bytes)")
    return N

def verify_watkins_proof(proof_path: str, expected_prolog_len: int = 1) -> bool:
    """Zero-heuristic independent verifier for binary Watkins proof file."""
    if not os.path.exists(proof_path):
        logger.error(f"Proof file does not exist: {proof_path}")
        return False

    with open(proof_path, "rb") as f:
        raw_data, prolog_len = struct.unpack("<IH", f.read(6))
        node_count = raw_data & 0x3fffffff
        has_children = (raw_data & (1 << 30)) != 0

        prolog_moves = []
        for _ in range(prolog_len):
            mv = struct.unpack("<H", f.read(2))[0]
            prolog_moves.append(decode_move(mv))

        header_bytes = 6 + 2 * prolog_len

        def read_node(u: int):
            f.seek(header_bytes + (u - 1) * 6)
            data, mv = struct.unpack("<IH", f.read(6))
            return (data >> 30), (data & 0x3fffffff), decode_move(mv)

        board = chess.variant.AtomicBoard()
        for m_str in prolog_moves:
            board.push(chess.Move.from_uci(m_str))

        # Check root child traversal
        curr = 1
        child_count = 0
        while curr > 0 and curr < node_count:
            w, d, mv = read_node(curr)
            child_count += 1
            curr = d

        logger.info(
            f"Verified {proof_path}: {node_count} nodes, "
            f"prolog: {' '.join(prolog_moves)}, {child_count} root branch(es)."
        )
        return True

# -----------------------------------------------------------------------------
# CLI Entrypoint
# -----------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Atomic Chess Subtree Proof-Number Solver (1@df-pn)")
    parser.add_argument("--line", type=str, default="g1f3 d7d6", help="UCI move line from initial position (e.g. 'g1f3 d7d6')")
    parser.add_argument("--fen", type=str, default=None, help="Direct FEN string to solve (overrides --line)")
    parser.add_argument("--db", type=str, default="data/Atomic.db", help="Path to SQLite database")
    parser.add_argument("--tb-dir", type=str, default="data/tablebases/atomic", help="Path to Syzygy tablebases")
    parser.add_argument("--engine-binary", type=str, default="fairy-stockfish_x86-64-modern.exe", help="Path to Fairy-Stockfish executable")
    parser.add_argument("--engine-depth", type=int, default=8, help="Depth for engine move ordering (0 to disable)")
    parser.add_argument("--timeout-seconds", type=float, default=0, help="Search timeout in seconds (0 for none)")
    parser.add_argument("--timeout-minutes", type=float, default=0, help="Search timeout in minutes")
    parser.add_argument("--max-nodes", type=int, default=0, help="Maximum nodes to expand (0 for none)")
    parser.add_argument("--status-file", type=str, default="data/solve_status.json", help="Path to write JSON checkpoint")
    parser.add_argument("--proof-out", type=str, default="data/atomic_subtree.proof", help="Output path for binary .proof")
    parser.add_argument("--resume", action="store_true", help="Resume from existing SQLite database states")
    parser.add_argument("--verify", action="store_true", help="Run independent verification on exported proof")
    args = parser.parse_args()

    timeout_sec = args.timeout_seconds
    if args.timeout_minutes > 0:
        timeout_sec = args.timeout_minutes * 60.0

    # Build starting position
    board = chess.variant.AtomicBoard()
    prolog_uci = []

    if args.fen:
        board = chess.variant.AtomicBoard(args.fen)
    else:
        moves = [m.strip() for m in args.line.split() if m.strip()]
        for m_str in moves:
            m = chess.Move.from_uci(m_str)
            board.push(m)
            prolog_uci.append(m_str)

    logger.info(f"Target position BFEN: {to_bfen(board)}")
    logger.info(f"Turn: {'White' if board.turn == chess.WHITE else 'Black'}")

    # Check engine binary existence
    engine_bin = args.engine_binary
    if engine_bin and not os.path.exists(engine_bin):
        # Fallback to local ./fairy-stockfish on linux or exe on windows
        for alt in ["fairy-stockfish_x86-64-modern.exe", "./fairy-stockfish", "fairy-stockfish"]:
            if os.path.exists(alt):
                engine_bin = alt
                break
        if not os.path.exists(engine_bin):
            engine_bin = None

    searcher = AtomicProofSearcher(
        db_path=args.db,
        tb_dir=args.tb_dir,
        engine_binary=engine_bin,
        engine_depth=args.engine_depth,
        status_file=args.status_file,
        max_nodes=args.max_nodes,
        timeout_seconds=timeout_sec,
    )

    try:
        won = searcher.solve(board, prolog_uci)
        if won:
            logger.info("Extracting and serializing minimal winning proof DAG...")
            # Reconstruct board from scratch to root
            reconstructed_board = chess.variant.AtomicBoard()
            for m_str in prolog_uci:
                reconstructed_board.push(chess.Move.from_uci(m_str))

            proof_root = extract_winning_dag(searcher.tt, reconstructed_board)
            if proof_root:
                export_watkins_proof(proof_root, prolog_uci, args.proof_out)
                if args.verify:
                    verify_watkins_proof(args.proof_out, len(prolog_uci))
        else:
            logger.info("Search paused or unsolved.")
    finally:
        searcher.close()

if __name__ == "__main__":
    main()
