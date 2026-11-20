#!/usr/bin/env python3
"""
solve_best_first.py

Unattended Best-First Atomic Chess Subtree Mate Solver.
Mirrors the RetroSolve `_proveMateRecursive` algorithm with adaptations for
unattended operation:
1. Attacker (OR node) cycle backtracking with irreversible-move priority:
   When the #1 candidate move fails due to a cycle/repetition, remaining winning
   candidates (>= min_win_cp or forced mate) are re-ordered to prioritize
   irreversible moves (`board.is_zeroing(move)` — pawn pushes and captures/explosions)
   first, breaking repetition loops immediately.
2. Persistent SQLite `engine_cache` + existing `Atomic.db` child evaluation reuse:
   - Caches Fairy-Stockfish `MultiPV` evaluations durably in `engine_cache` inside
     SQLite so restarts and transpositions never re-run FSF on visited positions.
   - Reuses existing `Atomic.db` child evaluations when a position's children
     have already been explored in a prior session (skipping redundant FSF calls
     on Defender AND nodes when children are already evaluated).
3. Session-level `failed_bfens` transposition memoization:
   - Remembers positions that failed for path-independent reasons (e.g. score drop,
     defender mate) so alternative move orders transposing into them return
     immediately in 0 ms.
4. No fixed 20-ply depth cutoff: keeps expanding as long as the attacker's
   evaluation remains winning (>= min_win_cp, default +200 cp) or hits a
   confirmed forced mate / tablebase win (up to a high safety cap, e.g., 100 plies).
5. Local SQLite persistence (`data/Atomic.db`) with exact retrograde minimax
   backpropagation (`solve_bfen`) and periodic checkpointing to persistent
   storage (`~/.gemini/Atomic.db`).
"""

import argparse
from collections import deque
import json
import logging
import os
import shutil
import signal
import sqlite3
import sys
import time
from typing import Dict, List, Optional, Set, Tuple

import chess
import chess.engine
import chess.variant

# Allow importing AtomicAtbdProber from tool/tablebase_server.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from tablebase_server import AtomicAtbdProber
except ImportError:
    AtomicAtbdProber = None

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("best_first")


def to_bfen(board: chess.variant.AtomicBoard) -> str:
    """Returns canonical BFEN (first 4 fields of FEN)."""
    return " ".join(board.fen().split()[:4])


def count_pieces(bfen: str) -> int:
    board_part = bfen.split(" ")[0]
    return sum(1 for c in board_part if c.isalpha())


def white_to_move_from_bfen(bfen: str) -> bool:
    parts = bfen.split(" ")
    return len(parts) < 2 or parts[1] == "w"


class PositionEval:
    """Represents (result, dtw, cp) from White's perspective."""

    __slots__ = ("result", "dtw", "cp")

    def __init__(
        self,
        result: Optional[int] = None,
        dtw: Optional[int] = None,
        cp: Optional[int] = None,
    ):
        self.result = result  # 1 = WhiteWins, -1 = BlackWins, 0 = Draw, None = non-decisive
        self.dtw = dtw        # Distance to win in plies
        self.cp = cp          # Centipawns from White's perspective

    def __eq__(self, other) -> bool:
        if not isinstance(other, PositionEval):
            return False
        return (
            self.result == other.result
            and self.dtw == other.dtw
            and self.cp == other.cp
        )

    def __repr__(self) -> str:
        if self.result == 1:
            m = (self.dtw + 1) // 2 if self.dtw is not None else "?"
            return f"+M{m}(dtw={self.dtw})"
        if self.result == -1:
            m = (self.dtw + 1) // 2 if self.dtw is not None else "?"
            return f"-M{m}(dtw={self.dtw})"
        if self.result == 0:
            return "Draw(0.0)"
        if self.cp is not None:
            return f"{self.cp / 100.0:+.2f}"
        return "None"


