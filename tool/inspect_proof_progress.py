#!/usr/bin/env python3
"""
inspect_proof_progress.py

Telemetry and inspection utility for Atomic Chess proof subtrees.
Queries SQLite (Atomic.db v6) and outputs:
- Subtree root proof status, proof number (pn), and disproof number (dn)
- Reachable graph metrics: total nodes, solved wins, losses, unexpanded leaves, solve %
- Ply-by-ply breakdown of defensive candidate branches
- The current Most Proving Node (MPN) Critical Path (the exact line the solver is attacking)
"""

import argparse
import json
import os
import sqlite3
import sys
from typing import Dict, List, Optional, Set, Tuple

import chess
import chess.variant

def to_bfen(board: chess.variant.AtomicBoard) -> str:
    """Returns canonical BFEN."""
    return ' '.join(board.fen().split()[:4])

def format_status(proof_status: Optional[int], comp_res: Optional[int], dtw: Optional[int]) -> str:
    if proof_status == 1:
        mate_str = f" (M{(dtw + 1) // 2})" if dtw is not None else ""
        return f"\033[92mPROVEN WIN{mate_str}\033[0m"
    elif proof_status == -1:
        return "\033[91mPROVEN LOSS\033[0m"
    elif proof_status == 2:
        return "\033[93mPROVEN DRAW\033[0m"
    elif comp_res == 1:
        mate_str = f" (M{(dtw + 1) // 2})" if dtw is not None else ""
        return f"\033[36mPartial Win{mate_str}\033[0m"
    elif comp_res == -1:
        return "\033[35mPartial Loss\033[0m"
    elif comp_res == 0:
        return "\033[33mPartial Draw\033[0m"
    return "In Progress"

def ensure_db_schema(conn: sqlite3.Connection):
    cur = conn.cursor()
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

