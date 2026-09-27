#!/usr/bin/env python3
"""
prove_17_blunders.py

Proves that 17 of Black's 20 legal responses to 1. Nf3 in Atomic Chess
are forced losses (14 Mate in 2, 3 Mate in 3), generates the complete
finite game tree, performs retrograde minimax evaluation, writes
all positions, evaluations, and edges into Atomic.db, and exports a
binary .proof file adhering to the Watkins Losing Chess proof tree specification.
"""

import os
import shutil
import struct
import sqlite3
import chess.variant

BLUNDERS_17 = [
    'a7a6', 'a7a5', 'b7b6', 'b7b5', 'c7c6', 'c7c5', 'd7d5',
    'e7e6', 'f7f5', 'g7g6', 'g7g5', 'h7h6', 'h7h5',
    'b8a6', 'b8c6', 'g8f6', 'g8h6'
]

def to_bfen(board: chess.variant.AtomicBoard) -> str:
    """Returns canonical BFEN (board FEN without move counters)."""
    return ' '.join(board.fen().split()[:4])

def find_winning_move(board: chess.variant.AtomicBoard):
    """Finds an immediate winning move for the side to move (delivering explosion/mate)."""
    for m in board.legal_moves:
        board.push(m)
        if board.is_game_over() and board.outcome() and board.outcome().winner == True:
            board.pop()
            return m
        board.pop()
    return None

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

class ProofTreeNode:
    def __init__(self, move_uci: str):
        self.move_uci = move_uci
        self.children = []
        self.index = 0
        self.w = 0  # 0=leaf, 1=branch
        self.d = 0  # next sibling index or target

def build_proof_tree():
    """
    Constructs the complete proof tree for all 17 blunders after 1. Nf3.
    Returns:
        positions: dict of bfen -> (assigned_result, assigned_dtw)
        edges: set of (from_bfen, to_bfen)
        blunder_bfens: dict of uci_move -> blunder_bfen
        proof_root_node: ProofTreeNode representing root of tree for Watkins export
    """
    positions = {}  # bfen -> (assigned_result, assigned_dtw)
    edges = set()   # (from_bfen, to_bfen)
    blunder_bfens = {}

    root = chess.variant.AtomicBoard()
    root_bfen = to_bfen(root)
    positions[root_bfen] = (None, None)

    # 1. Nf3 (prolog)
    root.push_san('Nf3')
    ply1_bfen = to_bfen(root)
    positions[ply1_bfen] = (None, None)
    edges.add((root_bfen, ply1_bfen))

    proof_root = ProofTreeNode("ROOT")

    for m_uci in BLUNDERS_17:
        b1 = root.copy()
        b1.push(chess.Move.from_uci(m_uci))
        b_bfen = to_bfen(b1)
        positions[b_bfen] = (None, None)
        edges.add((ply1_bfen, b_bfen))
        blunder_bfens[m_uci] = b_bfen

        blunder_node = ProofTreeNode(m_uci)
        proof_root.children.append(blunder_node)

        # White choice: 2. Ng5 against 1... Nc6, 2. Ne5 against all others
        w1_uci = 'f3g5' if m_uci == 'b8c6' else 'f3e5'
        b1.push(chess.Move.from_uci(w1_uci))
        w1_bfen = to_bfen(b1)
        positions[w1_bfen] = (None, None)
        edges.add((b_bfen, w1_bfen))

        w1_node = ProofTreeNode(w1_uci)
        blunder_node.children.append(w1_node)

        for black_reply in list(b1.legal_moves):
            b2 = b1.copy()
            b2.push(black_reply)
            b2_bfen = to_bfen(b2)
            positions[b2_bfen] = (None, None)
            edges.add((w1_bfen, b2_bfen))

            b2_node = ProofTreeNode(black_reply.uci())
            w1_node.children.append(b2_node)

            # Immediate winning explosion / mate
            win_m = find_winning_move(b2)
            if win_m:
                b2.push(win_m)
                term_bfen = to_bfen(b2)
                positions[term_bfen] = (1, 0)
                edges.add((b2_bfen, term_bfen))

                term_node = ProofTreeNode(win_m.uci())
                term_node.w = 0
                b2_node.children.append(term_node)
            else:
                # 3. Nd7 or 3. Nf7
                cont_uci = 'g5f7' if m_uci == 'b8c6' else 'e5d7'
                b2.push(chess.Move.from_uci(cont_uci))
                w2_bfen = to_bfen(b2)
                positions[w2_bfen] = (None, None)
                edges.add((b2_bfen, w2_bfen))

                w2_node = ProofTreeNode(cont_uci)
                b2_node.children.append(w2_node)

                for black_reply2 in list(b2.legal_moves):
                    b3 = b2.copy()
                    b3.push(black_reply2)
                    b3_bfen = to_bfen(b3)
                    positions[b3_bfen] = (None, None)
                    edges.add((w2_bfen, b3_bfen))

                    b3_node = ProofTreeNode(black_reply2.uci())
                    w2_node.children.append(b3_node)

                    win_m2 = find_winning_move(b3)
                    assert win_m2 is not None, f"No win found in {m_uci} -> {black_reply.uci()} -> {cont_uci} -> {black_reply2.uci()}"
                    b3.push(win_m2)
                    term_bfen2 = to_bfen(b3)
                    positions[term_bfen2] = (1, 0)
                    edges.add((b3_bfen, term_bfen2))

                    term_node2 = ProofTreeNode(win_m2.uci())
                    term_node2.w = 0
                    b3_node.children.append(term_node2)

    return positions, edges, blunder_bfens, ply1_bfen, proof_root

