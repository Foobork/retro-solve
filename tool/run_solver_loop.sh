#!/usr/bin/env bash
cd /home/antigravity/Foobork/retro-solve
cat /home/antigravity/.gemini/solve_best_first.py > tool/solve_best_first.py
while true; do
  echo "[$(date -Is)] Starting solve_best_first.py..." >> data/solver.log
  uv run --with chess python3 tool/solve_best_first.py --line "Nf3 d6 Ng5" >> data/solver.log 2>&1
  EXIT_CODE=$?
  echo "[$(date -Is)] solve_best_first.py exited with code $EXIT_CODE" >> data/solver.log
  if tail -n 20 data/solver.log | grep -q "Search Finished! Proven: True"; then
    echo "[$(date -Is)] Subtree PROVEN! Exiting loop." >> data/solver.log
    break
  fi
  if tail -n 20 data/solver.log | grep -q "Engine Evals: 0 "; then
    echo "[$(date -Is)] Search finished with 0 new engine evals; stopping loop." >> data/solver.log
    break
  fi
  sleep 3
done
