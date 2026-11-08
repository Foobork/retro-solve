use shakmaty::variant::Atomic;
use shakmaty::{
    Board, CastlingMode, Color, FromSetup, Piece, Position, Role, Setup, Square,
};
use std::env;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Instant;

pub const ILLEGAL: i8 = -128;
pub const DRAW: i8 = 0;

// 3-piece total: 524,288 entries (512 KB)
pub const THREE_PIECE_TOTAL: usize = 1 << 19;

// KQvKR total: 33,554,432 entries (32 MB)
pub const KQ_KR_TOTAL: usize = 1 << 25;

fn get_out_dir() -> PathBuf {
    let p1 = PathBuf::from("data/tablebases/atomic");
    if p1.parent().map(|p| p.exists()).unwrap_or(false) {
        return p1;
    }
    let p2 = PathBuf::from("../../data/tablebases/atomic");
    if p2.parent().map(|p| p.exists()).unwrap_or(false) {
        return p2;
    }
    PathBuf::from("data/tablebases/atomic")
}

#[inline(always)]
pub fn encode_kq_k(turn: Color, wk: Square, bk: Square, wq: Square) -> usize {
    ((turn.is_black() as usize) << 18)
        | ((wk as usize) << 12)
        | ((bk as usize) << 6)
        | (wq as usize)
}

#[inline(always)]
pub fn encode_kq_kr(turn: Color, wk: Square, bk: Square, wq: Square, br: Square) -> usize {
    ((turn.is_black() as usize) << 24)
        | ((wk as usize) << 18)
        | ((bk as usize) << 12)
        | ((wq as usize) << 6)
        | (br as usize)
}

