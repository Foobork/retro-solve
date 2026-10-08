import sqlite3
import chess
import chess.variant
import os

def fix_database(db_path: str):
    if not os.path.exists(db_path):
        print(f"Database not found: {db_path}")
        return

    print(f"==================================================")
    print(f"Fixing terminal DTWs in: {db_path}")
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='positions'")
    if not cur.fetchone():
        print(f"Skipping {db_path} (no 'positions' table).")
        conn.close()
        return

    # 1. Find all positions with assigned_result = -1 and assigned_dtw IS NULL
    cur.execute("""
        SELECT id, bfen
        FROM positions
        WHERE assigned_result = -1 AND assigned_dtw IS NULL
    """)
    rows = cur.fetchall()
    print(f"Found {len(rows)} positions with assigned_result = -1 and NULL DTW.")

    term_black_ids = []
    non_term_ids = []

    for pid, bfen in rows:
        parts = bfen.split(' ')
        fen = f"{parts[0]} {parts[1]} {parts[2]} {parts[3]} 0 1"
        try:
            b = chess.variant.AtomicBoard(fen)
            if b.is_game_over() and b.outcome() and b.outcome().winner == chess.BLACK:
                term_black_ids.append(pid)
            else:
                non_term_ids.append(pid)
        except Exception as e:
            non_term_ids.append(pid)

    print(f"  -> Terminal Black wins: {len(term_black_ids)}")
    print(f"  -> Non-terminal positions: {len(non_term_ids)}")

    # Update terminal positions to assigned_dtw = 0, computed_dtw = 0
    if term_black_ids:
        cur.executemany(
            "UPDATE positions SET assigned_dtw = 0, computed_dtw = 0 WHERE id = ?",
            [(pid,) for pid in term_black_ids]
        )
        print(f"  Updated {len(term_black_ids)} terminal positions with assigned_dtw = 0, computed_dtw = 0.")

    # Non-terminal positions: clear assigned_result/assigned_dtw so CSR solver can compute DTW
    if non_term_ids:
        cur.executemany(
            "UPDATE positions SET assigned_result = NULL, assigned_dtw = NULL WHERE id = ?",
            [(pid,) for pid in non_term_ids]
        )
        print(f"  Cleared assigned_result/assigned_dtw on {len(non_term_ids)} non-terminal positions.")

    # 2. Check any White terminal positions that might have NULL DTW
    cur.execute("""
        SELECT id, bfen
        FROM positions
        WHERE assigned_result = 1 AND assigned_dtw IS NULL
    """)
    w_rows = cur.fetchall()
    term_white_ids = []
    for pid, bfen in w_rows:
        parts = bfen.split(' ')
        fen = f"{parts[0]} {parts[1]} {parts[2]} {parts[3]} 0 1"
        try:
            b = chess.variant.AtomicBoard(fen)
            if b.is_game_over() and b.outcome() and b.outcome().winner == chess.WHITE:
                term_white_ids.append(pid)
        except Exception:
            pass
    if term_white_ids:
        cur.executemany(
            "UPDATE positions SET assigned_dtw = 0, computed_dtw = 0 WHERE id = ?",
            [(pid,) for pid in term_white_ids]
        )
        print(f"  Updated {len(term_white_ids)} terminal White win positions with DTW = 0.")

    conn.commit()
    conn.close()
    print("Database fix completed.")

if __name__ == '__main__':
    for p in ['data/Atomic.db', '.dart_tool/sqflite_common_ffi/databases/Atomic.db']:
        fix_database(p)
