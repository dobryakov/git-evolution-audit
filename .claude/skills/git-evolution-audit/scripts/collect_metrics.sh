#!/usr/bin/env bash
# collect_metrics.sh — deterministic metric layer for git-evolution-audit.
#
# Emits JSON to stdout. Read-only: only git log / rev-list / show --name-only.
#
# Components are immediate subdirectories of --root (one level deep). Files
# directly at --root (not in a subdir) are grouped under "_root".
#
# Bulk-commit filter: commits touching > BULK_THRESHOLD distinct components
# are excluded from the co-change matrix but still counted in per-component
# churn. This avoids "обновил всё" coloring the coupling signal.

set -euo pipefail

ROOT=""
SINCE=""
UNTIL=""
BULK_THRESHOLD=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)            ROOT="$2"; shift 2 ;;
    --since)           SINCE="$2"; shift 2 ;;
    --until)           UNTIL="$2"; shift 2 ;;
    --bulk-threshold)  BULK_THRESHOLD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  echo "--root is required" >&2
  exit 2
fi
if [[ ! -d "$ROOT" ]]; then
  echo "--root is not a directory: $ROOT" >&2
  exit 2
fi

# Normalize root to repo-relative path
REPO_ROOT="$(git rev-parse --show-toplevel)"
ROOT_ABS="$(cd "$ROOT" && pwd)"
ROOT_REL="${ROOT_ABS#$REPO_ROOT/}"
if [[ "$ROOT_REL" == "$ROOT_ABS" ]]; then
  echo "--root is outside the repo: $ROOT" >&2
  exit 2
fi

GIT_RANGE_ARGS=()
[[ -n "$SINCE" ]] && GIT_RANGE_ARGS+=(--since "$SINCE")
[[ -n "$UNTIL" ]] && GIT_RANGE_ARGS+=(--until "$UNTIL")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Pull raw log with numstat into a flat file: one record per commit.
# Format per commit:
#   __COMMIT__\t<sha>\t<unix>\t<iso>\t<author>\t<subject>
#   <add>\t<del>\t<path>
#   ...
git log "${GIT_RANGE_ARGS[@]}" \
  --pretty=format:'__COMMIT__%x09%H%x09%at%x09%aI%x09%an%x09%s' \
  --numstat -- "$ROOT_REL" > "$TMP/log.tsv"

# Map each path to its component. Component = first path segment AFTER ROOT_REL.
# Path "ROOT_REL/<comp>/..." → comp. Path "ROOT_REL/<file>" → _root.
awk -v root="$ROOT_REL" -v bulk="$BULK_THRESHOLD" '
function flush_commit() {
  if (sha == "") return
  ncomp = 0
  for (c in seen) { ncomp++ }
  is_bulk = (ncomp > bulk) ? 1 : 0
  printf("C\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\n", sha, ts, iso, author, subj, total_add, total_del, is_bulk)
  for (c in seen) {
    printf("CC\t%s\t%s\t%d\t%d\n", sha, c, comp_add[c], comp_del[c])
  }
  if (!is_bulk) {
    n = 0
    for (c in seen) { arr[n++] = c }
    for (i = 0; i < n; i++) {
      for (j = i + 1; j < n; j++) {
        a = arr[i]; b = arr[j]
        if (a > b) { t = a; a = b; b = t }
        printf("CP\t%s\t%s\t%s\n", sha, a, b)
      }
    }
    delete arr
  }
  delete seen; delete comp_add; delete comp_del
  sha = ""; total_add = 0; total_del = 0
}
BEGIN { FS = "\t"; sha = "" }
$1 == "__COMMIT__" {
  flush_commit()
  sha = $2; ts = $3; iso = $4; author = $5; subj = $6
  total_add = 0; total_del = 0
  next
}
NF >= 3 && sha != "" {
  add = $1; del = $2; path = $3
  # binary files show "-" "-"; treat as 0/0 but still count the touch.
  if (add == "-") add = 0
  if (del == "-") del = 0
  add += 0; del += 0
  # path must start with ROOT_REL/
  if (index(path, root "/") != 1) next
  rest = substr(path, length(root) + 2)
  slash = index(rest, "/")
  if (slash == 0) {
    comp = "_root"
  } else {
    comp = substr(rest, 1, slash - 1)
  }
  seen[comp] = 1
  comp_add[comp] += add
  comp_del[comp] += del
  total_add += add
  total_del += del
}
END { flush_commit() }
' "$TMP/log.tsv" > "$TMP/parsed.tsv"

# Build aggregates:
#   comp_stats.tsv : comp \t commits \t add \t del \t first_iso \t last_iso \t biggest_sha \t biggest_size
#   pair_stats.tsv : a \t b \t co_count
#   comp_counts.tsv: comp \t commit_count_total (incl bulk, for denominator)
#   commits.tsv    : sha \t iso \t author \t subj \t add \t del \t is_bulk \t comps_csv