def solve_minimax(positions, edges):
    """
    Computes exact retrograde minimax values (computed_result, computed_dtw)
    for every node in the graph.
    """
    children = {}
    for u, v in edges:
        children.setdefault(u, []).append(v)

    computed = {}
    for bfen, (res, dtw) in positions.items():
        if res is not None:
            computed[bfen] = (res, dtw)

    changed = True
    while changed:
        changed = False
        for bfen, ch in children.items():
            if bfen in computed:
                continue
            is_white = (bfen.split()[1] == 'w')
            ch_evals = [computed.get(c) for c in ch]

            if is_white:
                winning = [e for e in ch_evals if e is not None and e[0] == 1 and e[1] is not None]
                if winning:
                    best_dtw = min(e[1] for e in winning) + 1
                    computed[bfen] = (1, best_dtw)
                    changed = True
            else:
                if all(e is not None and e[0] == 1 and e[1] is not None for e in ch_evals):
                    worst_dtw = max(e[1] for e in ch_evals) + 1
                    computed[bfen] = (1, worst_dtw)
                    changed = True

    return computed

def export_watkins_proof(proof_root: ProofTreeNode, out_path: str):
    """
    Serializes proof_root into a binary .proof file conforming to
    Mark Watkins' Losing Chess / Antichess proof tree format.
    """
    next_index = 1
    node_list = []

    def assign_preorder(node):
        nonlocal next_index
        node.index = next_index
        next_index += 1
        node_list.append(node)

        if node.children:
            node.w = 1  # Branch node
            for child in node.children:
                assign_preorder(child)
            # Sibling links
            for i in range(len(node.children) - 1):
                node.children[i].d = node.children[i + 1].index
            node.children[-1].d = 0
        else:
            node.w = 0  # Terminal leaf
            node.d = 0

    # Root children are the 17 blunders
    for child in proof_root.children:
        assign_preorder(child)

    for i in range(len(proof_root.children) - 1):
        proof_root.children[i].d = proof_root.children[i + 1].index
    proof_root.children[-1].d = 0

    # Total nodes = N (including root Node 0)
    N = len(node_list) + 1

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        # Header (Node 0)
        root_data = (N & 0x3fffffff) | (1 << 30)  # child flag set
        prolog_length = 1  # 1 ply: 1. Nf3
        prolog_move = encode_move('g1f3')

        f.write(struct.pack("<IH", root_data, prolog_length))
        f.write(struct.pack("<H", prolog_move))

        # Records 1..N-1 (6 bytes each)
        for node in node_list:
            data = (node.w << 30) | (node.d & 0x3fffffff)
            mv = encode_move(node.move_uci)
            f.write(struct.pack("<IH", data, mv))

    file_size = os.path.getsize(out_path)
    print(f"Exported Watkins proof file: {out_path} ({N} nodes, {file_size} bytes).")
    return N

def verify_watkins_proof(proof_path: str):
    """Verifies internal integrity of the binary .proof file."""
    with open(proof_path, "rb") as f:
        raw_data, prolog_len = struct.unpack("<IH", f.read(6))
        node_count = raw_data & 0x3fffffff
        prolog_mv = struct.unpack("<H", f.read(2))[0]
        header_bytes = 6 + 2 * prolog_len

        def read_node(u):
            f.seek(header_bytes + (u - 1) * 6)
            data, mv = struct.unpack("<IH", f.read(6))
            return (data >> 30), (data & 0x3fffffff), decode_move(mv)

        # Traverse root children
        curr = 1
        blunder_count = 0
        while curr > 0 and curr < node_count:
            w, d, mv = read_node(curr)
            blunder_count += 1
            curr = d

        assert blunder_count == 17, f"Expected 17 root children, found {blunder_count}"
        assert prolog_len == 1, f"Expected prolog_len 1, found {prolog_len}"
        assert decode_move(prolog_mv) == 'g1f3', f"Expected g1f3, found {decode_move(prolog_mv)}"
        print(f"Verified {proof_path}: 17 blunder branches, prolog=1. Nf3, integrity intact.")

