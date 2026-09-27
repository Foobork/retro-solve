#!/usr/bin/env python3
"""
Local Syzygy Tablebase HTTP Sidecar Server for RetroSolve.

Provides a fast, local REST API compatible with the Lichess Tablebase API:
    GET /atomic?fen=<FEN>
    GET /health

Uses python-chess with AtomicBoard and Syzygy tablebases (3-4-5 pieces)
located in data/tablebases/atomic.
"""

import argparse
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


class TablebaseEngine:
    def __init__(self, tablebase_dir: str):
        self.tablebase_dir = tablebase_dir
        self.tb = chess.syzygy.Tablebase(VariantBoard=chess.variant.AtomicBoard)
        if os.path.exists(tablebase_dir):
            count = self.tb.add_directory(tablebase_dir)
            logger.info("Loaded %d tablebase files from %s", count, tablebase_dir)
        else:
            logger.warning("Tablebase directory not found: %s", tablebase_dir)

    def is_supported(self, board: chess.variant.AtomicBoard) -> bool:
        # Atomic Syzygy tablebases downloaded are 3-4-5 pieces
        piece_count = len(board.piece_map())
        return piece_count <= 5

    def probe(self, fen: str) -> Dict[str, Any]:
        # Clean FEN (handle underscores from URL conventions)
        clean_fen = fen.replace("_", " ").strip()
        tokens = clean_fen.split()
        if len(tokens) < 2:
            raise ValueError(f"Invalid FEN: {fen}")

        try:
            board = chess.variant.AtomicBoard(clean_fen)
        except Exception as e:
            raise ValueError(f"Could not parse atomic FEN: {e}")

        # Check piece count limit
        if not self.is_supported(board):
            return {
                "error": "Tablebase only supports positions with 5 or fewer pieces",
                "category": "unknown",
                "moves": []
            }

        # Terminal game over position
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
                "moves": []
            }

        # Probe position WDL and DTZ directly from Syzygy
        try:
            wdl = self.tb.probe_wdl(board)
            dtz = self.tb.probe_dtz(board)
        except Exception as e:
            return {
                "error": f"Syzygy probe failed: {e}",
                "category": "unknown",
                "moves": []
            }

        pos_cat = CATEGORY_MAP.get(wdl, "unknown")

        # Probe legal moves
        moves_data = []
        for move in board.legal_moves:
            uci = move.uci()
            san = board.san(move)
            zeroing = board.is_zeroing(move)

            board.push(move)
            if board.is_game_over():
                outcome = board.outcome()
                is_draw = outcome is None or outcome.winner is None
                # Side that just moved won?
                prev_won = False if is_draw else outcome.winner == (not board.turn)
                is_cm = outcome.termination == chess.Termination.CHECKMATE if outcome else False
                is_vw = outcome.termination == chess.Termination.VARIANT_LOSS and prev_won if outcome else False
                is_vl = outcome.termination == chess.Termination.VARIANT_LOSS and not prev_won if outcome else False

                # In Lichess API, move category is from opponent's perspective:
                # If side to move wins, opponent loses -> category = "loss"
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

        # Sort candidate moves:
        # 1. Opponent "loss" (winning moves for player): sort by fastest zeroing (smallest abs DTZ)
        # 2. Opponent "draw": sort by DTZ
        # 3. Opponent "win" (losing moves for player): sort by longest survival (largest abs DTZ)
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


class TablebaseRequestHandler(BaseHTTPRequestHandler):
    engine: TablebaseEngine = None  # Injected

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
                "variant": "atomic",
                "tablebase_dir": self.engine.tablebase_dir,
            }
            self.wfile.write(json.dumps(resp).encode("utf-8"))
            return

        if path == "/atomic":
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
                result = self.engine.probe(fen)
                status_code = 404 if "error" in result and result.get("category") == "unknown" else 200
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
        # Quiet regular access logging unless debugging
        logger.debug("%s - - [%s] %s", self.client_address[0], self.log_date_time_string(), format % args)


def run_server(host: str = "127.0.0.1", port: int = 8080, tablebase_dir: str = "data/tablebases/atomic"):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
    engine = TablebaseEngine(tablebase_dir)
    TablebaseRequestHandler.engine = engine

    server_address = (host, port)
    httpd = ThreadingHTTPServer(server_address, TablebaseRequestHandler)
    logger.info("Atomic Tablebase Server running on http://%s:%d", host, port)
    logger.info("Endpoints: http://%s:%d/health, http://%s:%d/atomic?fen=<fen>", host, port, host, port)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down server...")
        httpd.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="RetroSolve Syzygy Tablebase Sidecar Server")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind to (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8080, help="Port to bind to (default: 8080)")
    parser.add_argument("--tables", default="data/tablebases/atomic", help="Path to atomic tablebases")
    args = parser.parse_args()

    run_server(host=args.host, port=args.port, tablebase_dir=args.tables)
