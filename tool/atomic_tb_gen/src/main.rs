use rayon::prelude::*;
use shakmaty::variant::Atomic;
use shakmaty::{
    Board, CastlingMode, Color, FromSetup, Piece, Position, Rank, Role, Setup, Square,
};
use std::collections::HashMap;
use std::env;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Instant;

pub const ILLEGAL: i8 = -128;
pub const DRAW: i8 = 0;

// All 4-piece tables use 32 MB direct indexing: 2 turns * 64^4 = 33,554,432 entries
pub const TOTAL_STATES: usize = 1 << 25;
pub const CHUNK_SIZE: usize = 1 << 18; // 262,144 states per (turn, wk)
pub const NUM_CHUNKS: usize = 128;

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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndgameConfig {
    ThreeVsOne { role1: Role, role2: Role },
    TwoVsTwo { w_role: Role, b_role: Role },
}

fn char_to_role(c: char) -> Option<Role> {
    match c {
        'Q' | 'q' => Some(Role::Queen),
        'R' | 'r' => Some(Role::Rook),
        'B' | 'b' => Some(Role::Bishop),
        'N' | 'n' => Some(Role::Knight),
        'P' | 'p' => Some(Role::Pawn),
        _ => None,
    }
}

fn role_to_char(r: Role) -> char {
    match r {
        Role::Queen => 'Q',
        Role::Rook => 'R',
        Role::Bishop => 'B',
        Role::Knight => 'N',
        Role::Pawn => 'P',
        Role::King => 'K',
    }
}

pub fn parse_config(name: &str) -> Option<EndgameConfig> {
    let parts: Vec<&str> = name.split('v').collect();
    if parts.len() != 2 {
        return None;
    }
    let left = parts[0];
    let right = parts[1];

    if !left.starts_with('K') || !right.starts_with('K') {
        return None;
    }

    let left_pieces: Vec<char> = left[1..].chars().collect();
    let right_pieces: Vec<char> = right[1..].chars().collect();

    if left_pieces.len() == 2 && right_pieces.is_empty() {
        let r1 = char_to_role(left_pieces[0])?;
        let r2 = char_to_role(left_pieces[1])?;
        return Some(EndgameConfig::ThreeVsOne { role1: r1, role2: r2 });
    }

    if left_pieces.len() == 1 && right_pieces.len() == 1 {
        let w_role = char_to_role(left_pieces[0])?;
        let b_role = char_to_role(right_pieces[0])?;
        return Some(EndgameConfig::TwoVsTwo { w_role, b_role });
    }

    None
}

#[inline(always)]
pub fn encode_state(turn: Color, wk: Square, bk: Square, p1: Square, p2: Square) -> usize {
    ((turn.is_black() as usize) << 24)
        | ((wk as usize) << 18)
        | ((bk as usize) << 12)
        | ((p1 as usize) << 6)
        | (p2 as usize)
}

fn load_table_file(name: &str) -> Option<Vec<i8>> {
    let out_dir = get_out_dir();
    let path = out_dir.join(format!("{}.atbd", name));
    if !path.exists() {
        return None;
    }
    let mut file = File::open(&path).ok()?;
    let mut header = [0u8; 32];
    file.read_exact(&mut header).ok()?;
    if &header[0..4] != b"ATBD" {
        return None;
    }
    let mut buffer = vec![0u8; TOTAL_STATES];
    file.read_exact(&mut buffer).ok()?;
    Some(unsafe { std::mem::transmute::<Vec<u8>, Vec<i8>>(buffer) })
}