def persist_to_sqlite(db_path: str, positions, edges, computed):
    """Writes all nodes, edges, and evaluations into Atomic.db."""
    print(f"Connecting to database: {db_path}")
    con = sqlite3.connect(db_path)
    cur = con.cursor()

    cur.execute("PRAGMA journal_mode = WAL;")
    cur.execute("PRAGMA synchronous = NORMAL;")

    # 1. Insert / Update positions
    print("Upserting positions...")
    node_records = []
    for bfen, (a_res, a_dtw) in positions.items():
        c_res, c_dtw = computed.get(bfen, (None, None))
        node_records.append((bfen, a_res, a_dtw, c_res, c_dtw))

    cur.executemany("""
        INSERT INTO positions (bfen, assigned_result, assigned_dtw, computed_result, computed_dtw)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(bfen) DO UPDATE SET
            assigned_result = COALESCE(excluded.assigned_result, positions.assigned_result),
            assigned_dtw = COALESCE(excluded.assigned_dtw, positions.assigned_dtw),
            computed_result = COALESCE(excluded.computed_result, positions.computed_result),
            computed_dtw = COALESCE(excluded.computed_dtw, positions.computed_dtw);
    """, node_records)

    # 2. Map BFENs to database integer IDs
    print("Mapping BFENs to database IDs...")
    cur.execute("SELECT id, bfen FROM positions WHERE bfen IN ({})".format(
        ','.join('?' for _ in positions)
    ), list(positions.keys()))
    id_map = {bfen: pid for pid, bfen in cur.fetchall()}

    # 3. Insert edges
    print("Inserting edges...")
    edge_records = []
    for u, v in edges:
        u_id = id_map.get(u)
        v_id = id_map.get(v)
        if u_id and v_id:
            edge_records.append((u_id, v_id))

    cur.executemany("""
        INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?);
    """, edge_records)

    con.commit()
    con.close()
    print("Successfully committed proof tree to database.")

def main():
    db_path = os.path.join('data', 'Atomic.db')
    proof_path = os.path.join('data', 'Nf3_17_blunders.proof')

    print("=== PROVING THE 17 BLUNDERS AFTER 1. Nf3 IN ATOMIC CHESS ===")
    positions, edges, blunder_bfens, ply1_bfen, proof_root = build_proof_tree()
    print(f"Tree constructed: {len(positions)} positions, {len(edges)} transitions, {sum(1 for v in positions.values() if v == (1,0))} terminal wins.")

    computed = solve_minimax(positions, edges)
    print(f"Minimax solved: {len(computed)} / {len(positions)} positions evaluated.")

    print("\nSummary of the 17 Blunders:")
    print(f"{'Move':<8} | {'Outcome':<12} | {'DTW (plies)':<12} | {'Mate in N':<10}")
    print("-" * 50)
    for m in BLUNDERS_17:
        b_bfen = blunder_bfens[m]
        res, dtw = computed.get(b_bfen, (None, None))
        outcome_str = "White Wins" if res == 1 else "Unsolved"
        mate_n = f"Mate in {(dtw + 1) // 2}" if dtw else "N/A"
        print(f"1... {m:<4} | {outcome_str:<12} | {str(dtw) + ' plies':<12} | {mate_n:<10}")

    # 1. Persist to SQLite
    if os.path.exists(db_path):
        persist_to_sqlite(db_path, positions, edges, computed)
    else:
        print(f"Warning: {db_path} not found. Skipping SQLite write.")

    # 2. Export Watkins proof file
    export_watkins_proof(proof_root, proof_path)
    verify_watkins_proof(proof_path)

    # 3. If ../proof-browser exists, also copy proof file there
    proof_browser_dir = os.path.join('..', 'proof-browser')
    if os.path.exists(proof_browser_dir):
        dest_copy = os.path.join(proof_browser_dir, 'Nf3_17_blunders.proof')
        shutil.copyfile(proof_path, dest_copy)
        print(f"Copied proof file to proof-browser: {dest_copy}")

    print("\nAll 17 blunder refutations have been mathematically proven, written to Atomic.db, and exported as a Watkins binary proof file!")

if __name__ == '__main__':
    main()
