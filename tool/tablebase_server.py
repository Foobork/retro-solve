#!/usr/bin/env python3
"""
Local Syzygy and Antichess Tablebase HTTP Sidecar Server for RetroSolve.

Provides a fast, local REST API compatible with the Lichess Tablebase API:
    GET /atomic?fen=<FEN>
    GET /antichess?fen=<FEN>
    GET /health

Uses:
- python-chess with AtomicBoard and Syzygy tablebases (3-4-5 pieces) located in data/tablebases/atomic.
- antichess_tb_api.dll with .an0 tablebases (2-3-4 pieces) located in data/tablebases/antichess.
"""

import argparse
import ctypes
import json
import logging
import os
import sys
import urllib.parse
from http.server import HTTPServer, ThreadingHTTPServer, BaseHTTPRequestHandler
from typing import Optional, Dict, Any, List

import chess
import chess.variant
import chess.syzygy

logger = logging.getLogger("tablebase_server")

CATEGORY_MAP = {
    2: "win",
    1: "win",
    0: "draw",
    -1: "loss",
    -2: "loss",
}

PIECE_TYPE_MAP = {
    chess.PAWN: 1,
    chess.KNIGHT: 2,
    chess.BISHOP: 3,
    chess.ROOK: 4,
    chess.QUEEN: 5,
    chess.KING: 6,
}


class AtomicTablebaseEngine:
    def __init__(self, tablebase_dir: str):
        self.tablebase_dir = tablebase_dir
        self.tb = chess.syzygy.Tablebase(VariantBoard=chess.variant.AtomicBoard)
        if os.path.exists(tablebase_dir):
            count = self.tb.add_directory(tablebase_dir)
            logger.info("Loaded %d Atomic tablebase files from %s", count, tablebase_dir)
        else:
            logger.warning("Atomic tablebase directory not found: %s", tablebase_dir)

    def is_supported(self, board: chess.variant.AtomicBoard) -> bool:
        piece_count = len(board.piece_map())
        return piece_count <= 5

    def probe(self, fen: str) -> Dict[str, Any]:
        clean_fen = fen.replace("_", " ").strip()
        tokens = clean_fen.split()
        if len(tokens) < 2:
            raise ValueError(f"Invalid FEN: {fen}")

        try:
            board = chess.variant.AtomicBoard(clean_fen)
        except Exception as e:
            raise ValueError(f"Could not parse atomic FEN: {e}")

        if not self.is_supported(board):
            return {
                "error": "Atomic tablebase only supports positions with 5 or fewer pieces",
                "category": "unknown",
                "moves": [],
            }

        if board.is_game_over():
            outcome = board.outcome()
            is_draw = outcome is None or outcome.winner is None
            is_win = False if is_draw else outcome.winner == board.turn
            is_loss = False if is_draw else outcome.winner != board.turn
            is_checkmate = outcome.termination == chess.Termination.CHECKMATE if outcome else False
            is_variant_win = outcome.termination == chess.Termination.VARIANT_LOSS and is_win if outcome else False
            is_variant_loss = outcome.termination == chess.Termination.VARIANT_LOSS and is_loss if outcome else False

            category = "draw" if is_draw else ("win" if is_win else "loss")
            return {
                "category": category,
                "dtz": 0,
                "precise_dtz": 0,
                "dtm": 0 if not is_draw else None,
                "dtw": 0 if not is_draw else None,
                "checkmate": is_checkmate,
                "stalemate": outcome.termination == chess.Termination.STALEMATE if outcome else False,
                "variant_win": is_variant_win,
                "variant_loss": is_variant_loss,
                "insufficient_material": outcome.termination == chess.Termination.INSUFFICIENT_MATERIAL if outcome else False,
                "moves": [],
            }

        try:
            wdl = self.tb.probe_wdl(board)
            dtz = self.tb.probe_dtz(board)
        except Exception as e:
            return {
                "error": f"Syzygy probe failed: {e}",
                "category": "unknown",
                "moves": [],
            }

        pos_cat = CATEGORY_MAP.get(wdl, "unknown")
        moves_data = []

        for move in board.legal_moves:
            uci = move.uci()
            san = board.san(move)
            zeroing = board.is_zeroing(move)

            board.push(move)
            if board.is_game_over():
                outcome = board.outcome()
                is_draw = outcome is None or outcome.winner is None
                prev_won = False if is_draw else outcome.winner == (not board.turn)
                is_cm = outcome.termination == chess.Termination.CHECKMATE if outcome else False
                is_vw = outcome.termination == chess.Termination.VARIANT_LOSS and prev_won if outcome else False
                is_vl = outcome.termination == chess.Termination.VARIANT_LOSS and not prev_won if outcome else False

                move_cat = "draw" if is_draw else ("loss" if prev_won else "win")
                moves_data.append({
                    "uci": uci,
                    "san": san,
                    "category": move_cat,
                    "dtz": 0,
                    "precise_dtz": 0,
                    "dtm": -1 if prev_won else (1 if not is_draw else None),
                    "dtw": -1 if prev_won else (1 if not is_draw else None),
                    "checkmate": is_cm,
                    "stalemate": outcome.termination == chess.Termination.STALEMATE if outcome else False,
                    "variant_win": is_vw,
                    "variant_loss": is_vl,
                    "zeroing": True,
                })
            else:
                try:
                    m_wdl = self.tb.probe_wdl(board)
                    m_dtz = self.tb.probe_dtz(board)
                    m_cat = CATEGORY_MAP.get(m_wdl, "unknown")

                    moves_data.append({
                        "uci": uci,
                        "san": san,
                        "category": m_cat,
                        "dtz": m_dtz,
                        "precise_dtz": m_dtz,
                        "dtm": None,
                        "dtw": None,
                        "checkmate": False,
                        "stalemate": False,
                        "variant_win": False,
                        "variant_loss": False,
                        "zeroing": zeroing,
                    })
                except Exception:
                    moves_data.append({
                        "uci": uci,
                        "san": san,
                        "category": "unknown",
                        "dtz": None,
                        "precise_dtz": None,
                        "dtm": None,
                        "dtw": None,
                        "checkmate": False,
                        "stalemate": False,
                        "variant_win": False,
                        "variant_loss": False,
                        "zeroing": zeroing,
                    })
            board.pop()

        def sort_key(item):
            cat = item.get("category")
            dtz = item.get("dtz") or 0
            if cat == "loss":
                return (0, abs(dtz))
            elif cat == "draw":
                return (1, 0)
            elif cat == "win":
                return (2, -abs(dtz))
            return (3, 0)

        moves_data.sort(key=sort_key)

        return {
            "checkmate": False,
            "stalemate": False,
            "variant_win": False,
            "variant_loss": False,
            "insufficient_material": False,
            "dtz": dtz,
            "precise_dtz": dtz,
            "dtm": None,
            "dtw": None,
            "category": pos_cat,
            "moves": moves_data,
        }


