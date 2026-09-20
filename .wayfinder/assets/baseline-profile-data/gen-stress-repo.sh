#!/usr/bin/env bash
# 构造压力仓库:~3000 文件 × 200 提交,混合大小提交,末尾留脏工作区
set -euo pipefail
ROOT=${1:-/tmp/opencode/stress-repo}
NFILES=${2:-3000}
NTOTALCOMMITS=${3:-200}
SEED=${4:-20260920}

NDIRS=100
PERDIR=$((NFILES / NDIRS))

rm -rf "$ROOT"
mkdir -p "$ROOT"
cd "$ROOT"
git init -q -b main
git config user.email bench@example.com
git config user.name bench
git config commit.gpgsign false

echo "[1/4] generating $NFILES files ($NDIRS dirs x $PERDIR files)..."
awk -v ndirs="$NDIRS" -v perdir="$PERDIR" -v seed="$SEED" 'BEGIN{
  srand(seed);
  for (d = 1; d <= ndirs; d++) {
    dir = sprintf("dir%03d", d);
    system("mkdir -p " dir);
    for (f = 1; f <= perdir; f++) {
      path = sprintf("%s/file%03d.txt", dir, f);
      for (i = 0; i < 40; i++) {
        line = "";
        for (w = 0; w < 12; w++) {
          line = line sprintf("%c", 97 + int(rand() * 26));
        }
        print line > path;
      }
      close(path);
    }
  }
}'

echo "[2/4] initial commit of all files..."
git add -A
git commit -q -m "initial: import $NFILES files"

echo "[3/4] creating $((NTOTALCOMMITS - 1)) commits (mix of small/large)..."
ALLFILES=$(git ls-files)
i=0
for c in $(seq 2 "$NTOTALCOMMITS"); do
  i=$((i + 1))
  if [ $((c % 7)) -eq 0 ]; then
    # 大提交:改 300 个文件
    N=300
  else
    # 小提交:改 3 个文件
    N=3
  fi
  echo "$ALLFILES" | awk -v n="$N" -v seed=$((SEED + c)) 'BEGIN{srand(seed)} {a[NR]=$0} END{for(j=1;j<=n && j<=NR;j++){k=int(rand()*NR)+1; t=a[j]; a[j]=a[k]; a[k]=t}; for(j=1;j<=n && j<=NR;j++) print a[j]}' | while read -r f; do
    echo "change $f line (commit $c)" >> "$f"
  done
  git add -u
  git commit -q -m "commit $c: modify files"
done

echo "[4/4] leaving dirty worktree (unstaged + staged + untracked)..."
# 50 个未暂存修改
echo "$ALLFILES" | head -50 | while read -r f; do echo "unstaged change $f" >> "$f"; done
# 20 个已暂存修改
echo "$ALLFILES" | tail -20 | while read -r f; do echo "staged change $f" >> "$f"; done
git add $(echo "$ALLFILES" | tail -20 | tr '\n' ' ')
# 10 个未跟踪文件
for u in $(seq 1 10); do
  echo "untracked $u" > "untracked-$u.txt"
done

git gc -q

echo "=== repo stats ==="
echo "commits:   $(git rev-list --count HEAD)"
echo "files:     $(git ls-files | wc -l)"
echo "objects:   $(git count-objects -v | grep -E '^count|in-pack' | tr '\n' ' ')"
echo "repo size: $(du -sh .git | cut -f1)"
echo "status:    $(git status --porcelain | wc -l) dirty entries"