class UnattendedBestFirstSolver:
    def __init__(
        self,
        db_path: str = "data/Atomic.db",
        backup_db_path: Optional[str] = "/home/antigravity/.gemini/Atomic.db",
        tb_dir: str = "data/tablebases/atomic",
        engine_binary: str = "./fairy-stockfish",
        nnue_path: str = "atomic-2cf13ff256cc.nnue",
        engine_depth: int = 16,
        multipv: int = 5,
        min_win_cp: int = 200,
        max_depth: int = 0,
        backtrack_on_any_failure: bool = True,
        status_file: str = "data/best_first_status.json",
        backup_interval_sec: float = 600.0,
        threads: int = 2,
        hash_mb: int = 256,
    ):
        sys.setrecursionlimit(max(sys.getrecursionlimit(), 20000))
        self.db_path = db_path
        self.backup_db_path = backup_db_path
        self.tb_dir = tb_dir
        self.engine_binary = engine_binary
        self.nnue_path = nnue_path
        self.engine_depth = engine_depth
        self.multipv = multipv
        self.min_win_cp = min_win_cp
        self.max_depth = max_depth
        self.backtrack_on_any_failure = backtrack_on_any_failure
        self.status_file = status_file
        self.backup_interval_sec = backup_interval_sec

        # Connect to local SQLite
        self.conn = sqlite3.connect(self.db_path)
        self.conn.execute("PRAGMA journal_mode = WAL;")
        self.conn.execute("PRAGMA synchronous = NORMAL;")
        self.conn.execute("PRAGMA cache_size = -64000;")  # 64 MB page cache
        self._ensure_engine_cache_table()

        # Load local .atbd tablebase prober if available
        self.tb_prober = None
        if AtomicAtbdProber is not None and os.path.exists(self.tb_dir):
            try:
                self.tb_prober = AtomicAtbdProber(self.tb_dir)
                logger.info("Initialized AtomicAtbdProber from %s", self.tb_dir)
            except Exception as e:
                logger.warning("Could not initialize AtomicAtbdProber: %s", e)

        # Start Fairy-Stockfish
        self.engine = chess.engine.SimpleEngine.popen_uci(self.engine_binary)
        opts = {
            "Threads": threads,
            "Hash": hash_mb,
            "Use NNUE": True,
        }
        if self.nnue_path and os.path.exists(self.nnue_path):
            opts["EvalFile"] = os.path.abspath(self.nnue_path)
        self.engine.configure(opts)
        logger.info(
            "Initialized Fairy-Stockfish (%s) with options: %s",
            self.engine_binary,
            opts,
        )

        # Telemetry & runtime state
        self.nodes_explored = 0
        self.engine_evals_count = 0
        self.cache_hits = 0
        self.db_reuse_hits = 0
        self.tb_hits = 0
        self.cycles_backtracked = 0
        self.mates_found = 0
        self.start_time = time.time()
        self.last_heartbeat = self.start_time
        self.last_commit = self.start_time
        self.last_backup = self.start_time
        self._backup_proc = None
        self._last_backup_evals = -1
        self.interrupted = False
        self.current_line_san: List[str] = []
        self.ply_progress: Dict[int, str] = {}

        # In-memory cache of engine evaluations: bfen -> list of (uci, san, cp_white, mate_white)
        self.eval_cache: Dict[str, List[Tuple[str, str, Optional[int], Optional[int]]]] = {}

        # Session-level memoization of path-independent failed positions: bfen -> failure_reason
        self.failed_bfens: Dict[str, str] = {}

        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)

    def _ensure_engine_cache_table(self):
        self.conn.execute(
            """
            CREATE TABLE IF NOT EXISTS engine_cache (
                bfen TEXT PRIMARY KEY,
                depth INTEGER NOT NULL,
                multipv_json TEXT NOT NULL
            ) WITHOUT ROWID;
            """
        )
        self.conn.commit()

    def _handle_signal(self, signum, frame):
        logger.warning("Received signal %d. Stopping cleanly...", signum)
        self.interrupted = True

    def close(self):
        if self._backup_proc is not None and self._backup_proc.poll() is None:
            try:
                logger.info("Waiting for in-flight shared DB backup to finish...")
                self._backup_proc.wait(timeout=120)
            except Exception:
                pass
        try:
            self.conn.commit()
            self.conn.close()
        except Exception:
            pass
        if self.tb_prober:
            try:
                self.tb_prober.close()
            except Exception:
                pass
        if self.engine:
            try:
                self.engine.quit()
            except Exception:
                pass

    # -------------------------------------------------------------------------
    # SQLite Graph Persistence & Retrograde Backpropagation
    # -------------------------------------------------------------------------

    def get_or_create_position_id(self, bfen: str) -> int:
        cur = self.conn.cursor()
        cur.execute("SELECT id FROM positions WHERE bfen = ?", (bfen,))
        row = cur.fetchone()
        if row:
            return row[0]
        cur.execute("INSERT INTO positions (bfen) VALUES (?)", (bfen,))
        return cur.lastrowid

    def get_effective_eval(self, bfen: str) -> Optional[PositionEval]:
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT assigned_result, assigned_dtw, assigned_cp,
                   computed_result, computed_dtw, computed_cp
            FROM positions WHERE bfen = ?
            """,
            (bfen,),
        )
        row = cur.fetchone()
        if not row:
            return None
        ar, ad, ac, cr, cd, cc = row
        if cr is not None or cd is not None or cc is not None:
            return PositionEval(cr, cd, cc)
        if ar is not None or ad is not None or ac is not None:
            return PositionEval(ar, ad, ac)
        return None

    def get_db_children_evals(self, bfen: str) -> Dict[str, PositionEval]:
        """Returns mapping of child_bfen -> PositionEval for all linked children in SQLite."""
        cur = self.conn.cursor()
        cur.execute("SELECT id FROM positions WHERE bfen = ?", (bfen,))
        row = cur.fetchone()
        if not row:
            return {}
        pos_id = row[0]
        cur.execute(
            """
            SELECT p.bfen, p.assigned_result, p.assigned_dtw, p.assigned_cp,
                   p.computed_result, p.computed_dtw, p.computed_cp
            FROM edges e
            JOIN positions p ON e.target_id = p.id
            WHERE e.source_id = ?
            """,
            (pos_id,),
        )
        result: Dict[str, PositionEval] = {}
        for c_bfen, ar, ad, ac, cr, cd, cc in cur.fetchall():
            if cr is not None or cd is not None or cc is not None:
                result[c_bfen] = PositionEval(cr, cd, cc)
            elif ar is not None or ad is not None or ac is not None:
                result[c_bfen] = PositionEval(ar, ad, ac)
        return result

    def assign_eval(self, bfen: str, ev: PositionEval, also_computed: bool = True):
        cur = self.conn.cursor()
        cur.execute("SELECT id FROM positions WHERE bfen = ?", (bfen,))
        row = cur.fetchone()
        if row:
            if also_computed:
                cur.execute(
                    """
                    UPDATE positions
                    SET assigned_result = ?, assigned_dtw = ?, assigned_cp = ?,
                        computed_result = COALESCE(computed_result, ?),
                        computed_dtw = COALESCE(computed_dtw, ?),
                        computed_cp = COALESCE(computed_cp, ?)
                    WHERE id = ?
                    """,
                    (ev.result, ev.dtw, ev.cp, ev.result, ev.dtw, ev.cp, row[0]),
                )
            else:
                cur.execute(
                    """
                    UPDATE positions
                    SET assigned_result = ?, assigned_dtw = ?, assigned_cp = ?
                    WHERE id = ?
                    """,
                    (ev.result, ev.dtw, ev.cp, row[0]),
                )
        else:
            cur.execute(
                """
                INSERT INTO positions (
                    bfen, assigned_result, assigned_dtw, assigned_cp,
                    computed_result, computed_dtw, computed_cp
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (bfen, ev.result, ev.dtw, ev.cp, ev.result, ev.dtw, ev.cp),
            )

    def add_link(self, parent_bfen: str, child_bfen: str):
        p_id = self.get_or_create_position_id(parent_bfen)
        c_id = self.get_or_create_position_id(child_bfen)
        self.conn.execute(
            "INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?)",
            (p_id, c_id),
        )

    def compute_node_minimax(self, pos_id: int) -> Tuple[Optional[PositionEval], Optional[PositionEval]]:
        """Computes (old_computed, new_computed) for pos_id from its children in SQLite."""
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT bfen, assigned_result, assigned_dtw, assigned_cp,
                   computed_result, computed_dtw, computed_cp
            FROM positions WHERE id = ?
            """,
            (pos_id,),
        )
        row = cur.fetchone()
        if not row:
            return None, None
        bfen, ar, ad, ac, cr, cd, cc = row
        old_comp = (
            PositionEval(cr, cd, cc)
            if (cr is not None or cd is not None or cc is not None)
            else None
        )
        assigned = (
            PositionEval(ar, ad, ac)
            if (ar is not None or ad is not None or ac is not None)
            else None
        )

        cur.execute(
            """
            SELECT p.assigned_result, p.assigned_dtw, p.assigned_cp,
                   p.computed_result, p.computed_dtw, p.computed_cp
            FROM edges e
            JOIN positions p ON e.target_id = p.id
            WHERE e.source_id = ?
            """,
            (pos_id,),
        )
        child_rows = cur.fetchall()
        num_edges = len(child_rows)
        if num_edges == 0:
            return old_comp, assigned

        is_white = white_to_move_from_bfen(bfen)
        target_win = 1 if is_white else -1
        target_loss = -1 if is_white else 1

        winning_count = 0
        min_win_dtw = 999999
        best_win: Optional[PositionEval] = None

        losing_count = 0
        max_lose_dtw = -1
        has_null_lose_dtw = False
        best_lose: Optional[PositionEval] = None

        best_non_decisive: Optional[PositionEval] = None
        has_draw = False

        for car, cad, cac, ccr, ccd, ccc in child_rows:
            if ccr is not None or ccd is not None or ccc is not None:
                c_res, c_dtw, c_cp = ccr, ccd, ccc
            elif car is not None or cad is not None or cac is not None:
                c_res, c_dtw, c_cp = car, cad, cac
            else:
                continue

            adj_dtw = (c_dtw + 1) if (c_res in (1, -1) and c_dtw is not None) else c_dtw
            cand = PositionEval(c_res, adj_dtw, c_cp)

            if cand.result == target_win:
                winning_count += 1
                if cand.dtw is not None and cand.dtw < min_win_dtw:
                    min_win_dtw = cand.dtw
                    best_win = cand
                elif best_win is None:
                    best_win = cand
            elif cand.result == target_loss:
                losing_count += 1
                if cand.dtw is None:
                    has_null_lose_dtw = True
                    best_lose = cand
                elif not has_null_lose_dtw and cand.dtw > max_lose_dtw:
                    max_lose_dtw = cand.dtw
                    best_lose = cand
                elif best_lose is None:
                    best_lose = cand
            elif cand.result == 0:
                has_draw = True
                if best_non_decisive is None:
                    best_non_decisive = cand
                elif best_non_decisive.cp is not None:
                    if is_white and 0 > best_non_decisive.cp:
                        best_non_decisive = cand
                    elif not is_white and 0 < best_non_decisive.cp:
                        best_non_decisive = cand
            elif cand.cp is not None:
                if best_non_decisive is None or best_non_decisive.cp is None:
                    best_non_decisive = cand
                else:
                    if is_white and cand.cp > best_non_decisive.cp:
                        best_non_decisive = cand
                    elif not is_white and cand.cp < best_non_decisive.cp:
                        best_non_decisive = cand

        best_candidate: Optional[PositionEval] = None
        if winning_count > 0:
            best_candidate = best_win
        elif num_edges > 0 and losing_count == num_edges:
            best_candidate = best_lose
        elif num_edges > 0 and losing_count + (1 if has_draw else 0) == num_edges and has_draw:
            best_candidate = PositionEval(0, None, 0)
        else:
            if assigned is not None and assigned.result is not None:
                best_candidate = assigned
            elif best_non_decisive is not None:
                best_candidate = best_non_decisive
            elif assigned is not None:
                best_candidate = assigned

        return old_comp, best_candidate

    def solve_bfen(self, bfen: str):
        """Propagates minimax updates upward along ancestor paths in SQLite."""
        cur = self.conn.cursor()
        cur.execute("SELECT id FROM positions WHERE bfen = ?", (bfen,))
        row = cur.fetchone()
        if not row:
            return
        start_id = row[0]

        queue = deque([start_id])
        visit_counts: Dict[int, int] = {start_id: 1}

        while queue:
            curr_id = queue.popleft()
            old_comp, new_comp = self.compute_node_minimax(curr_id)
            if old_comp == new_comp:
                continue

            cur.execute(
                """
                UPDATE positions
                SET computed_result = ?, computed_dtw = ?, computed_cp = ?
                WHERE id = ?
                """,
                (
                    new_comp.result if new_comp else None,
                    new_comp.dtw if new_comp else None,
                    new_comp.cp if new_comp else None,
                    curr_id,
                ),
            )

            cur.execute("SELECT source_id FROM edges WHERE target_id = ?", (curr_id,))
            for (parent_id,) in cur.fetchall():
                cnt = visit_counts.get(parent_id, 0) + 1
                visit_counts[parent_id] = cnt
                if cnt <= 10:
                    queue.append(parent_id)

    # -------------------------------------------------------------------------
    # Engine & Tablebase Probing (with Persistent SQLite engine_cache)
    # -------------------------------------------------------------------------

    def probe_terminal_or_tb(
        self, board: chess.variant.AtomicBoard, bfen: str
    ) -> Optional[PositionEval]:
        if board.is_game_over():
            outcome = board.outcome()
            if outcome is not None:
                if outcome.winner == chess.WHITE:
                    return PositionEval(result=1, dtw=0)
                elif outcome.winner == chess.BLACK:
                    return PositionEval(result=-1, dtw=0)
                else:
                    return PositionEval(result=0, dtw=0, cp=0)

        if self.tb_prober is not None and count_pieces(bfen) <= 5:
            dtw_val = self.tb_prober.probe(board)
            if dtw_val is not None:
                self.tb_hits += 1
                is_white = board.turn == chess.WHITE
                if dtw_val == 0:
                    return PositionEval(result=0, dtw=0, cp=0)
                elif dtw_val > 0:
                    res = 1 if is_white else -1
                    return PositionEval(result=res, dtw=int(dtw_val))
                else:
                    res = -1 if is_white else 1
                    return PositionEval(result=res, dtw=int(abs(dtw_val)))
        return None

    def evaluate_with_engine(
        self, board: chess.variant.AtomicBoard, bfen: str
    ) -> List[Tuple[str, str, Optional[int], Optional[int]]]:
        """
        Returns list of (uci, san, cp_white, mate_white) sorted best-first for side to move.
        Checks in-memory cache first, then SQLite `engine_cache`, and finally runs Fairy-Stockfish.
        """
        if bfen in self.eval_cache:
            self.cache_hits += 1
            return self.eval_cache[bfen]

        cur = self.conn.cursor()
        cur.execute(
            "SELECT depth, multipv_json FROM engine_cache WHERE bfen = ?",
            (bfen,),
        )
        row = cur.fetchone()
        if row and row[0] >= self.engine_depth:
            try:
                raw_list = json.loads(row[1])
                cached_res = [(x[0], x[1], x[2], x[3]) for x in raw_list]
                if cached_res:
                    self.cache_hits += 1
                    self.eval_cache[bfen] = cached_res
                    return cached_res
            except Exception:
                pass

        self.engine_evals_count += 1
        clean_board = chess.variant.AtomicBoard(bfen + " 0 1")

        def _run_analyse(new_game: bool = False):
            kwargs = {"multipv": self.multipv}
            if new_game:
                kwargs["game"] = object()
            infos_raw = self.engine.analyse(
                clean_board,
                chess.engine.Limit(depth=self.engine_depth),
                **kwargs,
            )
            if not isinstance(infos_raw, list):
                infos_raw = [infos_raw]
            parsed: List[Tuple[str, str, Optional[int], Optional[int]]] = []
            for info in infos_raw:
                pv = info.get("pv")
                if not pv:
                    continue
                move = pv[0]
                if move not in clean_board.legal_moves:
                    continue
                uci = move.uci()
                san = clean_board.san(move)
                score_w = info["score"].white()
                mate_w = score_w.mate()
                cp_w = score_w.score()
                # Filter out FSF depth-100 tablebase draw artifact (±20000 cp at depth 100)
                if info.get("depth") == 100 and cp_w is not None and abs(cp_w) == 20000:
                    cp_w = 0
                parsed.append((uci, san, cp_w, mate_w))
            return parsed

        try:
            results = _run_analyse(new_game=False)
            # If the top evaluation unexpectedly drops below min_win_cp (e.g. 0 cp from
            # a stale repetition/draw entry in FSF's transposition table), re-verify
            # once with a clean TT (ucinewgame) before caching or triggering score_drop.
            if results:
                _, _, top_cp_w, top_mate_w = results[0]
                if top_mate_w is None and top_cp_w is not None and abs(top_cp_w) < self.min_win_cp:
                    logger.info(
                        "[tt-verify] Re-evaluating %s with clean TT (ucinewgame) after low score (%+d cp)",
                        bfen,
                        top_cp_w,
                    )
                    self.engine_evals_count += 1
                    results = _run_analyse(new_game=True)
        except chess.engine.EngineTerminatedError:
            self.interrupted = True
            return []

        if results:
            self.conn.execute(
                """
                INSERT OR REPLACE INTO engine_cache (bfen, depth, multipv_json)
                VALUES (?, ?, ?)
                """,
                (bfen, self.engine_depth, json.dumps(results)),
            )

        self.eval_cache[bfen] = results
        if len(self.eval_cache) > 50000:
            keys = list(self.eval_cache.keys())[:25000]
            for k in keys:
                del self.eval_cache[k]
        return results

    def evaluate_extra_candidates(
        self,
        board: chess.variant.AtomicBoard,
        bfen: str,
        attacking_color: chess.Color,
        exclude_ucis: Set[str],
        only_irreversible: bool = True,
    ) -> List[Tuple[str, str, Optional[int], Optional[int], int, bool]]:
        """
        Evaluates untried legal moves (either irreversible moves only, or all remaining untried
        legal moves) and returns those that are winning (>= min_win_cp).
        Also appends them to `engine_cache` so future runs don't re-evaluate them.
        """
        clean_board = chess.variant.AtomicBoard(bfen + " 0 1")
        target_moves = [
            m
            for m in clean_board.legal_moves
            if m.uci() not in exclude_ucis
            and (
                not only_irreversible
                or clean_board.is_zeroing(m)
                or clean_board.is_castling(m)
            )
        ]
        if not target_moves:
            return []

        self.engine_evals_count += 1
        try:
            infos_raw = self.engine.analyse(
                clean_board,
                chess.engine.Limit(depth=self.engine_depth),
                multipv=min(len(target_moves), 8),
                root_moves=target_moves,
            )
        except chess.engine.EngineTerminatedError:
            self.interrupted = True
            return []
        if not isinstance(infos_raw, list):
            infos_raw = [infos_raw]

        extra_cands: List[Tuple[str, str, Optional[int], Optional[int], int, bool]] = []
        new_cache_entries: List[Tuple[str, str, Optional[int], Optional[int]]] = []
        for info in infos_raw:
            pv = info.get("pv")
            if not pv:
                continue
            move = pv[0]
            if move not in clean_board.legal_moves:
                continue
            uci = move.uci()
            san = clean_board.san(move)
            is_irrev = clean_board.is_zeroing(move) or clean_board.is_castling(move)
            score_w = info["score"].white()
            mate_w = score_w.mate()
            cp_w = score_w.score()
            if info.get("depth") == 100 and cp_w is not None and abs(cp_w) == 20000:
                cp_w = 0
            c_att_cp = (
                cp_w
                if (attacking_color == chess.WHITE or cp_w is None)
                else -cp_w
            )
            is_cand_mate = mate_w is not None and (
                mate_w > 0 if attacking_color == chess.WHITE else mate_w < 0
            )
            score_key = (
                100000 - abs(mate_w)
                if is_cand_mate
                else (c_att_cp if c_att_cp is not None else -99999)
            )
            if score_key >= self.min_win_cp:
                extra_cands.append((uci, san, cp_w, mate_w, score_key, is_irrev))
                new_cache_entries.append((uci, san, cp_w, mate_w))

        if new_cache_entries:
            existing = list(self.eval_cache.get(bfen, []))
            existing_ucis = {x[0] for x in existing}
            for item in new_cache_entries:
                if item[0] not in existing_ucis:
                    existing.append(item)
                    existing_ucis.add(item[0])
            self.eval_cache[bfen] = existing
            self.conn.execute(
                """
                INSERT OR REPLACE INTO engine_cache (bfen, depth, multipv_json)
                VALUES (?, ?, ?)
                """,
                (bfen, self.engine_depth, json.dumps(existing)),
            )

        return extra_cands

    def best_eval_to_position_eval(
        self, best_tuple: Tuple[str, str, Optional[int], Optional[int]]
    ) -> PositionEval:
        _, _, cp_w, mate_w = best_tuple
        if mate_w is not None:
            if mate_w > 0:
                return PositionEval(result=1, dtw=mate_w * 2 - 1)
            elif mate_w < 0:
                return PositionEval(result=-1, dtw=abs(mate_w) * 2)
            else:
                return PositionEval(result=1, dtw=0)
        return PositionEval(result=None, dtw=None, cp=cp_w)

    # -------------------------------------------------------------------------
    # Telemetry & Checkpointing
    # -------------------------------------------------------------------------

    def maybe_checkpoint(self, force: bool = False):
        now = time.time()
        if force or (now - self.last_commit >= 15.0):
            self.conn.commit()
            self.last_commit = now

        if force or (now - self.last_heartbeat >= 15.0):
            self.last_heartbeat = now
            elapsed = max(0.001, now - self.start_time)
            line_preview = " ".join(self.current_line_san[:16])
            if len(self.current_line_san) > 16:
                line_preview += " ..."
            ply_bars = " | ".join(
                f"P{p}:{s}" for p, s in sorted(self.ply_progress.items())[:6]
            )
            logger.info(
                "[T+%ds] Nodes: %d | Evals: %d (Cache:%d DB:%d) | Mates: %d | Backtracks: %d | %s | Line(%d): %s",
                int(elapsed),
                self.nodes_explored,
                self.engine_evals_count,
                self.cache_hits,
                self.db_reuse_hits,
                self.mates_found,
                self.cycles_backtracked,
                ply_bars,
                len(self.current_line_san),
                line_preview,
            )
            self.write_status_file()

        if self.backup_db_path and (
            force or (now - self.last_backup >= self.backup_interval_sec)
        ):
            self.backup_to_shared(wait=force)
            self.last_backup = time.time()

    def write_status_file(self):
        if not self.status_file:
            return
        now = time.time()
        elapsed = max(0.001, now - self.start_time)
        status = {
            "timestamp": now,
            "elapsed_seconds": int(elapsed),
            "nodes_explored": self.nodes_explored,
            "engine_evals": self.engine_evals_count,
            "cache_hits": self.cache_hits,
            "db_reuse_hits": self.db_reuse_hits,
            "mates_found": self.mates_found,
            "tb_hits": self.tb_hits,
            "cycles_backtracked": self.cycles_backtracked,
            "failed_memo_size": len(self.failed_bfens),
            "current_ply": len(self.current_line_san),
            "current_line": " ".join(self.current_line_san),
            "ply_progress": {str(k): v for k, v in sorted(self.ply_progress.items())},
            "interrupted": self.interrupted,
        }
        try:
            os.makedirs(os.path.dirname(os.path.abspath(self.status_file)), exist_ok=True)
            with open(self.status_file, "w") as f:
                json.dump(status, f, indent=2)
        except Exception as e:
            logger.warning("Could not write status file: %s", e)

    def backup_to_shared(self, wait: bool = False):
        if not self.backup_db_path:
            return
        try:
            import subprocess
            if self._backup_proc is not None and self._backup_proc.poll() is None:
                if wait:
                    logger.info("Waiting for in-flight shared DB sync to complete...")
                    self._backup_proc.wait(timeout=120)
                else:
                    logger.info("Skipping shared DB sync because previous background copy is still running.")
                    return

            if (
                self.engine_evals_count == self._last_backup_evals
                and os.path.exists(self.backup_db_path)
                and os.path.getsize(self.backup_db_path) > 0
            ):
                return

            logger.info("Checkpointing SQLite WAL and syncing to %s...", self.backup_db_path)
            self.conn.commit()
            self.conn.execute("PRAGMA wal_checkpoint(PASSIVE);")
            self._last_backup_evals = self.engine_evals_count
            tmp_dest = f"{self.backup_db_path}.tmp.{os.getpid()}"
            cmd = f"cp -f '{self.db_path}' '{tmp_dest}' && mv -f '{tmp_dest}' '{self.backup_db_path}'"
            self._backup_proc = subprocess.Popen(["bash", "-c", cmd])
            if wait:
                self._backup_proc.wait(timeout=120)
        except Exception as e:
            logger.warning("Backup to %s failed: %s", self.backup_db_path, e)

    # -------------------------------------------------------------------------
    # Core Recursive Best-First Solver
    # -------------------------------------------------------------------------

    def prove_mate_recursive(
        self,
        board: chess.variant.AtomicBoard,
        ply: int,
        attacking_color: chess.Color,
        path_bfens: Set[str],
    ) -> Tuple[bool, str]:
        """
        Returns (proven: bool, failure_reason: str).
        failure_reason is 'cycle' if direct or child cycle caused failure,
        or 'score_drop', 'defender_mate', 'transposition_non_win', 'stopped', etc.
        """
        if self.interrupted:
            return False, "stopped"

        self.nodes_explored += 1
        bfen = to_bfen(board)
        is_attacker_turn = board.turn == attacking_color
        target_win_res = 1 if attacking_color == chess.WHITE else -1
        target_loss_res = -1 if attacking_color == chess.WHITE else 1

        self.maybe_checkpoint(force=False)

        # 1. Cycle detection:
        if bfen in path_bfens:
            logger.info(
                "[cycle] Repetition detected at ply %d (%s) along %s",
                ply,
                bfen,
                " ".join(self.current_line_san[-8:]),
            )
            return False, "cycle"

        # 2. Terminal / Tablebase check:
        term_or_tb = self.probe_terminal_or_tb(board, bfen)
        if term_or_tb is not None:
            self.assign_eval(bfen, term_or_tb)
            self.solve_bfen(bfen)
            if term_or_tb.result == target_win_res:
                self.mates_found += 1
                return True, "proven"
            return False, "terminal_non_win"

        # 3. Existing proven transposition in SQLite graph:
        existing_eval = self.get_effective_eval(bfen)
        if existing_eval is not None and existing_eval.result is not None:
            if existing_eval.result == target_win_res:
                return True, "proven_in_db"
            if existing_eval.result in (0, target_loss_res):
                return False, "transposition_non_win"

        # 3b. Session-level memoization of path-independent failed nodes:
        if bfen in self.failed_bfens:
            return False, self.failed_bfens[bfen]

        # 4. Check if Defender (AND) node already has evaluated children in Atomic.db:
        legal_moves = list(board.legal_moves)
        if not legal_moves:
            return False, "no_legal_moves"

        db_children = self.get_db_children_evals(bfen)
        evals: List[Tuple[str, str, Optional[int], Optional[int]]] = []

        if not is_attacker_turn and len(db_children) >= len(legal_moves) and existing_eval is not None:
            # All defender children already exist with evaluations in Atomic.db!
            # Skip redundant depth-16 FSF call and use existing DB evaluations.
            self.db_reuse_hits += 1
            best_cp_w = existing_eval.cp
            best_mate_w = None
        else:
            evals = self.evaluate_with_engine(board, bfen)
            if not evals:
                return False, "no_evals"

            best_uci, best_san, best_cp_w, best_mate_w = evals[0]
            pos_eval = self.best_eval_to_position_eval(evals[0])

            # Store static evaluation if unassigned
            if existing_eval is None:
                self.assign_eval(bfen, pos_eval)
                self.solve_bfen(bfen)

            # 5. Check if FSF confirms forced mate:
            if best_mate_w is not None:
                is_attacker_mate = (
                    (best_mate_w > 0)
                    if attacking_color == chess.WHITE
                    else (best_mate_w < 0)
                )
                if is_attacker_mate:
                    self.assign_eval(bfen, pos_eval)
                    self.solve_bfen(bfen)
                    self.mates_found += 1
                    logger.info(
                        "[mate] FSF confirmed mate (%+d) at ply %d (%s)",
                        best_mate_w,
                        ply,
                        " ".join(self.current_line_san[-6:]),
                    )
                    return True, "fsf_mate"
                else:
                    logger.info(
                        "[refuted] Defender forced mate (%+d) at ply %d",
                        best_mate_w,
                        ply,
                    )
                    self.failed_bfens[bfen] = "defender_mate"
                    return False, "defender_mate"

        # 6. Optional depth cap (disabled by default when max_depth <= 0) & winning score threshold check:
        if self.max_depth > 0 and ply >= self.max_depth:
            logger.info("[cutoff] Max safety depth (%d) reached at %s", self.max_depth, bfen)
            return False, "max_depth"

        attacker_cp = (
            best_cp_w
            if (attacking_color == chess.WHITE or best_cp_w is None)
            else -best_cp_w
        )
        if ply >= 20 and attacker_cp is not None and attacker_cp < self.min_win_cp:
            logger.info(
                "[score-drop] Ply %d eval dropped to %+d cp (< %+d cp) at %s",
                ply,
                attacker_cp,
                self.min_win_cp,
                bfen,
            )
            self.failed_bfens[bfen] = "score_drop"
            return False, "score_drop"

        # 7. Branching (Attacker = OR node backtracking on cycles or refutations / Defender = AND node):
        path_bfens.add(bfen)
        try:
            if is_attacker_turn:
                # Build candidate moves combining FSF MultiPV and existing DB evaluations
                # Tuple: (uci, san, cp_w, mate_w, score_key, is_irreversible)
                cand_map: Dict[str, Tuple[str, str, Optional[int], Optional[int], int, bool]] = {}
                for idx, (c_uci, c_san, c_cp_w, c_mate_w) in enumerate(evals):
                    c_att_cp = (
                        c_cp_w
                        if (attacking_color == chess.WHITE or c_cp_w is None)
                        else -c_cp_w
                    )
                    is_cand_mate = c_mate_w is not None and (
                        c_mate_w > 0
                        if attacking_color == chess.WHITE
                        else c_mate_w < 0
                    )
                    score_key = (
                        100000 - abs(c_mate_w)
                        if is_cand_mate
                        else (c_att_cp if c_att_cp is not None else -99999)
                    )
                    mv_obj = chess.Move.from_uci(c_uci)
                    is_irrev = board.is_zeroing(mv_obj) or board.is_castling(mv_obj)
                    cand_map[c_uci] = (c_uci, c_san, c_cp_w, c_mate_w, score_key, is_irrev)

                # Also check all legal moves for existing higher computed evaluations in DB
                for m in legal_moves:
                    m_uci = m.uci()
                    board.push(m)
                    c_bfen = to_bfen(board)
                    board.pop()
                    c_ev = db_children.get(c_bfen) or self.get_effective_eval(c_bfen)
                    if c_ev is None:
                        continue
                    is_irrev = board.is_zeroing(m) or board.is_castling(m)
                    if c_ev.result == target_win_res:
                        m_san = board.san(m)
                        dtw_val = c_ev.dtw if c_ev.dtw is not None else 50
                        cand_map[m_uci] = (
                            m_uci,
                            m_san,
                            None,
                            (dtw_val + 1) // 2,
                            200000 - dtw_val,
                            is_irrev,
                        )
                    elif c_ev.result is None and c_ev.cp is not None:
                        db_att_cp = c_ev.cp if attacking_color == chess.WHITE else -c_ev.cp
                        if db_att_cp >= self.min_win_cp:
                            if m_uci in cand_map:
                                u, s, cpw, mw, sk, irr = cand_map[m_uci]
                                if db_att_cp > sk:
                                    cand_map[m_uci] = (u, s, c_ev.cp, mw, db_att_cp, irr)
                            else:
                                m_san = board.san(m)
                                cand_map[m_uci] = (m_uci, m_san, c_ev.cp, None, db_att_cp, is_irrev)

                # Sort by score_key descending, breaking ties in favor of irreversible moves
                sorted_cands = sorted(
                    cand_map.values(),
                    key=lambda x: (x[4], 1 if x[5] else 0),
                    reverse=True,
                )
                candidates: List[Tuple[str, str, Optional[int], Optional[int], int, bool]] = []
                for idx, item in enumerate(sorted_cands):
                    if idx == 0 or item[4] >= self.min_win_cp:
                        candidates.append(item)

                last_reason = "no_candidates"
                saw_cycle = False
                expanded_irrev = False
                expanded_all = False
                tried_ucis: Set[str] = set()
                idx = 0
                while idx < len(candidates):
                    if self.interrupted:
                        return False, "stopped"

                    c_uci, c_san, c_cp_w, c_mate_w, c_sk, c_irrev = candidates[idx]
                    tried_ucis.add(c_uci)
                    move = chess.Move.from_uci(c_uci)
                    board.push(move)
                    child_bfen = to_bfen(board)
                    self.add_link(bfen, child_bfen)

                    self.current_line_san.append(c_san)
                    self.ply_progress[ply] = f"{c_san}({idx + 1}/{len(candidates)})"

                    child_ok, reason = self.prove_mate_recursive(
                        board=board,
                        ply=ply + 1,
                        attacking_color=attacking_color,
                        path_bfens=path_bfens,
                    )

                    self.current_line_san.pop()
                    board.pop()

                    if child_ok:
                        self.ply_progress.pop(ply, None)
                        self.solve_bfen(bfen)
                        return True, "proven"

                    if reason == "stopped":
                        return False, "stopped"

                    last_reason = reason
                    if reason == "cycle":
                        saw_cycle = True

                    # Backtrack on cycles or refutations:
                    # 1) Ensure winning irreversible moves are injected if not already checked
                    if not expanded_irrev:
                        expanded_irrev = True
                        rem_irrev_count = sum(1 for item in candidates[idx + 1 :] if item[5])
                        if rem_irrev_count == 0:
                            extra_irrev = self.evaluate_extra_candidates(
                                board, bfen, attacking_color, tried_ucis, only_irreversible=True
                            )
                            existing_ucis = {item[0] for item in candidates}
                            for item in extra_irrev:
                                if item[0] not in existing_ucis:
                                    candidates.append(item)
                                    existing_ucis.add(item[0])

                    # 2) If a cycle occurred, prioritize irreversible moves among remaining candidates
                    if reason == "cycle" and idx + 1 < len(candidates):
                        remaining = candidates[idx + 1 :]
                        remaining.sort(
                            key=lambda x: (1 if x[5] else 0, x[4]),
                            reverse=True,
                        )
                        candidates[idx + 1 :] = remaining

                    # 3) If we exhausted current candidates, check any remaining untried legal moves
                    if idx + 1 >= len(candidates) and not expanded_all:
                        expanded_all = True
                        existing_ucis = {item[0] for item in candidates} | tried_ucis
                        if len(existing_ucis) < len(legal_moves):
                            extra_all = self.evaluate_extra_candidates(
                                board, bfen, attacking_color, existing_ucis, only_irreversible=False
                            )
                            for item in extra_all:
                                if item[0] not in existing_ucis:
                                    candidates.append(item)
                                    existing_ucis.add(item[0])
                            if idx + 1 < len(candidates):
                                remaining = candidates[idx + 1 :]
                                if saw_cycle:
                                    remaining.sort(key=lambda x: (1 if x[5] else 0, x[4]), reverse=True)
                                else:
                                    remaining.sort(key=lambda x: (x[4], 1 if x[5] else 0), reverse=True)
                                candidates[idx + 1 :] = remaining

                    if idx + 1 < len(candidates):
                        self.cycles_backtracked += 1
                        next_san = candidates[idx + 1][1]
                        next_cp = candidates[idx + 1][2]
                        next_irrev = candidates[idx + 1][5]
                        logger.info(
                            "[backtrack] Attacker move %s at ply %d failed (%s); trying #%d candidate %s (cp=%s, irrev=%s)",
                            c_san,
                            ply,
                            reason,
                            idx + 2,
                            next_san,
                            next_cp,
                            next_irrev,
                        )
                        idx += 1
                        continue
                    break

                self.ply_progress.pop(ply, None)
                final_reason = "cycle" if saw_cycle else last_reason
                if not saw_cycle and final_reason in (
                    "score_drop",
                    "defender_mate",
                    "transposition_non_win",
                    "terminal_non_win",
                ):
                    self.failed_bfens[bfen] = final_reason
                return False, final_reason

            else:
                # DEFENDER (AND node): Must refute ALL legal moves, ordered best-defense-first
                move_sans = {m: board.san(m) for m in legal_moves}
                engine_order = {cand[0]: i for i, cand in enumerate(evals)}

                # Pre-link all legal moves and check existing DB evaluations for ordering
                child_info = []
                for m in legal_moves:
                    m_uci = m.uci()
                    m_san = move_sans[m]
                    board.push(m)
                    c_bfen = to_bfen(board)
                    board.pop()
                    if c_bfen not in db_children:
                        self.add_link(bfen, c_bfen)
                    c_eval = db_children.get(c_bfen) or self.get_effective_eval(c_bfen)
                    eng_rank = engine_order.get(m_uci, 999)
                    # Sort key: FSF top defense first, then lowest attacker cp in DB
                    db_cp = c_eval.cp if (c_eval and c_eval.cp is not None) else 99999
                    if attacking_color == chess.BLACK:
                        db_cp = -db_cp
                    child_info.append((eng_rank, db_cp, m, m_san, c_bfen, c_eval))

                child_info.sort(key=lambda x: (x[0], x[1]))

                for i, (_, _, m, m_san, c_bfen, c_eval) in enumerate(child_info):
                    if self.interrupted:
                        return False, "stopped"

                    self.ply_progress[ply] = f"{m_san}({i + 1}/{len(child_info)})"

                    # Skip re-searching if already proven win for attacker in DB
                    if c_eval is not None and c_eval.result == target_win_res:
                        continue

                    board.push(m)
                    self.current_line_san.append(m_san)

                    child_ok, reason = self.prove_mate_recursive(
                        board=board,
                        ply=ply + 1,
                        attacking_color=attacking_color,
                        path_bfens=path_bfens,
                    )

                    self.current_line_san.pop()
                    board.pop()

                    if not child_ok:
                        logger.info(
                            "[defense-holds] Defender move %s (%d/%d) at ply %d held (%s)",
                            m_san,
                            i + 1,
                            len(child_info),
                            ply,
                            reason,
                        )
                        self.ply_progress.pop(ply, None)
                        if reason in (
                            "score_drop",
                            "defender_mate",
                            "transposition_non_win",
                            "terminal_non_win",
                        ):
                            self.failed_bfens[bfen] = reason
                        return False, reason

                self.ply_progress.pop(ply, None)
                self.solve_bfen(bfen)
                return True, "proven"
        finally:
            path_bfens.remove(bfen)


def main():
    parser = argparse.ArgumentParser(
        description="Unattended Best-First Atomic Chess Subtree Mate Solver"
    )
    parser.add_argument(
        "--line",
        type=str,
        default="Nf3 d6",
        help="Starting move line in SAN or UCI (e.g. 'Nf3 d6' or 'g1f3 d7d6')",
    )
    parser.add_argument("--fen", type=str, default=None, help="Starting FEN (overrides --line)")
    parser.add_argument("--db", type=str, default="data/Atomic.db", help="Local SQLite database path")
    parser.add_argument(
        "--backup-db",
        type=str,
        default="/home/antigravity/.gemini/Atomic.db",
        help="Persistent shared database path for periodic checkpoints (empty to disable)",
    )
    parser.add_argument(
        "--backup-interval",
        type=float,
        default=900.0,
        help="Seconds between backups to --backup-db (default 900s)",
    )
    parser.add_argument("--tb-dir", type=str, default="data/tablebases/atomic", help="Path to .atbd tablebases")
    parser.add_argument("--engine", type=str, default="./fairy-stockfish", help="Path to Fairy-Stockfish binary")
    parser.add_argument("--nnue", type=str, default="atomic-2cf13ff256cc.nnue", help="Path to Atomic NNUE file")
    parser.add_argument("--depth", type=int, default=16, help="Fairy-Stockfish search depth (default 16)")
    parser.add_argument("--multipv", type=int, default=5, help="MultiPV count for candidate moves (default 5)")
    parser.add_argument(
        "--min-win-cp",
        type=int,
        default=200,
        help="Minimum winning evaluation in cp to continue past 20 plies / try alternate candidates (default 200)",
    )
    parser.add_argument(
        "--max-depth",
        type=int,
        default=0,
        help="Maximum safety ply depth (default 0 = no depth limit)",
    )
    parser.add_argument(
        "--backtrack-any",
        action="store_true",
        default=True,
        help="Backtrack and try next attacker candidate on ANY child failure (cycles or refutations)",
    )
    parser.add_argument(
        "--status-file",
        type=str,
        default="data/best_first_status.json",
        help="JSON status checkpoint file",
    )
    parser.add_argument("--threads", type=int, default=2, help="Engine threads")
    parser.add_argument("--hash", type=int, default=256, help="Engine hash MB")
    args = parser.parse_args()

    board = chess.variant.AtomicBoard()
    prolog_sans: List[str] = []
    if args.fen:
        board = chess.variant.AtomicBoard(args.fen)
    else:
        tokens = [t.strip() for t in args.line.replace(",", " ").split() if t.strip()]
        for tok in tokens:
            try:
                m = board.parse_san(tok)
            except ValueError:
                m = board.parse_uci(tok)
            prolog_sans.append(board.san(m))
            board.push(m)

    root_bfen = to_bfen(board)
    logger.info("========================================================")
    logger.info("Unattended Best-First Atomic Solver")
    logger.info("Prolog:      %s", " ".join(prolog_sans) if prolog_sans else "(startpos)")
    logger.info("Root BFEN:   %s", root_bfen)
    logger.info("Database:    %s (backup: %s)", args.db, args.backup_db)
    logger.info("Engine:      %s (depth=%d, multipv=%d)", args.engine, args.depth, args.multipv)
    logger.info(
        "Min Win CP:  %+d cp | Max Depth: %s",
        args.min_win_cp,
        "Unlimited" if args.max_depth <= 0 else str(args.max_depth),
    )
    logger.info("Backtrack:   Cycles & Refutations (Irreversible Moves First on Cycles)")
    logger.info("========================================================")

    solver = UnattendedBestFirstSolver(
        db_path=args.db,
        backup_db_path=args.backup_db if args.backup_db else None,
        tb_dir=args.tb_dir,
        engine_binary=args.engine,
        nnue_path=args.nnue,
        engine_depth=args.depth,
        multipv=args.multipv,
        min_win_cp=args.min_win_cp,
        max_depth=args.max_depth,
        backtrack_on_any_failure=True,
        status_file=args.status_file,
        backup_interval_sec=args.backup_interval,
        threads=args.threads,
        hash_mb=args.hash,
    )

    # Seed path_bfens with prolog history so cycles back into prolog are caught
    path_bfens: Set[str] = set()
    temp_b = chess.variant.AtomicBoard()
    if not args.fen:
        for san in prolog_sans[:-1]:
            path_bfens.add(to_bfen(temp_b))
            temp_b.push_san(san)
        if prolog_sans:
            path_bfens.add(to_bfen(temp_b))

    solver.current_line_san = list(prolog_sans)

    try:
        proven, reason = solver.prove_mate_recursive(
            board=board,
            ply=0,
            attacking_color=chess.WHITE,
            path_bfens=path_bfens,
        )
        solver.maybe_checkpoint(force=True)
        root_eval = solver.get_effective_eval(root_bfen)
        logger.info("========================================================")
        logger.info("Search Finished! Proven: %s | Reason: %s", proven, reason)
        logger.info("Root Effective Eval: %s", root_eval)
        logger.info(
            "Nodes: %d | Engine Evals: %d (Cache:%d DB:%d) | Mates: %d | Backtracks: %d",
            solver.nodes_explored,
            solver.engine_evals_count,
            solver.cache_hits,
            solver.db_reuse_hits,
            solver.mates_found,
            solver.cycles_backtracked,
        )
        logger.info("========================================================")
    finally:
        solver.close()


if __name__ == "__main__":
    main()