def inspect_subtree(db_path: str, root_line: str, fen: Optional[str] = None, json_output: bool = False):
    if not os.path.exists(db_path):
        print(f"Error: Database not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    ensure_db_schema(conn)
    cur = conn.cursor()

    # Build target board
    board = chess.variant.AtomicBoard()
    prolog_moves = []
    if fen:
        board = chess.variant.AtomicBoard(fen)
    else:
        for m_str in root_line.split():
            m = chess.Move.from_uci(m_str.strip())
            board.push(m)
            prolog_moves.append(m)

    root_bfen = to_bfen(board)

    # Fetch root row
    cur.execute("""
        SELECT id, bfen, proof_status, pn, dn, computed_result, computed_dtw, assigned_result, assigned_dtw
        FROM positions WHERE bfen = ?
    """, (root_bfen,))
    root_row = cur.fetchone()

    if not root_row:
        print(f"Position not found in database: {root_bfen}")
        conn.close()
        return

    root_id, _, p_status, pn, dn, c_res, c_dtw, a_res, a_dtw = root_row
    effective_res = c_res if c_res is not None else a_res
    effective_dtw = c_dtw if c_dtw is not None else a_dtw

    # Traverse reachable nodes in subtree
    visited = {root_id}
    frontier = [root_id]
    parent_map = {}
    edges_count = 0

    while frontier:
        next_frontier = []
        for i in range(0, len(frontier), 500):
            chunk = frontier[i:i+500]
            placeholders = ','.join('?' for _ in chunk)
            cur.execute(f"SELECT source_id, target_id FROM edges WHERE source_id IN ({placeholders})", chunk)
            rows = cur.fetchall()
            edges_count += len(rows)

            for s_id, t_id in rows:
                if t_id not in visited:
                    visited.add(t_id)
                    parent_map[t_id] = s_id
                    next_frontier.append(t_id)

        frontier = next_frontier

    total_nodes = len(visited)

    # Fetch statistics across all reachable nodes
    visited_list = list(visited)
    solved_wins = 0
    solved_losses = 0
    draws = 0
    unsolved = 0

    for i in range(0, len(visited_list), 500):
        chunk = visited_list[i:i+500]
        placeholders = ','.join('?' for _ in chunk)
        cur.execute(f"""
            SELECT proof_status, computed_result, assigned_result
            FROM positions WHERE id IN ({placeholders})
        """, chunk)
        for ps, cr, ar in cur.fetchall():
            res = cr if cr is not None else ar
            if ps == 1 or res == 1:
                solved_wins += 1
            elif ps == -1 or res == -1:
                solved_losses += 1
            elif ps == 2 or res == 0:
                draws += 1
            else:
                unsolved += 1

    solve_pct = (solved_wins / total_nodes * 100) if total_nodes > 0 else 0.0

    # Query children of root
    cur.execute("""
        SELECT p.id, p.bfen, p.proof_status, p.pn, p.dn, p.computed_result, p.computed_dtw
        FROM edges e
        JOIN positions p ON e.target_id = p.id
        WHERE e.source_id = ?
    """, (root_id,))
    child_rows = cur.fetchall()

    # Map children to legal moves
    child_moves = []
    for m in board.legal_moves:
        board.push(m)
        c_bfen = to_bfen(board)
        board.pop()

        # Find matching row
        matching = [r for r in child_rows if r[1] == c_bfen]
        if matching:
            r = matching[0]
            child_moves.append({
                "uci": m.uci(),
                "san": board.san(m),
                "id": r[0],
                "bfen": r[1],
                "proof_status": r[2],
                "pn": r[3] if r[3] is not None else 1,
                "dn": r[4] if r[4] is not None else 1,
                "result": r[5],
                "dtw": r[6]
            })
        else:
            child_moves.append({
                "uci": m.uci(),
                "san": board.san(m),
                "id": None,
                "bfen": c_bfen,
                "proof_status": 0,
                "pn": 1,
                "dn": 1,
                "result": None,
                "dtw": None
            })

    # Sort children:
    # If White turn: sort by lowest pn (most promising winning line)
    # If Black turn: sort by lowest dn (most fragile defense first)
    is_white = (board.turn == chess.WHITE)
    if is_white:
        child_moves.sort(key=lambda c: (c["pn"] if c["pn"] is not None else 1, c["uci"]))
    else:
        child_moves.sort(key=lambda c: (c["dn"] if c["dn"] is not None else 1, c["uci"]))

    # Trace Most Proving Node (MPN) Critical Path
    mpn_path = []
    curr_board = board.copy()
    curr_id = root_id
    visited_mpn = set()

    while curr_id and curr_id not in visited_mpn:
        visited_mpn.add(curr_id)
        cur.execute("""
            SELECT p.id, p.bfen, p.proof_status, p.pn, p.dn, p.computed_result
            FROM edges e
            JOIN positions p ON e.target_id = p.id
            WHERE e.source_id = ?
        """, (curr_id,))
        c_rows = cur.fetchall()
        if not c_rows:
            break

        c_is_white = (curr_board.turn == chess.WHITE)
        best_child = None
        best_move_san = None

        for m in curr_board.legal_moves:
            curr_board.push(m)
            target_bfen = to_bfen(curr_board)
            curr_board.pop()

            m_row = [r for r in c_rows if r[1] == target_bfen]
            if not m_row:
                continue
            r = m_row[0]
            cid, cbfen, cps, cpn, cdn, cr = r
            cpn = cpn if cpn is not None else 1
            cdn = cdn if cdn is not None else 1

            if c_is_white:
                # Pick child with min pn
                if best_child is None or cpn < best_child[3]:
                    best_child = r
                    best_move_san = curr_board.san(m)
                    best_move = m
            else:
                # Pick child with min dn
                if best_child is None or cdn < best_child[4]:
                    best_child = r
                    best_move_san = curr_board.san(m)
                    best_move = m

        if best_child and best_child[3] != 0:  # Continue along unsolved frontier
            mpn_path.append(best_move_san)
            curr_board.push(best_move)
            curr_id = best_child[0]
        else:
            break

    conn.close()

    if json_output:
        res_json = {
            "root_bfen": root_bfen,
            "turn": "White" if is_white else "Black",
            "proof_status": p_status,
            "pn": pn,
            "dn": dn,
            "total_nodes": total_nodes,
            "solved_wins": solved_wins,
            "solved_losses": solved_losses,
            "unsolved": unsolved,
            "solve_percentage": round(solve_pct, 2),
            "mpn_critical_path": mpn_path,
            "children": child_moves
        }
        print(json.dumps(res_json, indent=2))
        return

    # Formatted terminal display
    print("=" * 70)
    print(f"ATOMIC PROOF INSPECTION: {root_line if root_line else root_bfen}")
    print("=" * 70)
    status_str = format_status(p_status, effective_res, effective_dtw)
    turn_str = "White to move (OR Node)" if is_white else "Black to move (AND Node)"
    print(f"Turn:             {turn_str}")
    print(f"Root Outcome:     {status_str}")
    print(f"Proof Number:     pn={pn if pn is not None else 'N/A'}, dn={dn if dn is not None else 'N/A'}")
    print(f"Subtree Nodes:    {total_nodes:,} positions, {edges_count:,} edges")
    print(f"Solve Rate:       {solve_pct:.1f}% ({solved_wins:,} wins, {solved_losses:,} losses, {unsolved:,} unrefuted)")
    print("-" * 70)

    print(f"Immediate Branch Responses ({len(child_moves)} legal moves):")
    print(f"{'Move':<10} | {'Status':<22} | {'pn':<8} | {'dn':<8} | {'DTW':<6}")
    print("-" * 70)
    for c in child_moves:
        c_status = format_status(c["proof_status"], c["result"], c["dtw"])
        c_dtw = f"{c['dtw']} plies" if c['dtw'] is not None else "-"
        c_pn = str(c['pn']) if c['pn'] is not None else "1"
        c_dn = str(c['dn']) if c['dn'] is not None else "1"
        print(f"{c['san']:<10} | {c_status:<31} | {c_pn:<8} | {c_dn:<8} | {c_dtw:<6}")

    print("-" * 70)
    if mpn_path:
        print(f"Most Proving Node (MPN) Critical Path ({len(mpn_path)} plies):")
        print("  " + " -> ".join(mpn_path))
    else:
        print("Most Proving Node: Branch is completely solved or unexpanded.")
    print("=" * 70)

def main():
    parser = argparse.ArgumentParser(description="Inspect Atomic Chess Subtree Proof Progress")
    parser.add_argument("--line", type=str, default="g1f3 d7d6", help="UCI move sequence (default: 'g1f3 d7d6')")
    parser.add_argument("--fen", type=str, default=None, help="Direct FEN string")
    parser.add_argument("--db", type=str, default="data/Atomic.db", help="Path to SQLite database")
    parser.add_argument("--json", action="store_true", help="Output summary as JSON")
    args = parser.parse_args()

    inspect_subtree(args.db, args.line, fen=args.fen, json_output=args.json)

if __name__ == "__main__":
    main()