fn probe_promoted_state(parent_tables: &HashMap<String, Vec<i8>>, pos: &Atomic) -> i8 {
    let wk = pos.board().king_of(Color::White).unwrap();
    let bk = pos.board().king_of(Color::Black).unwrap();

    let mut w_pieces = Vec::new();
    let mut b_pieces = Vec::new();

    for sq in pos.board().by_color(Color::White) {
        if let Some(piece) = pos.board().piece_at(sq) {
            if piece.role != Role::King {
                w_pieces.push((sq, piece.role));
            }
        }
    }
    for sq in pos.board().by_color(Color::Black) {
        if let Some(piece) = pos.board().piece_at(sq) {
            if piece.role != Role::King {
                b_pieces.push((sq, piece.role));
            }
        }
    }

    let role_order = |r: Role| match r {
        Role::Queen => 4,
        Role::Rook => 3,
        Role::Bishop => 2,
        Role::Knight => 1,
        _ => 0,
    };

    // 3 vs 1
    if b_pieces.is_empty() && w_pieces.len() == 2 {
        let (s1, r1) = w_pieces[0];
        let (s2, r2) = w_pieces[1];

        if r1 == r2 {
            let name = format!("K{}{}{}vK", role_to_char(r1), role_to_char(r2), "");
            if let Some(table) = parent_tables.get(&name) {
                let idx = encode_state(pos.turn(), wk, bk, s1, s2);
                return table[idx];
            } else {
                return DRAW;
            }
        } else {
            let ((hp_sq, hp_r), (lp_sq, lp_r)) = if role_order(r1) >= role_order(r2) {
                ((s1, r1), (s2, r2))
            } else {
                ((s2, r2), (s1, r1))
            };
            let name = format!("K{}{}{}vK", role_to_char(hp_r), role_to_char(lp_r), "");
            if let Some(table) = parent_tables.get(&name) {
                let idx = encode_state(pos.turn(), wk, bk, hp_sq, lp_sq);
                return table[idx];
            } else {
                return DRAW;
            }
        }
    }

    // 2 vs 2
    if w_pieces.len() == 1 && b_pieces.len() == 1 {
        let (ws, wr) = w_pieces[0];
        let (bs, br) = b_pieces[0];

        if wr == Role::Queen {
            let name = format!("KQvK{}", role_to_char(br));
            if let Some(table) = parent_tables.get(&name) {
                let idx = encode_state(pos.turn(), wk, bk, ws, bs);
                return table[idx];
            }
        } else if br == Role::Queen {
            // Mirrored lookup
            let mir_turn = !pos.turn();
            let mir_wk = Square::new((bk as u32) ^ 56);
            let mir_bk = Square::new((wk as u32) ^ 56);
            let mir_wq = Square::new((bs as u32) ^ 56);
            let mir_br = Square::new((ws as u32) ^ 56);
            let name = format!("KQvK{}", role_to_char(wr));
            if let Some(table) = parent_tables.get(&name) {
                let idx = encode_state(mir_turn, mir_wk, mir_bk, mir_wq, mir_br);
                return table[idx];
            }
        }

        // Underpromotions (R, B, N vs non-Queen):
        // Check if opponent has an immediate win on the next move
        for opp_m in pos.legal_moves() {
            if let Ok(after_opp) = pos.clone().play(&opp_m) {
                if after_opp.is_game_over() {
                    if let Some(outcome) = after_opp.outcome() {
                        if outcome.winner() == Some(pos.turn()) {
                            return 1; // Opponent has an immediate win!
                        }
                    }
                }
            }
        }
        return DRAW;
    }

    DRAW
}