class AntichessTablebaseEngine:
    def __init__(self, tablebase_dir: str):
        self.tablebase_dir = tablebase_dir
        self.dll = None
        dll_path = os.path.join(tablebase_dir, "antichess_tb_api.dll")
        if not os.path.exists(dll_path):
            logger.warning("Antichess DLL not found at %s", dll_path)
            return

        try:
            self.dll = ctypes.CDLL(os.path.abspath(dll_path))
            self.dll.antichess_tb_init.restype = ctypes.c_int32
            self.dll.antichess_tb_init.argtypes = []

            self.dll.antichess_tb_add_path.restype = ctypes.c_int32
            self.dll.antichess_tb_add_path.argtypes = [ctypes.c_char_p, ctypes.c_size_t]

            self.dll.antichess_tb_probe_dtw.restype = ctypes.c_int32
            self.dll.antichess_tb_probe_dtw.argtypes = [
                ctypes.POINTER(ctypes.c_int32),
                ctypes.POINTER(ctypes.c_int32),
                ctypes.c_size_t,
                ctypes.POINTER(ctypes.c_int32),
                ctypes.POINTER(ctypes.c_int32),
                ctypes.c_size_t,
                ctypes.c_int32,
                ctypes.c_int32,
                ctypes.POINTER(ctypes.c_int32),
            ]

            init_res = self.dll.antichess_tb_init()
            if init_res != 0:
                logger.error("antichess_tb_init() failed with code %d", init_res)
                self.dll = None
                return

            abs_tb_dir = os.path.abspath(tablebase_dir).encode("utf-8")
            add_res = self.dll.antichess_tb_add_path(abs_tb_dir, len(abs_tb_dir))
            logger.info("Loaded Antichess tablebases from %s (res: %d)", tablebase_dir, add_res)
        except Exception as e:
            logger.exception("Failed to load Antichess tablebase library: %s", e)
            self.dll = None

    def is_available(self) -> bool:
        return self.dll is not None

    def _probe_single(self, board: chess.variant.AntichessBoard) -> Optional[Dict[str, Any]]:
        if not self.dll:
            return None

        # Check terminal conditions
        num_w_pieces = len(board.pieces(chess.PAWN, chess.WHITE) |
                           board.pieces(chess.KNIGHT, chess.WHITE) |
                           board.pieces(chess.BISHOP, chess.WHITE) |
                           board.pieces(chess.ROOK, chess.WHITE) |
                           board.pieces(chess.QUEEN, chess.WHITE) |
                           board.pieces(chess.KING, chess.WHITE))

        num_b_pieces = len(board.pieces(chess.PAWN, chess.BLACK) |
                           board.pieces(chess.KNIGHT, chess.BLACK) |
                           board.pieces(chess.BISHOP, chess.BLACK) |
                           board.pieces(chess.ROOK, chess.BLACK) |
                           board.pieces(chess.QUEEN, chess.BLACK) |
                           board.pieces(chess.KING, chess.BLACK))

        # Antichess win: side with 0 pieces wins, or side to move stalemated wins
        if num_w_pieces == 0:
            winner = chess.WHITE
            stm_won = (board.turn == winner)
            return {"category": "win" if stm_won else "loss", "dtw": 0, "cursed": False}
        if num_b_pieces == 0:
            winner = chess.BLACK
            stm_won = (board.turn == winner)
            return {"category": "win" if stm_won else "loss", "dtw": 0, "cursed": False}

        legal_moves = list(board.legal_moves)
        if len(legal_moves) == 0:
            # Stalemated side wins
            return {"category": "win", "dtw": 0, "cursed": False}

        total = num_w_pieces + num_b_pieces
        if total > 4 or num_w_pieces < 1 or num_b_pieces < 1:
            return None

        w_sq = (ctypes.c_int32 * 64)()
        w_pc = (ctypes.c_int32 * 64)()
        b_sq = (ctypes.c_int32 * 64)()
        b_pc = (ctypes.c_int32 * 64)()
        w_idx = 0
        b_idx = 0

        for sq, piece in board.piece_map().items():
            pt = PIECE_TYPE_MAP[piece.piece_type]
            if piece.color == chess.WHITE:
                w_sq[w_idx] = sq
                w_pc[w_idx] = pt
                w_idx += 1
            else:
                b_sq[b_idx] = sq
                b_pc[b_idx] = pt
                b_idx += 1

        stm = 0 if board.turn == chess.WHITE else 1
        ep = board.ep_square if board.ep_square is not None else -1
        dtw_out = ctypes.c_int32(0)

        code = self.dll.antichess_tb_probe_dtw(
            w_sq, w_pc, w_idx,
            b_sq, b_pc, b_idx,
            stm, ep, ctypes.byref(dtw_out),
        )

        if code < 0:
            return None
        if code == 2:
            return {"category": "draw", "dtw": None, "cursed": False}

        raw_dtw = dtw_out.value
        stm_wins = raw_dtw >= 0
        return {
            "category": "win" if stm_wins else "loss",
            "dtw": abs(raw_dtw),
            "cursed": code == 1,
        }

    def probe(self, fen: str) -> Dict[str, Any]:
        clean_fen = fen.replace("_", " ").strip()
        tokens = clean_fen.split()
        if len(tokens) < 2:
            raise ValueError(f"Invalid FEN: {fen}")

        try:
            board = chess.variant.AntichessBoard(clean_fen)
        except Exception as e:
            raise ValueError(f"Could not parse antichess FEN: {e}")

        piece_count = len(board.piece_map())
        if piece_count > 4:
            return {
                "error": "Local Antichess tablebase only supports 4 or fewer pieces",
                "category": "unknown",
                "moves": [],
            }

        root = self._probe_single(board)
        if not root:
            return {
                "error": "Antichess tablebase lookup failed",
                "category": "unknown",
                "moves": [],
            }

        moves_data = []
        for move in board.legal_moves:
            uci = move.uci()
            san = board.san(move)
            board.push(move)

            child = self._probe_single(board)
            if child:
                opp_cat = child["category"]
                opp_dtw = child["dtw"]
                signed_dtw = -opp_dtw if opp_cat == "loss" else (opp_dtw if opp_cat == "win" else None)
                moves_data.append({
                    "uci": uci,
                    "san": san,
                    "category": opp_cat,
                    "dtz": signed_dtw,
                    "dtm": signed_dtw,
                    "dtw": signed_dtw,
                    "checkmate": False,
                    "stalemate": False,
                    "variant_win": False,
                    "variant_loss": False,
                })
            else:
                moves_data.append({
                    "uci": uci,
                    "san": san,
                    "category": "unknown",
                    "dtz": None,
                    "dtm": None,
                    "dtw": None,
                    "checkmate": False,
                    "stalemate": False,
                    "variant_win": False,
                    "variant_loss": False,
                })
            board.pop()

        def sort_key(item):
            cat = item.get("category")
            dtw = item.get("dtw") or 9999
            if cat == "loss":
                return (0, abs(dtw))
            elif cat == "draw":
                return (1, 0)
            elif cat == "win":
                return (2, -abs(dtw))
            return (3, 0)

        moves_data.sort(key=sort_key)

        return {
            "checkmate": False,
            "stalemate": False,
            "variant_win": False,
            "variant_loss": False,
            "insufficient_material": False,
            "dtz": root["dtw"],
            "precise_dtz": root["dtw"],
            "dtm": root["dtw"],
            "dtw": root["dtw"],
            "category": root["category"],
            "moves": moves_data,
        }


