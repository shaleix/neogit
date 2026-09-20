#!/usr/bin/env bash
# PROTOTYPE — throwaway fixture builder for the libgit2 binding PoC.
# Builds a small repo exercising every interesting status shape:
#   staged/unstaged modify, staged new, staged delete, staged rename,
#   unstaged delete, unstaged rename (as D + ??), untracked, ignored dir,
#   ahead 2 / behind 1 vs upstream.
set -euo pipefail

ROOT=/tmp/opencode/poc-fixtures/rich
REMOTE=/tmp/opencode/poc-fixtures/rich-remote.git
PEER=/tmp/opencode/poc-fixtures/rich-peer

rm -rf "$ROOT" "$REMOTE" "$PEER"
mkdir -p "$ROOT"
cd "$ROOT"

git init -q -b main
git config user.name "PoC" && git config user.email "poc@example.com"
git config commit.gpgsign false

# base: 7 tracked files
for i in 1 2 3 4 5 6 7; do printf 'line one\nline two\n' > "file$i.txt"; done
git add . && git commit -qm "base"
# commit 2: a file we will later rename on disk only, plus gitignore
printf 'to be moved later\n' > filemv.txt
mkdir -p ignoredir && printf 'x\n' > ignoredir/x.txt
printf 'ignoredir/\n' > .gitignore
git add filemv.txt .gitignore && git commit -qm "add filemv + gitignore"

# upstream: bare remote + peer adds 1 commit -> behind 1
git clone -q --bare . "$REMOTE"
git remote add origin "$REMOTE"
git push -q -u origin main
git clone -q "$REMOTE" "$PEER"
cd "$PEER"
git config user.name "PoC" && git config user.email "poc@example.com"
printf 'remote change\n' >> file2.txt
git commit -qam "remote commit"
git push -q
cd "$ROOT"
git fetch -q origin

# local: 2 commits on top -> ahead 2
printf 'local change\n' >> file1.txt && git commit -qam "local 1"
printf 'local change 2\n' >> file4.txt && git commit -qam "local 2"

# ---- index/worktree states (no commits after this point!) ----
printf 'unstaged edit\n' >> file3.txt                      # worktree M
printf 'staged edit\n' >> file5.txt && git add file5.txt   # index M
printf 'brand new\n' > new-staged.txt && git add new-staged.txt  # index A
git rm -q file6.txt                                        # index D
git mv file7.txt renamed-staged.txt                        # index R
rm file1.txt                                               # worktree D
mv filemv.txt filemv-moved.txt                             # worktree rename = D + ??
printf 'ignore me\n' > untracked.txt                       # ??

echo "fixture ready: $ROOT"
git -C "$ROOT" status --porcelain=2 --branch --untracked-files=all