awk -F'\t' '
$1 == "C"  { commit_iso[$2] = $4; commit_author[$2] = $5; commit_subj[$2] = $6; commit_add[$2] = $7; commit_del[$2] = $8; commit_bulk[$2] = $9; commit_ts[$2] = $3; commits[$2] = 1 }
$1 == "CC" {
  sha = $2; comp = $3; add = $4; del = $5
  comp_commits[comp]++
  comp_add[comp] += add
  comp_del[comp] += del
  size = add + del
  if (!(comp in first_iso) || commit_ts[sha] < first_ts[comp]) {
    first_iso[comp] = commit_iso[sha]; first_ts[comp] = commit_ts[sha]
  }
  if (!(comp in last_iso) || commit_ts[sha] > last_ts[comp]) {
    last_iso[comp] = commit_iso[sha]; last_ts[comp] = commit_ts[sha]
  }
  if (!(comp in big_size) || size > big_size[comp]) {
    big_size[comp] = size; big_sha[comp] = sha
  }
  # collect comps per commit for commits.tsv
  if (commit_comps[sha] == "") {
    commit_comps[sha] = comp
  } else {
    commit_comps[sha] = commit_comps[sha] "," comp
  }
}
$1 == "CP" {
  a = $2 "\t" $3 "\t" $4   # sha, comp_a, comp_b — but we want pair count, not sha
  pair_key = $3 "\t" $4
  pair[pair_key]++
}
END {
  for (c in comp_commits) {
    print "S\t" c "\t" comp_commits[c] "\t" comp_add[c] "\t" comp_del[c] "\t" first_iso[c] "\t" last_iso[c] "\t" big_sha[c] "\t" big_size[c]
  }
  for (p in pair) {
    print "P\t" p "\t" pair[p]
  }
  for (sha in commits) {
    print "K\t" sha "\t" commit_iso[sha] "\t" commit_author[sha] "\t" commit_add[sha] "\t" commit_del[sha] "\t" commit_bulk[sha] "\t" commit_comps[sha] "\t" commit_subj[sha]
  }
}
' "$TMP/parsed.tsv" > "$TMP/agg.tsv"

# JSON emission. We hand-build JSON in awk; only data sources are
# git-controlled paths/SHAs and commit metadata (subjects can contain
# quotes/backslashes — escape both).
awk -F'\t' '
function jesc(s,    r) {
  r = s
  gsub(/\\/, "\\\\", r)
  gsub(/"/, "\\\"", r)
  gsub(/\n/, "\\n", r)
  gsub(/\r/, "\\r", r)
  gsub(/\t/, "\\t", r)
  return r
}
$1 == "S" { ns++; comps[ns] = $0 }
$1 == "P" { np++; pairs[np] = $0 }
$1 == "K" { nk++; ks[nk] = $0 }
END {
  print "{"
  print "  \"components\": ["
  for (i = 1; i <= ns; i++) {
    n = split(comps[i], f, "\t")
    sep = (i < ns) ? "," : ""
    printf("    {\"name\":\"%s\",\"commits\":%d,\"insertions\":%d,\"deletions\":%d,\"first_commit\":\"%s\",\"last_commit\":\"%s\",\"biggest_commit_sha\":\"%s\",\"biggest_commit_size\":%d}%s\n",
      jesc(f[2]), f[3]+0, f[4]+0, f[5]+0, f[6], f[7], f[8], f[9]+0, sep)
  }
  print "  ],"
  print "  \"co_change_pairs\": ["
  for (i = 1; i <= np; i++) {
    n = split(pairs[i], f, "\t")
    sep = (i < np) ? "," : ""
    printf("    {\"a\":\"%s\",\"b\":\"%s\",\"co_commits\":%d}%s\n", jesc(f[2]), jesc(f[3]), f[4]+0, sep)
  }
  print "  ],"
  print "  \"commits\": ["
  for (i = 1; i <= nk; i++) {
    n = split(ks[i], f, "\t")
    sep = (i < nk) ? "," : ""
    printf("    {\"sha\":\"%s\",\"date\":\"%s\",\"author\":\"%s\",\"insertions\":%d,\"deletions\":%d,\"is_bulk\":%s,\"components\":\"%s\",\"subject\":\"%s\"}%s\n",
      f[2], f[3], jesc(f[4]), f[5]+0, f[6]+0, (f[7] == "1" ? "true" : "false"), jesc(f[8]), jesc(f[9]), sep)
  }
  print "  ]"
  print "}"
}
' "$TMP/agg.tsv"