class TablebaseRequestHandler(BaseHTTPRequestHandler):
    atomic_engine: Optional[AtomicTablebaseEngine] = None
    antichess_engine: Optional[AntichessTablebaseEngine] = None

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/health" or path == "/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            resp = {
                "status": "ok",
                "variants": {
                    "atomic": self.atomic_engine.tablebase_dir if self.atomic_engine else None,
                    "antichess": self.antichess_engine.tablebase_dir if self.antichess_engine and self.antichess_engine.is_available() else None,
                },
            }
            self.wfile.write(json.dumps(resp).encode("utf-8"))
            return

        engine = None
        if path == "/atomic":
            engine = self.atomic_engine
        elif path == "/antichess":
            engine = self.antichess_engine

        if engine is not None:
            qs = urllib.parse.parse_qs(parsed.query)
            fen = qs.get("fen", [None])[0]
            if not fen:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing fen query parameter"}).encode("utf-8"))
                return

            try:
                result = engine.probe(fen)
                status_code = 404 if "error" in result and result.get("category") == "unknown" else 200
                logger.info("[%s] probe: %s -> %s (status: %d)", path.strip("/"), fen, result.get("category"), status_code)
                self.send_response(status_code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(json.dumps(result).encode("utf-8"))
            except ValueError as e:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode("utf-8"))
            except Exception as e:
                logger.exception("Internal error processing request")
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode("utf-8"))
            return

        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps({"error": f"Endpoint not found: {path}"}).encode("utf-8"))

    def log_message(self, format, *args):
        logger.debug("%s - - [%s] %s", self.client_address[0], self.log_date_time_string(), format % args)


def run_server(
    host: str = "127.0.0.1",
    port: int = 8080,
    atomic_dir: str = "data/tablebases/atomic",
    antichess_dir: str = "data/tablebases/antichess",
):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
    TablebaseRequestHandler.atomic_engine = AtomicTablebaseEngine(atomic_dir)
    TablebaseRequestHandler.antichess_engine = AntichessTablebaseEngine(antichess_dir)

    server_address = (host, port)
    httpd = ThreadingHTTPServer(server_address, TablebaseRequestHandler)
    logger.info("Tablebase Server running on http://%s:%d", host, port)
    logger.info("Endpoints: /health, /atomic?fen=<fen>, /antichess?fen=<fen>")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down server...")
        httpd.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="RetroSolve Tablebase Sidecar Server")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind to (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8080, help="Port to bind to (default: 8080)")
    parser.add_argument("--atomic-tables", default="data/tablebases/atomic", help="Path to atomic tablebases")
    parser.add_argument("--antichess-tables", default="data/tablebases/antichess", help="Path to antichess tablebases")
    args = parser.parse_args()

    run_server(
        host=args.host,
        port=args.port,
        atomic_dir=args.atomic_tables,
        antichess_dir=args.antichess_tables,
    )
