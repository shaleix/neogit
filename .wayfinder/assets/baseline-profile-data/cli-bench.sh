#!/usr/bin/env bash
# 裸 CLI 基准:循环计时(EPOCHREALTIME,无额外 spawn),输出 TSV
set -u
REPO=/tmp/opencode/stress-repo
OUT=${1:-/tmp/opencode/cli-bench.txt}
: > "$OUT"

NG_GIT=(git --no-pager --literal-pathspecs --no-optional-locks -c core.preloadindex=true -c color.ui=always -c diff.noprefix=false)

bench() {
  local label=$1 n=$2
  shift 2
  # 预热 2 次
  "$@" >/dev/null 2>&1
  "$@" >/dev/null 2>&1
  local times=() s e
  for _ in $(seq "$n"); do
    s=$EPOCHREALTIME
    "$@" >/dev/null 2>&1
    e=$EPOCHREALTIME
    times+=("$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f", (b-a)*1000}')")
  done
  # 排序取 min/median/max,算 mean
  local sorted
  sorted=$(printf '%s\n' "${times[@]}" | sort -n)
  local min median max mean sum=0 cnt=${#times[@]}
  min=$(echo "$sorted" | head -1)
  max=$(echo "$sorted" | tail -1)
  median=$(echo "$sorted" | awk -v c="$cnt" 'NR==int((c+1)/2)')
  for t in "${times[@]}"; do sum=$(awk -v a="$sum" -v b="$t" 'BEGIN{printf "%.3f", a+b}'); done
  mean=$(awk -v a="$sum" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$n" "$min" "$median" "$mean" "$max" >> "$OUT"
  printf '%-42s n=%-3s min=%-8s med=%-8s mean=%-8s max=%s ms\n' "$label" "$n" "$min" "$median" "$mean" "$max"
}

cd "$REPO" || exit 1

# --- spawn 固定开销 ---
bench "spawn:/usr/bin/true"            50 /usr/bin/true
bench "spawn:git --version"            50 git --version
bench "spawn:git-probe --version(C)"   50 /tmp/opencode/git-probe --version

# --- status ---
bench "status --porcelain=2 -z (bare)"              10 git status --porcelain=2 -z
bench "status --porcelain=2 -z (neogit argv)"       10 "${NG_GIT[@]}" status -z --porcelain=2
bench "status --porcelain=2 -b (neogit argv)"       10 "${NG_GIT[@]}" status --porcelain=2 -b
bench "status --porcelain=v2 -z (plain, no lock)"   10 git --no-optional-locks status --porcelain=2 -z

# --- log(500) ---
LOGFMT='sanitized_subject_line%x1D%f%x1Fparent%x1F%P%x1Fauthor_date%x1D%aD%x1Fcommit_notes%x1D%N%x1Fcommitter_name%x1D%cN%x1Fcommitter_email%x1D%cE%x1Fcommitter_date%x1D%cD%x1Fref_name%x1D%D%x1Ftree%x1D%T%x1Funix_date%x1D%ct%x1Flog_date%x1D%cd%x1Fauthor_name%x1D%aN%x1Fabbreviated_commit%x1D%h%x1Foid%x1D%H%x1Fbody%x1D%b%x1Fabbreviated_tree%x1D%t%x1Frel_date%x1D%cr%x1Fsubject%x1D%s%x1Fabbreviated_parent%x1D%p%x1Fencoding%x1D%e%x1Fauthor_email%x1D%aE%x1E'
bench "log -500 (bare oneline)"                     10 git log --oneline --no-patch --max-count=500 --topo-order
bench "log -500 (neogit argv+format)"               10 "${NG_GIT[@]}" log --format="$LOGFMT" --no-patch --max-count=500 --topo-order

# --- diff ---
bench "diff HEAD (bare)"                            10 git diff HEAD
bench "diff HEAD (neogit argv)"                     10 "${NG_GIT[@]}" diff HEAD
bench "diff --stat HEAD (neogit argv)"              10 "${NG_GIT[@]}" diff --stat HEAD

# --- 其他高频读 ---
bench "rev-parse HEAD"                              10 git rev-parse HEAD
bench "describe --long --tags HEAD"                 10 git describe --long --tags HEAD
bench "stash list"                                  10 git stash list
bench "for-each-ref (refs.lua fmt)"                 10 "${NG_GIT[@]}" for-each-ref '--format=%(refname)%1f%(objectname)%1f%(*objectname)%1f%(contents:subject)' --sort=-committerdate refs/heads/ refs/remotes

bench "for-each-ref (refs.lua fmt)"                 10 "${NG_GIT[@]}" for-each-ref '--format=%(refname)%1f%(objectname)%1f%(*objectname)%1f%(contents:subject)' --sort=-committerdate refs/heads/ refs/remotes
echo "---"
echo "results in $OUT"
