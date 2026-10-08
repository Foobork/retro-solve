#!/usr/bin/env python3
"""
merge_atomic_dbs.py

Merges evaluations, proof numbers, and edges from a source SQLite database (e.g. downloaded from GitHub Actions)
into a target local SQLite database (e.g. data/Atomic.db).
"""

import argparse
import os
import sqlite3
import sys

def merge_databases(source_path: str, target_path: str):
    if not os.path.exists(source_path):
        print(f"Error: Source database does not exist: {source_path}", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(target_path):
        print(f"Error: Target database does not exist: {target_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Merging: {source_path} -> {target_path}")

    target_conn = sqlite3.connect(target_path)
    target_cur = target_conn.cursor()

    # Ensure target WAL mode and schemas
    target_cur.execute("PRAGMA journal_mode = WAL;")

    # Ensure v6 columns exist on target
    target_cur.execute("PRAGMA table_info(positions);")
    target_cols = {row[1].lower() for row in target_cur.fetchall()}
    for col, col_type in [('proof_status', 'INTEGER DEFAULT 0'), ('pn', 'INTEGER DEFAULT 1'), ('dn', 'INTEGER DEFAULT 1'), ('proven_move_id', 'INTEGER')]:
        if col not in target_cols:
            target_cur.execute(f"ALTER TABLE positions ADD COLUMN {col} {col_type};")

    target_cur.execute("PRAGMA user_version = 6;")
    target_conn.commit();

    # Attach source database
    target_cur.execute(f"ATTACH DATABASE ? AS source;", (os.path.abspath(source_path),))

    # 1. Upsert positions
    print("Upserting positions...")
    target_cur.execute("""
        INSERT INTO positions (
            bfen, assigned_result, assigned_dtw, assigned_cp,
            computed_result, computed_dtw, computed_cp,
            proof_status, pn, dn, proven_move_id
        )
        SELECT
            bfen, assigned_result, assigned_dtw, assigned_cp,
            computed_result, computed_dtw, computed_cp,
            proof_status, pn, dn, proven_move_id
        FROM source.positions
        WHERE 1=1
        ON CONFLICT(bfen) DO UPDATE SET
            computed_result = COALESCE(excluded.computed_result, positions.computed_result),
            computed_dtw = COALESCE(excluded.computed_dtw, positions.computed_dtw),
            proof_status = CASE 
                WHEN excluded.proof_status != 0 THEN excluded.proof_status 
                ELSE positions.proof_status 
            END,
            pn = CASE 
                WHEN excluded.proof_status != 0 THEN excluded.pn
                WHEN positions.proof_status != 0 THEN positions.pn
                ELSE MIN(COALESCE(positions.pn, 999999999), COALESCE(excluded.pn, 999999999))
            END,
            dn = CASE 
                WHEN excluded.proof_status != 0 THEN excluded.dn
                WHEN positions.proof_status != 0 THEN positions.dn
                ELSE MAX(COALESCE(positions.dn, 1), COALESCE(excluded.dn, 1))
            END,
            proven_move_id = COALESCE(excluded.proven_move_id, positions.proven_move_id);
    """)
    positions_merged = target_cur.rowcount
    print(f"Positions processed: {positions_merged}")

    # 2. Merge edges
    print("Merging edges...")
    target_cur.execute("""
        INSERT OR IGNORE INTO edges (source_id, target_id)
        SELECT target_s.id, target_t.id
        FROM source.edges e
        JOIN source.positions src_s ON e.source_id = src_s.id
        JOIN source.positions src_t ON e.target_id = src_t.id
        JOIN positions target_s ON src_s.bfen = target_s.bfen
        JOIN positions target_t ON src_t.bfen = target_t.bfen;
    """)
    edges_merged = target_cur.rowcount
    print(f"Edges processed: {edges_merged}")

    target_conn.commit()
    target_cur.execute("DETACH DATABASE source;")
    target_conn.close()

    print("Database merge completed successfully!")

def main():
    parser = argparse.ArgumentParser(description="Merge Atomic Chess SQLite databases.")
    parser.add_argument("source", help="Source SQLite DB to merge from (e.g. downloaded cloud checkpoint)")
    parser.add_argument("target", help="Target SQLite DB to merge into (e.g. data/Atomic.db)")
    args = parser.parse_args()

    merge_databases(args.source, args.target)

if __name__ == "__main__":
    main()
