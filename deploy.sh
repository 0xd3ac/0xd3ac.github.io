#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== Generating ==="
npx hexo generate
cp source/.nojekyll public/

echo "=== Deploying ==="
cd public
git init
git config http.proxy http://127.0.0.1:7890
git add -A
git commit -m "deploy: $(date +%Y-%m-%d_%H:%M)" || true
git remote add origin https://github.com/0xd3ac/0xd3ac.github.io.git 2>/dev/null || true
git push -f origin master

echo "=== Done: https://0xd3ac.github.io/ ==="
