#!/bin/bash
set -e
git add -A
git commit -m "Auto-update Keep Awake: $(date '+%Y-%m-%d %H:%M:%S')" || true
git push origin main
echo "Successfully pushed latest updates to GitHub!"
