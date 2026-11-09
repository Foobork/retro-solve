import chess
import chess.variant
import chess.syzygy
import random
import struct
import sys

def verify_table(tb_name, num_samples=2000):
    print(f"==================================================")
    print(f"Verifying {tb_name}.atbd against Syzygy tablebases ({num_samples} samples)...")
    
    syz = chess.syzygy.open_tablebase("data/tablebases/atomic", VariantBoard=chess.variant.AtomicBoard)
    
    with open(f"data/tablebases/atomic/{tb_name}.atbd", "rb") as f:
        header = f.read(32)
        assert header[:4] == b"ATBD", "Invalid header"
        raw_data = f.read(1 << 25)
    
    # Parse table roles
    # E.g. KRvKP -> w_role = R, b_role = P
    parts = tb_name.split("v")
    left = parts[0][1:] # after K
    right = parts[1][1:] # after K
    
    is_3v1 = len(right) == 0
    
    role_map = {
        'Q': chess.QUEEN, 'R': chess.ROOK, 'B': chess.BISHOP, 'N': chess.KNIGHT, 'P': chess.PAWN
    }
    
    matches = 0
    tested = 0
    mismatches = []
    
    squares = list(range(64))
    
    random.seed(42)
    
    while tested < num_samples:
        wk = random.choice(squares)
        bk = random.choice(squares)
        if wk == bk:
            continue
        p1 = random.choice(squares)
        if p1 in (wk, bk):
            continue
        p2 = random.choice(squares)
        if p2 in (wk, bk, p1):
            continue
            
        turn_color = random.choice([chess.WHITE, chess.BLACK])
        
        # If pawn, check rank
        if is_3v1:
            r1 = role_map[left[0]]
            r2 = role_map[left[1]]
            if r1 == chess.PAWN and (chess.square_rank(p1) in (0, 7)):
                continue
            if r2 == chess.PAWN and (chess.square_rank(p2) in (0, 7)):
                continue
        else:
            w_role = role_map[left[0]]
            b_role = role_map[right[0]]
            if w_role == chess.PAWN and (chess.square_rank(p1) in (0, 7)):
                continue
            if b_role == chess.PAWN and (chess.square_rank(p2) in (0, 7)):
                continue
                
        b = chess.variant.AtomicBoard.empty()
        b.set_piece_at(wk, chess.Piece(chess.KING, chess.WHITE))
        b.set_piece_at(bk, chess.Piece(chess.KING, chess.BLACK))
        if is_3v1:
            b.set_piece_at(p1, chess.Piece(r1, chess.WHITE))
            b.set_piece_at(p2, chess.Piece(r2, chess.WHITE))
        else:
            b.set_piece_at(p1, chess.Piece(w_role, chess.WHITE))
            b.set_piece_at(p2, chess.Piece(b_role, chess.BLACK))
            
        b.turn = turn_color
        
        if not b.is_valid():
            continue
            
        # In chess/atomic, ensure player who just moved didn't leave own king in check or explode
        if b.was_into_check():
            continue
            
        idx = ((1 if turn_color == chess.BLACK else 0) << 24) | (wk << 18) | (bk << 12) | (p1 << 6) | p2
        our_dtw = struct.unpack("b", bytes([raw_data[idx]]))[0]
        
        try:
            syz_wdl = syz.probe_wdl(b)
        except Exception as e:
            continue
            
        # Convert our DTW to WDL:
        # our_dtw > 0: win (+2 in Syzygy for side to move)
        # our_dtw < 0: loss (-2 in Syzygy for side to move)
        # our_dtw == 0: draw (0 in Syzygy)
        if our_dtw > 0:
            our_wdl = 2
        elif our_dtw < 0:
            our_wdl = -2
        else:
            our_wdl = 0
            
        tested += 1
        if our_wdl == syz_wdl:
            matches += 1
        else:
            mismatches.append((b.fen(), our_dtw, our_wdl, syz_wdl))
            if len(mismatches) <= 5:
                print(f"Mismatch: fen={b.fen()}, our_dtw={our_dtw} (wdl={our_wdl}), syz_wdl={syz_wdl}")
                
    print(f"Results for {tb_name}: {matches}/{tested} matched ({(matches/tested)*100:.2f}%)")
    if mismatches:
        print(f"Total mismatches: {len(mismatches)}")
        return False
    return True

if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "KRvKP"
    verify_table(target)