pub fn solve_table(name: &str) {
    let config = match parse_config(name) {
        Some(c) => c,
        None => {
            eprintln!("Invalid table name: {}", name);
            return;
        }
    };

    println!("==================================================");
    println!("Generating Atomic DTW Tablebase for {} (4-piece)...", name);
    let t0 = Instant::now();

    // Preload required parent tables for promotions if this table has pawns
    let mut parent_tables: HashMap<String, Vec<i8>> = HashMap::new();
    let has_pawn = match config {
        EndgameConfig::ThreeVsOne { role1, role2 } => role1 == Role::Pawn || role2 == Role::Pawn,
        EndgameConfig::TwoVsTwo { w_role, b_role } => w_role == Role::Pawn || b_role == Role::Pawn,
    };

    if has_pawn {
        println!("Preloading parent tablebases for pawn promotions...");
        let needed_names = match config {
            EndgameConfig::ThreeVsOne { role1, role2 } => {
                if role1 == Role::Pawn && role2 == Role::Pawn {
                    vec!["KQPvK"]
                } else {
                    vec!["KQQvK", "KQRvK", "KQBvK", "KQNvK", "KRRvK", "KRBvK", "KRNvK"]
                }
            }
            EndgameConfig::TwoVsTwo { w_role, b_role } => {
                if w_role == Role::Pawn && b_role == Role::Pawn {
                    vec!["KQvKP"]
                } else {
                    vec!["KQvKQ", "KQvKR", "KQvKB", "KQvKN"]
                }
            }
        };

        for t_name in needed_names {
            if let Some(tb) = load_table_file(t_name) {
                println!("  Loaded parent {}.atbd", t_name);
                parent_tables.insert(t_name.to_string(), tb);
            } else {
                eprintln!("  WARNING: parent {}.atbd not found on disk!", t_name);
            }
        }
    }

    println!("Allocating CSR graph and retrograde arrays (32 MB direct indexing)...");
    let mut dtw = vec![ILLEGAL; TOTAL_STATES];
    let mut degrees = vec![0u16; TOTAL_STATES];
    let mut max_loss_dtw = vec![0u8; TOTAL_STATES];
    let mut is_legal = vec![false; TOTAL_STATES];
    let mut can_draw = vec![false; TOTAL_STATES];
    let mut external_wins = vec![255u8; TOTAL_STATES];

    let pred_counts: Vec<AtomicU32> = (0..TOTAL_STATES).map(|_| AtomicU32::new(0)).collect();

    println!("Step 1: Enumerating legal states and counting incoming edges (parallel across {} chunks)...", NUM_CHUNKS);
    let t_step1 = Instant::now();

    let dtw_chunks: Vec<&mut [i8]> = dtw.chunks_exact_mut(CHUNK_SIZE).collect();
    let degrees_chunks: Vec<&mut [u16]> = degrees.chunks_exact_mut(CHUNK_SIZE).collect();
    let is_legal_chunks: Vec<&mut [bool]> = is_legal.chunks_exact_mut(CHUNK_SIZE).collect();
    let can_draw_chunks: Vec<&mut [bool]> = can_draw.chunks_exact_mut(CHUNK_SIZE).collect();
    let ext_wins_chunks: Vec<&mut [u8]> = external_wins.chunks_exact_mut(CHUNK_SIZE).collect();

    let chunk_data: Vec<_> = dtw_chunks
        .into_iter()
        .zip(degrees_chunks)
        .zip(is_legal_chunks)
        .zip(can_draw_chunks)
        .zip(ext_wins_chunks)
        .enumerate()
        .collect();

    let parent_tables_ref = &parent_tables;

    let local_results: Vec<(Vec<u32>, Vec<(u32, u8)>, usize, usize, usize)> = chunk_data
        .into_par_iter()
        .map(|(chunk_id, ((((c_dtw, c_degrees), c_is_legal), c_can_draw), c_ext_wins))| {
            let turn = if chunk_id < 64 { Color::White } else { Color::Black };
            let wk = Square::new((chunk_id % 64) as u32);
            let wk_idx = wk as usize;

            let mut imm_wins_vec = Vec::new();
            let mut ext_wins_vec = Vec::new();
            let mut v_count = 0usize;
            let mut imm_wins = 0usize;
            let mut term_losses = 0usize;

            for bk_idx in 0..64 {
                if wk_idx == bk_idx { continue; }
                let bk = Square::new(bk_idx as u32);

                for p1_idx in 0..64 {
                    if p1_idx == wk_idx || p1_idx == bk_idx { continue; }
                    let p1 = Square::new(p1_idx as u32);

                    for p2_idx in 0..64 {
                        if p2_idx == wk_idx || p2_idx == bk_idx || p2_idx == p1_idx { continue; }
                        let p2 = Square::new(p2_idx as u32);

                        // Validate pawn square ranks (ranks 2 to 7)
                        match config {
                            EndgameConfig::ThreeVsOne { role1, role2 } => {
                                if role1 == Role::Pawn && (p1.rank() == Rank::First || p1.rank() == Rank::Eighth) { continue; }
                                if role2 == Role::Pawn && (p2.rank() == Rank::First || p2.rank() == Rank::Eighth) { continue; }
                            }
                            EndgameConfig::TwoVsTwo { w_role, b_role } => {
                                if w_role == Role::Pawn && (p1.rank() == Rank::First || p1.rank() == Rank::Eighth) { continue; }
                                if b_role == Role::Pawn && (p2.rank() == Rank::First || p2.rank() == Rank::Eighth) { continue; }
                            }
                        }

                        let local_idx = (bk_idx << 12) | (p1_idx << 6) | p2_idx;
                        let global_idx = (chunk_id << 18) | local_idx;

                        let mut board = Board::empty();
                        board.set_piece_at(wk, Piece { color: Color::White, role: Role::King });
                        board.set_piece_at(bk, Piece { color: Color::Black, role: Role::King });

                        match config {
                            EndgameConfig::ThreeVsOne { role1, role2 } => {
                                board.set_piece_at(p1, Piece { color: Color::White, role: role1 });
                                board.set_piece_at(p2, Piece { color: Color::White, role: role2 });
                            }
                            EndgameConfig::TwoVsTwo { w_role, b_role } => {
                                board.set_piece_at(p1, Piece { color: Color::White, role: w_role });
                                board.set_piece_at(p2, Piece { color: Color::Black, role: b_role });
                            }
                        }

                        let mut setup = Setup::empty();
                        setup.board = board;
                        setup.turn = turn;

                        let pos = match Atomic::from_setup(setup, CastlingMode::Standard) {
                            Ok(p) => p,
                            Err(_) => continue,
                        };

                        c_is_legal[local_idx] = true;
                        v_count += 1;

                        if pos.is_game_over() {
                            if let Some(outcome) = pos.outcome() {
                                if let Some(winner) = outcome.winner() {
                                    if winner != turn {
                                        c_dtw[local_idx] = -1; // checkmate
                                        term_losses += 1;
                                    }
                                } else {
                                    c_dtw[local_idx] = DRAW;
                                }
                            }
                            continue;
                        }

                        let legal_moves = pos.legal_moves();

                        // 1. Check for immediate win FIRST before counting any edges
                        let mut has_imm_win = false;
                        for m in &legal_moves {
                            if let Ok(next) = pos.clone().play(m) {
                                if next.is_game_over() {
                                    if let Some(outcome) = next.outcome() {
                                        if outcome.winner() == Some(turn) {
                                            has_imm_win = true;
                                            break;
                                        }
                                    }
                                }
                            }
                        }

                        if has_imm_win {
                            c_dtw[local_idx] = 1;
                            imm_wins_vec.push(global_idx as u32);
                            imm_wins += 1;
                            continue;
                        }

                        // 2. Count internal edges and external win/draw moves
                        let mut has_draw = false;
                        let mut best_ext_win = 255u8;

                        for m in &legal_moves {
                            let next = pos.clone().play(m).expect("legal move");
                            if next.is_game_over() {
                                if let Some(outcome) = next.outcome() {
                                    if outcome.winner().is_none() {
                                        has_draw = true;
                                    }
                                }
                                continue;
                            }

                            // If this was a pawn promotion, lookup in parent tables
                            if m.promotion().is_some() {
                                if m.promotion() != Some(Role::Queen) {
                                    continue;
                                }
                                let val = probe_promoted_state(parent_tables_ref, &next);
                                if val < 0 && val != ILLEGAL {
                                    let cand_w = ((-val) as u8) + 1;
                                    if cand_w < best_ext_win {
                                        best_ext_win = cand_w;
                                    }
                                } else if val == DRAW {
                                    has_draw = true;
                                }
                                continue;
                            }

                            let c_wk = next.board().king_of(Color::White);
                            let c_bk = next.board().king_of(Color::Black);

                            match config {
                                EndgameConfig::ThreeVsOne { role1, role2 } => {
                                    let mut p1_found = None;
                                    let mut p2_found = None;

                                    if role1 == role2 {
                                        let pieces = next.board().by_color(Color::White) & next.board().by_role(role1);
                                        if pieces.count() == 2 {
                                            let mut iter = pieces.into_iter();
                                            p1_found = iter.next();
                                            p2_found = iter.next();
                                        }
                                    } else {
                                        let pieces1 = next.board().by_color(Color::White) & next.board().by_role(role1);
                                        let pieces2 = next.board().by_color(Color::White) & next.board().by_role(role2);
                                        if pieces1.count() == 1 && pieces2.count() == 1 {
                                            p1_found = pieces1.first();
                                            p2_found = pieces2.first();
                                        }
                                    }

                                    if let (Some(cwk), Some(cbk), Some(cp1), Some(cp2)) = (c_wk, c_bk, p1_found, p2_found) {
                                        let child_idx = encode_state(next.turn(), cwk, cbk, cp1, cp2);
                                        pred_counts[child_idx].fetch_add(1, Ordering::Relaxed);
                                        c_degrees[local_idx] += 1;
                                    }
                                }
                                EndgameConfig::TwoVsTwo { w_role, b_role } => {
                                    let c_w = next.board().by_color(Color::White) & next.board().by_role(w_role);
                                    let c_b = next.board().by_color(Color::Black) & next.board().by_role(b_role);

                                    if let (Some(cwk), Some(cbk)) = (c_wk, c_bk) {
                                        if c_w.count() == 1 && c_b.count() == 1 {
                                            let cp1 = c_w.first().unwrap();
                                            let cp2 = c_b.first().unwrap();
                                            let child_idx = encode_state(next.turn(), cwk, cbk, cp1, cp2);
                                            pred_counts[child_idx].fetch_add(1, Ordering::Relaxed);
                                            c_degrees[local_idx] += 1;
                                        } else if c_w.is_empty() && c_b.is_empty() {
                                            has_draw = true;
                                        }
                                    }
                                }
                            }
                        }

                        if best_ext_win < 255 {
                            c_ext_wins[local_idx] = best_ext_win;
                            ext_wins_vec.push((global_idx as u32, best_ext_win));
                        }

                        if has_draw {
                            c_can_draw[local_idx] = true;
                        }
                    }
                }
            }

            (imm_wins_vec, ext_wins_vec, v_count, imm_wins, term_losses)
        })
        .collect();

    let mut buckets: Vec<Vec<(u32, bool)>> = vec![Vec::new(); 128];
    let mut valid_count = 0usize;
    let mut immediate_wins = 0usize;
    let mut terminal_losses = 0usize;

    for (imm_vec, ext_vec, vc, iw, tl) in local_results {
        for idx in imm_vec {
            buckets[1].push((idx, true));
        }
        for (idx, win_dist) in ext_vec {
            buckets[win_dist as usize].push((idx, true));
        }
        valid_count += vc;
        immediate_wins += iw;
        terminal_losses += tl;
    }

    let total_edges: usize = pred_counts.iter().map(|c| c.load(Ordering::Relaxed) as usize).sum();
    println!(
        "Pass 1 completed in {:?}: {} legal states, {} internal edges ({} imm wins, {} term losses)",
        t_step1.elapsed(),
        valid_count,
        total_edges,
        immediate_wins,
        terminal_losses
    );

    println!("Constructing CSR predecessor arrays ({} MB)...", (total_edges * 4 + TOTAL_STATES * 4) / (1024 * 1024));
    let mut row_ptrs = vec![0u32; TOTAL_STATES + 1];
    let mut running_sum = 0u32;
    for i in 0..TOTAL_STATES {
        row_ptrs[i] = running_sum;
        running_sum += pred_counts[i].load(Ordering::Relaxed);
    }
    row_ptrs[TOTAL_STATES] = running_sum;

    let curr_offsets: Vec<AtomicU32> = row_ptrs[0..TOTAL_STATES].iter().map(|&p| AtomicU32::new(p)).collect();
    let col_indices_atomic: Vec<AtomicU32> = (0..total_edges).map(|_| AtomicU32::new(0)).collect();

    println!("Pass 2: Populating CSR predecessor edges (parallel across {} chunks)...", NUM_CHUNKS);
    let t_pass2 = Instant::now();

    let is_legal_ref = &is_legal;
    let dtw_ref = &dtw;
    let curr_offsets_ref = &curr_offsets;
    let col_indices_ref = &col_indices_atomic;

    (0..NUM_CHUNKS).into_par_iter().for_each(|chunk_id| {
        let turn = if chunk_id < 64 { Color::White } else { Color::Black };
        let wk = Square::new((chunk_id % 64) as u32);
        let wk_idx = wk as usize;

        for bk_idx in 0..64 {
            if wk_idx == bk_idx { continue; }
            let bk = Square::new(bk_idx as u32);

            for p1_idx in 0..64 {
                if p1_idx == wk_idx || p1_idx == bk_idx { continue; }
                let p1 = Square::new(p1_idx as u32);

                for p2_idx in 0..64 {
                    if p2_idx == wk_idx || p2_idx == bk_idx || p2_idx == p1_idx { continue; }
                    let p2 = Square::new(p2_idx as u32);

                    let global_idx = (chunk_id << 18) | (bk_idx << 12) | (p1_idx << 6) | p2_idx;
                    if !is_legal_ref[global_idx] || dtw_ref[global_idx] == 1 || dtw_ref[global_idx] == -1 {
                        continue;
                    }

                    let mut board = Board::empty();
                    board.set_piece_at(wk, Piece { color: Color::White, role: Role::King });
                    board.set_piece_at(bk, Piece { color: Color::Black, role: Role::King });

                    match config {
                        EndgameConfig::ThreeVsOne { role1, role2 } => {
                            board.set_piece_at(p1, Piece { color: Color::White, role: role1 });
                            board.set_piece_at(p2, Piece { color: Color::White, role: role2 });
                        }
                        EndgameConfig::TwoVsTwo { w_role, b_role } => {
                            board.set_piece_at(p1, Piece { color: Color::White, role: w_role });
                            board.set_piece_at(p2, Piece { color: Color::Black, role: b_role });
                        }
                    }

                    let mut setup = Setup::empty();
                    setup.board = board;
                    setup.turn = turn;

                    let pos = match Atomic::from_setup(setup, CastlingMode::Standard) {
                        Ok(p) => p,
                        Err(_) => continue,
                    };

                    for m in pos.legal_moves() {
                        let next = match pos.clone().play(&m) {
                            Ok(n) => n,
                            Err(_) => continue,
                        };
                        if next.is_game_over() {
                            continue;
                        }
                        if m.promotion().is_some() {
                            continue;
                        }
                        let c_wk = next.board().king_of(Color::White);
                        let c_bk = next.board().king_of(Color::Black);

                        match config {
                            EndgameConfig::ThreeVsOne { role1, role2 } => {
                                let mut p1_found = None;
                                let mut p2_found = None;

                                if role1 == role2 {
                                    let pieces = next.board().by_color(Color::White) & next.board().by_role(role1);
                                    if pieces.count() == 2 {
                                        let mut iter = pieces.into_iter();
                                        p1_found = iter.next();
                                        p2_found = iter.next();
                                    }
                                } else {
                                    let pieces1 = next.board().by_color(Color::White) & next.board().by_role(role1);
                                    let pieces2 = next.board().by_color(Color::White) & next.board().by_role(role2);
                                    if pieces1.count() == 1 && pieces2.count() == 1 {
                                        p1_found = pieces1.first();
                                        p2_found = pieces2.first();
                                    }
                                }

                                if let (Some(cwk), Some(cbk), Some(cp1), Some(cp2)) = (c_wk, c_bk, p1_found, p2_found) {
                                    let child_idx = encode_state(next.turn(), cwk, cbk, cp1, cp2);
                                    let offset = curr_offsets_ref[child_idx].fetch_add(1, Ordering::Relaxed);
                                    col_indices_ref[offset as usize].store(global_idx as u32, Ordering::Relaxed);
                                }
                            }
                            EndgameConfig::TwoVsTwo { w_role, b_role } => {
                                let c_w = next.board().by_color(Color::White) & next.board().by_role(w_role);
                                let c_b = next.board().by_color(Color::Black) & next.board().by_role(b_role);

                                if let (Some(cwk), Some(cbk)) = (c_wk, c_bk) {
                                    if c_w.count() == 1 && c_b.count() == 1 {
                                        let cp1 = c_w.first().unwrap();
                                        let cp2 = c_b.first().unwrap();
                                        let child_idx = encode_state(next.turn(), cwk, cbk, cp1, cp2);
                                        let offset = curr_offsets_ref[child_idx].fetch_add(1, Ordering::Relaxed);
                                        col_indices_ref[offset as usize].store(global_idx as u32, Ordering::Relaxed);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    });

    println!("CSR construction completed in {:?}", t_pass2.elapsed());

    // Verify CSR integrity: exact offset match across all states
    for i in 0..TOTAL_STATES {
        let expected = row_ptrs[i + 1];
        let actual = curr_offsets[i].load(Ordering::Relaxed);
        assert_eq!(
            expected, actual,
            "CSR offset mismatch at state {}: expected {}, got {}",
            i, expected, actual
        );
    }
    println!("CSR integrity verified: all {} edges perfectly mapped.", total_edges);

    let col_indices: Vec<u32> = col_indices_atomic.into_iter().map(|a| a.load(Ordering::Relaxed)).collect();

    println!("Step 2: Retrograde BFS propagation on CSR graph...");
    let t_bfs = Instant::now();

    let mut wins_count = immediate_wins;
    let mut losses_count = terminal_losses;
    let mut max_dtw = 1u8;
    let mut visited = vec![false; TOTAL_STATES];

    for dist in 1..127usize {
        while let Some((curr_idx_u32, is_win)) = buckets[dist].pop() {
            let curr_idx = curr_idx_u32 as usize;

            if visited[curr_idx] {
                continue;
            }
            visited[curr_idx] = true;

            if is_win {
                if dtw[curr_idx] == ILLEGAL || dtw[curr_idx] == DRAW {
                    dtw[curr_idx] = dist as i8;
                    wins_count += 1;
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
    for idx in 0..TOTAL_STATES {
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
    header[5] = 4; // 4-piece marker

    file.write_all(&header).expect("write header");
    let byte_slice: &[u8] = unsafe {
        std::slice::from_raw_parts(dtw.as_ptr() as *const u8, dtw.len())
    };
    file.write_all(byte_slice).expect("write dtw bytes");
    println!("Saved {} ({} bytes)", out_path.display(), header.len() + dtw.len());
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let target = args.get(1).map(|s| s.as_str()).unwrap_or("KQPvK");

    solve_table(target);
}