pub fn solve_kqvk() -> Vec<i8> {
    println!("Generating Atomic DTW Tablebase for KQvK (3-piece)...");
    let t0 = Instant::now();

    let mut dtw = vec![ILLEGAL; THREE_PIECE_TOTAL];
    let mut degrees = vec![0u16; THREE_PIECE_TOTAL];
    let mut max_loss_dtw = vec![0u8; THREE_PIECE_TOTAL];
    let mut is_legal = vec![false; THREE_PIECE_TOTAL];
    let mut pred_counts = vec![0u32; THREE_PIECE_TOTAL];

    let mut buckets: Vec<Vec<(u32, bool)>> = vec![Vec::new(); 128];
    let mut valid_count = 0usize;
    let mut immediate_wins = 0usize;

    for wk_idx in 0..64 {
        let wk = Square::new(wk_idx);
        for bk_idx in 0..64 {
            if wk_idx == bk_idx { continue; }
            let bk = Square::new(bk_idx);
            for wq_idx in 0..64 {
                if wq_idx == wk_idx || wq_idx == bk_idx { continue; }
                let wq = Square::new(wq_idx);

                for &turn in &[Color::White, Color::Black] {
                    let idx = encode_kq_k(turn, wk, bk, wq);

                    let mut board = Board::empty();
                    board.set_piece_at(wk, Piece { color: Color::White, role: Role::King });
                    board.set_piece_at(bk, Piece { color: Color::Black, role: Role::King });
                    board.set_piece_at(wq, Piece { color: Color::White, role: Role::Queen });

                    let mut setup = Setup::empty();
                    setup.board = board;
                    setup.turn = turn;

                    let pos = match Atomic::from_setup(setup, CastlingMode::Standard) {
                        Ok(p) => p,
                        Err(_) => continue,
                    };

                    is_legal[idx] = true;
                    valid_count += 1;

                    if pos.is_game_over() {
                        if let Some(outcome) = pos.outcome() {
                            if let Some(winner) = outcome.winner() {
                                if winner != turn {
                                    dtw[idx] = -1; // terminal loss
                                }
                            }
                        }
                        continue;
                    }

                    let legal_moves = pos.legal_moves();
                    let mut has_imm_win = false;

                    for m in &legal_moves {
                        let next = pos.clone().play(m).expect("legal move");
                        if next.is_game_over() {
                            if let Some(outcome) = next.outcome() {
                                if outcome.winner() == Some(turn) {
                                    has_imm_win = true;
                                    break;
                                }
                            }
                        }
                    }

                    if has_imm_win {
                        dtw[idx] = 1;
                        buckets[1].push((idx as u32, true));
                        immediate_wins += 1;
                        continue;
                    }

                    for m in &legal_moves {
                        let next = pos.clone().play(m).expect("legal move");
                        let c_wk = next.board().king_of(Color::White);
                        let c_bk = next.board().king_of(Color::Black);
                        let c_wq = next.board().by_color(Color::White) & next.board().by_role(Role::Queen);

                        if let (Some(cwk), Some(cbk)) = (c_wk, c_bk) {
                            if c_wq.count() == 1 {
                                let cwq_sq = c_wq.first().unwrap();
                                let child_idx = encode_kq_k(next.turn(), cwk, cbk, cwq_sq);
                                pred_counts[child_idx] += 1;
                                degrees[idx] += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    let total_edges: usize = pred_counts.iter().map(|&c| c as usize).sum();
    let mut row_ptrs = vec![0u32; THREE_PIECE_TOTAL + 1];
    let mut running_sum = 0u32;
    for i in 0..THREE_PIECE_TOTAL {
        row_ptrs[i] = running_sum;
        running_sum += pred_counts[i];
    }
    row_ptrs[THREE_PIECE_TOTAL] = running_sum;

    let mut curr_offsets = row_ptrs.clone();
    let mut col_indices = vec![0u32; total_edges];

    for wk_idx in 0..64 {
        let wk = Square::new(wk_idx);
        for bk_idx in 0..64 {
            if wk_idx == bk_idx { continue; }
            let bk = Square::new(bk_idx);
            for wq_idx in 0..64 {
                if wq_idx == wk_idx || wq_idx == bk_idx { continue; }
                let wq = Square::new(wq_idx);

                for &turn in &[Color::White, Color::Black] {
                    let idx = encode_kq_k(turn, wk, bk, wq);
                    if !is_legal[idx] || dtw[idx] == 1 || dtw[idx] == -1 {
                        continue;
                    }

                    let mut board = Board::empty();
                    board.set_piece_at(wk, Piece { color: Color::White, role: Role::King });
                    board.set_piece_at(bk, Piece { color: Color::Black, role: Role::King });
                    board.set_piece_at(wq, Piece { color: Color::White, role: Role::Queen });

                    let mut setup = Setup::empty();
                    setup.board = board;
                    setup.turn = turn;

                    let pos = match Atomic::from_setup(setup, CastlingMode::Standard) {
                        Ok(p) => p,
                        Err(_) => continue,
                    };

                    for m in pos.legal_moves() {
                        let next = pos.clone().play(&m).expect("legal move");
                        let c_wk = next.board().king_of(Color::White);
                        let c_bk = next.board().king_of(Color::Black);
                        let c_wq = next.board().by_color(Color::White) & next.board().by_role(Role::Queen);

                        if let (Some(cwk), Some(cbk)) = (c_wk, c_bk) {
                            if c_wq.count() == 1 {
                                let cwq_sq = c_wq.first().unwrap();
                                let child_idx = encode_kq_k(next.turn(), cwk, cbk, cwq_sq);
                                let offset = curr_offsets[child_idx];
                                col_indices[offset as usize] = idx as u32;
                                curr_offsets[child_idx] += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    let mut wins_count = immediate_wins;
    let mut losses_count = 0usize;
    let mut max_dtw = 1u8;

    for dist in 1..127usize {
        while let Some((curr_idx, is_win)) = buckets[dist].pop() {
            if (dist as u8) > max_dtw {
                max_dtw = dist as u8;
            }

            let start = row_ptrs[curr_idx as usize] as usize;
            let end = row_ptrs[curr_idx as usize + 1] as usize;

            for edge_idx in start..end {
                let p_idx_u32 = col_indices[edge_idx];
                let p_idx = p_idx_u32 as usize;

                if dtw[p_idx] != ILLEGAL && dtw[p_idx] != DRAW {
                    continue;
                }

                if !is_win {
                    let win_dist = (dist + 1) as u8;
                    if win_dist <= 127 {
                        dtw[p_idx] = win_dist as i8;
                        buckets[win_dist as usize].push((p_idx_u32, true));
                        wins_count += 1;
                    }
                } else {
                    if degrees[p_idx] > 0 {
                        degrees[p_idx] -= 1;
                        let loss_cand = (dist + 1) as u8;
                        if loss_cand > max_loss_dtw[p_idx] {
                            max_loss_dtw[p_idx] = loss_cand;
                        }

                        if degrees[p_idx] == 0 {
                            let loss_dist = max_loss_dtw[p_idx];
                            if loss_dist <= 127 {
                                dtw[p_idx] = -(loss_dist as i8);
                                buckets[loss_dist as usize].push((p_idx_u32, false));
                                losses_count += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    for idx in 0..THREE_PIECE_TOTAL {
        if is_legal[idx] && dtw[idx] == ILLEGAL {
            dtw[idx] = DRAW;
        }
    }

    println!("Finished KQvK in {:?}: {} legal states, {} wins, {} losses, max DTW {}",
        t0.elapsed(), valid_count, wins_count, losses_count, max_dtw);

    let out_dir = get_out_dir();
    fs::create_dir_all(&out_dir).expect("create output directory");
    let out_path = out_dir.join("KQvK.atbd");
    let mut file = File::create(&out_path).expect("create KQvK.atbd");

    let mut header = [0u8; 32];
    header[0..4].copy_from_slice(b"ATBD");
    header[4] = 1;
    header[5] = 1; // KQvK marker
    file.write_all(&header).expect("write header");
    let byte_slice: &[u8] = unsafe {
        std::slice::from_raw_parts(dtw.as_ptr() as *const u8, dtw.len())
    };
    file.write_all(byte_slice).expect("write dtw bytes");
    dtw
}

pub fn load_or_generate_kqvk() -> Vec<i8> {
    let out_dir = get_out_dir();
    let path = out_dir.join("KQvK.atbd");
    if path.exists() {
        if let Ok(mut f) = File::open(&path) {
            let mut header = [0u8; 32];
            if f.read_exact(&mut header).is_ok() && &header[0..4] == b"ATBD" {
                let mut data = vec![0u8; THREE_PIECE_TOTAL];
                if f.read_exact(&mut data).is_ok() {
                    println!("Loaded existing KQvK.atbd ({} bytes)", data.len());
                    return unsafe { std::mem::transmute::<Vec<u8>, Vec<i8>>(data) };
                }
            }
        }
    }
    solve_kqvk()
}

pub fn solve_kqvkr() {
    let name = "KQvKR";
    println!("==================================================");
    println!("Generating Atomic DTW Tablebase for {} (4-piece 2v2) in Rust...", name);
    let t0 = Instant::now();

    let kqvk_tb = load_or_generate_kqvk();

    println!("Allocating CSR graph and retrograde arrays (32 MB direct indexing)...");
    let mut dtw = vec![ILLEGAL; KQ_KR_TOTAL];
    let mut degrees = vec![0u16; KQ_KR_TOTAL];
    let mut max_loss_dtw = vec![0u8; KQ_KR_TOTAL];
    let mut is_legal = vec![false; KQ_KR_TOTAL];
    let mut pred_counts = vec![0u32; KQ_KR_TOTAL];
    let mut can_draw = vec![false; KQ_KR_TOTAL];
    let mut external_wins = vec![255u8; KQ_KR_TOTAL];

    let mut buckets: Vec<Vec<(u32, bool)>> = vec![Vec::new(); 128];
    let mut valid_count = 0usize;
    let mut immediate_wins = 0usize;
    let mut terminal_losses = 0usize;

    println!("Step 1: Enumerating legal states and counting incoming edges...");
    let t_step1 = Instant::now();

    for wk_idx in 0..64 {
        let wk = Square::new(wk_idx);
        for bk_idx in 0..64 {
            if wk_idx == bk_idx { continue; }
            let bk = Square::new(bk_idx);

            for wq_idx in 0..64 {
                if wq_idx == wk_idx || wq_idx == bk_idx { continue; }
                let wq = Square::new(wq_idx);

                for br_idx in 0..64 {
                    if br_idx == wk_idx || br_idx == bk_idx || br_idx == wq_idx { continue; }
                    let br = Square::new(br_idx);

                    for &turn in &[Color::White, Color::Black] {
                        let idx = encode_kq_kr(turn, wk, bk, wq, br);

                        let mut board = Board::empty();
                        board.set_piece_at(wk, Piece { color: Color::White, role: Role::King });
                        board.set_piece_at(bk, Piece { color: Color::Black, role: Role::King });
                        board.set_piece_at(wq, Piece { color: Color::White, role: Role::Queen });
                        board.set_piece_at(br, Piece { color: Color::Black, role: Role::Rook });

                        let mut setup = Setup::empty();
                        setup.board = board;
                        setup.turn = turn;

                        let pos = match Atomic::from_setup(setup, CastlingMode::Standard) {
                            Ok(p) => p,
                            Err(_) => continue,
                        };

                        is_legal[idx] = true;
                        valid_count += 1;

                        if pos.is_game_over() {
                            if let Some(outcome) = pos.outcome() {
                                if let Some(winner) = outcome.winner() {
                                    if winner != turn {
                                        dtw[idx] = -1; // checkmated terminal loss
                                        terminal_losses += 1;
                                    }
                                } else {
                                    dtw[idx] = DRAW;
                                }
                            }
                            continue;
                        }

                        let legal_moves = pos.legal_moves();
                        let mut has_imm_win = false;
                        let mut best_ext_win = 255u8;
                        let mut has_draw = false;

                        for m in &legal_moves {
                            let next = pos.clone().play(m).expect("legal move play");
                            if next.is_game_over() {
                                if let Some(outcome) = next.outcome() {
                                    if outcome.winner() == Some(turn) {
                                        has_imm_win = true;
                                        break;
                                    } else if outcome.winner().is_none() {
                                        has_draw = true;
                                    }
                                }
                                continue;
                            }

                            let c_wk = next.board().king_of(Color::White);
                            let c_bk = next.board().king_of(Color::Black);
                            let c_wq = next.board().by_color(Color::White) & next.board().by_role(Role::Queen);
                            let c_br = next.board().by_color(Color::Black) & next.board().by_role(Role::Rook);

                            if let (Some(cwk), Some(cbk)) = (c_wk, c_bk) {
                                if c_wq.count() == 1 && c_br.count() == 1 {
                                    // Internal edge in KQvKR
                                    let cwq_sq = c_wq.first().unwrap();
                                    let cbr_sq = c_br.first().unwrap();
                                    let child_idx = encode_kq_kr(next.turn(), cwk, cbk, cwq_sq, cbr_sq);
                                    pred_counts[child_idx] += 1;
                                    degrees[idx] += 1;
                                } else if c_wq.count() == 1 && c_br.is_empty() {
                                    // Black Rook captured, White Queen survived -> transitions into KQvK!
                                    let cwq_sq = c_wq.first().unwrap();
                                    let kq_idx = encode_kq_k(next.turn(), cwk, cbk, cwq_sq);
                                    let val = kqvk_tb[kq_idx];
                                    if val < 0 && val != ILLEGAL {
                                        // Opponent in KQvK loses in |val| plies => Current player wins in |val| + 1!
                                        let cand_w = ((-val) as u8) + 1;
                                        if cand_w < best_ext_win {
                                            best_ext_win = cand_w;
                                        }
                                    } else if val == DRAW {
                                        has_draw = true;
                                    }
                                } else if c_wq.is_empty() && c_br.count() == 1 {
                                    // White Queen captured, Black Rook survived -> transitions into KRvK (100% draw)
                                    has_draw = true;
                                } else if c_wq.is_empty() && c_br.is_empty() {
                                    // Both pieces destroyed -> KvK (100% draw)
                                    has_draw = true;
                                }
                            }
                        }

                        if has_imm_win {
                            dtw[idx] = 1;
                            buckets[1].push((idx as u32, true));
                            immediate_wins += 1;
                            continue;
                        }

                        if best_ext_win < 255 {
                            external_wins[idx] = best_ext_win;
                            buckets[best_ext_win as usize].push((idx as u32, true));
                        }

                        if has_draw {
                            can_draw[idx] = true;
                        }
                    }
                }
            }
        }
    }

    let total_edges: usize = pred_counts.iter().map(|&c| c as usize).sum();
    println!(
        "Pass 1 completed in {:?}: {} legal states, {} total internal edges ({} imm wins, {} term losses)",
        t_step1.elapsed(),
        valid_count,
        total_edges,
        immediate_wins,
        terminal_losses
    );

    println!("Constructing CSR predecessor arrays ({} MB)...", (total_edges * 4 + KQ_KR_TOTAL * 4) / (1024 * 1024));
    let mut row_ptrs = vec![0u32; KQ_KR_TOTAL + 1];
    let mut running_sum = 0u32;
    for i in 0..KQ_KR_TOTAL {
        row_ptrs[i] = running_sum;
        running_sum += pred_counts[i];
    }
    row_ptrs[KQ_KR_TOTAL] = running_sum;

    let mut curr_offsets = row_ptrs.clone();
    let mut col_indices = vec![0u32; total_edges];

    println!("Pass 2: Populating CSR predecessor edges...");
    let t_pass2 = Instant::now();

    for wk_idx in 0..64 {
        let wk = Square::new(wk_idx);
        for bk_idx in 0..64 {
            if wk_idx == bk_idx { continue; }
            let bk = Square::new(bk_idx);

            for wq_idx in 0..64 {
                if wq_idx == wk_idx || wq_idx == bk_idx { continue; }
                let wq = Square::new(wq_idx);

                for br_idx in 0..64 {
                    if br_idx == wk_idx || br_idx == bk_idx || br_idx == wq_idx { continue; }
                    let br = Square::new(br_idx);

                    for &turn in &[Color::White, Color::Black] {
                        let idx = encode_kq_kr(turn, wk, bk, wq, br);
                        if !is_legal[idx] || dtw[idx] == 1 || dtw[idx] == -1 {
                            continue;
                        }

                        let mut board = Board::empty();
                        board.set_piece_at(wk, Piece { color: Color::White, role: Role::King });
                        board.set_piece_at(bk, Piece { color: Color::Black, role: Role::King });
                        board.set_piece_at(wq, Piece { color: Color::White, role: Role::Queen });
                        board.set_piece_at(br, Piece { color: Color::Black, role: Role::Rook });

                        let mut setup = Setup::empty();
                        setup.board = board;
                        setup.turn = turn;

                        let pos = match Atomic::from_setup(setup, CastlingMode::Standard) {
                            Ok(p) => p,
                            Err(_) => continue,
                        };

                        let legal_moves = pos.legal_moves();
                        for m in &legal_moves {
                            let next = pos.clone().play(m).expect("legal move play");
                            let c_wk = next.board().king_of(Color::White);
                            let c_bk = next.board().king_of(Color::Black);
                            let c_wq = next.board().by_color(Color::White) & next.board().by_role(Role::Queen);
                            let c_br = next.board().by_color(Color::Black) & next.board().by_role(Role::Rook);

                            if let (Some(cwk), Some(cbk)) = (c_wk, c_bk) {
                                if c_wq.count() == 1 && c_br.count() == 1 {
                                    let cwq_sq = c_wq.first().unwrap();
                                    let cbr_sq = c_br.first().unwrap();
                                    let child_idx = encode_kq_kr(next.turn(), cwk, cbk, cwq_sq, cbr_sq);

                                    let offset = curr_offsets[child_idx];
                                    col_indices[offset as usize] = idx as u32;
                                    curr_offsets[child_idx] += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    println!("CSR construction completed in {:?}", t_pass2.elapsed());

    println!("Step 2: Retrograde BFS propagation on CSR graph...");
    let t_bfs = Instant::now();

    let mut wins_count = immediate_wins;
    let mut losses_count = terminal_losses;
    let mut max_dtw = 1u8;

    for dist in 1..127usize {
        while let Some((curr_idx_u32, is_win)) = buckets[dist].pop() {
            let curr_idx = curr_idx_u32 as usize;

            if is_win {
                // If curr_idx has a faster win recorded, keep it; otherwise record dist
                if dtw[curr_idx] == ILLEGAL || dtw[curr_idx] == DRAW {
                    dtw[curr_idx] = dist as i8;
                    wins_count += 1;
                } else if dtw[curr_idx] > 0 && (dtw[curr_idx] as usize) < dist {
                    continue; // Already solved with a strictly faster win
                }
            }

            if (dist as u8) > max_dtw {
                max_dtw = dist as u8;
            }

            let start = row_ptrs[curr_idx] as usize;
            let end = row_ptrs[curr_idx + 1] as usize;

            for edge_idx in start..end {
                let p_idx_u32 = col_indices[edge_idx];
                let p_idx = p_idx_u32 as usize;

                if dtw[p_idx] != ILLEGAL && dtw[p_idx] != DRAW {
                    continue;
                }

                if !is_win {
                    // Predecessor moves into a losing state for the opponent => Predecessor WINS!
                    let win_dist = (dist + 1) as u8;
                    if win_dist <= 127 {
                        dtw[p_idx] = win_dist as i8;
                        buckets[win_dist as usize].push((p_idx_u32, true));
                        wins_count += 1;
                    }
                } else {
                    // Predecessor has a move leading to a win for the opponent
                    if degrees[p_idx] > 0 {
                        degrees[p_idx] -= 1;
                        let loss_cand = (dist + 1) as u8;
                        if loss_cand > max_loss_dtw[p_idx] {
                            max_loss_dtw[p_idx] = loss_cand;
                        }

                        // Can only be forced to lose if NO draw moves and NO external winning moves exist!
                        if degrees[p_idx] == 0 && !can_draw[p_idx] && external_wins[p_idx] == 255 {
                            let loss_dist = max_loss_dtw[p_idx];
                            if loss_dist <= 127 {
                                dtw[p_idx] = -(loss_dist as i8);
                                buckets[loss_dist as usize].push((p_idx_u32, false));
                                losses_count += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    println!("Retrograde BFS completed in {:?}", t_bfs.elapsed());

    let mut draw_count = 0usize;
    for idx in 0..KQ_KR_TOTAL {
        if is_legal[idx] {
            if dtw[idx] == ILLEGAL {
                dtw[idx] = DRAW;
                draw_count += 1;
            } else if dtw[idx] == DRAW {
                draw_count += 1;
            }
        }
    }

    let elapsed = t0.elapsed();
    println!("--------------------------------------------------");
    println!("Finished {} in {:?}", name, elapsed);
    println!("  Total legal states: {}", valid_count);
    println!("  Wins:   {} ({:.1}%)", wins_count, (wins_count as f64 / valid_count as f64) * 100.0);
    println!("  Losses: {} ({:.1}%)", losses_count, (losses_count as f64 / valid_count as f64) * 100.0);
    println!("  Draws:  {} ({:.1}%)", draw_count, (draw_count as f64 / valid_count as f64) * 100.0);
    println!("  Max DTW: {} plies ({} full moves)", max_dtw, (max_dtw + 1) / 2);

    let out_dir = get_out_dir();
    fs::create_dir_all(&out_dir).expect("create output directory");
    let out_path = out_dir.join(format!("{}.atbd", name));
    let mut file = File::create(&out_path).expect("create .atbd file");

    let mut header = [0u8; 32];
    header[0..4].copy_from_slice(b"ATBD");
    header[4] = 1; // version
    header[5] = 22; // KQvKR marker

    file.write_all(&header).expect("write header");
    let byte_slice: &[u8] = unsafe {
        std::slice::from_raw_parts(dtw.as_ptr() as *const u8, dtw.len())
    };
    file.write_all(byte_slice).expect("write dtw bytes");
    println!("Saved {} ({} bytes)", out_path.display(), header.len() + dtw.len());
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let target = args.get(1).map(|s| s.as_str()).unwrap_or("KQvKR");

    match target {
        "KQvK" => { solve_kqvk(); },
        "KQvKR" => solve_kqvkr(),
        other => eprintln!("Unknown target: {}", other),
    }
}
