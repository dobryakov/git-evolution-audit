# git-evolution-audit

Architectural retro-analysis that reads a directory's **git history as a dataset** — to recover the context behind past decisions without relying on human memory. A hybrid of **deterministic metrics + LLM interpretation**: a bash script computes churn and co-change, an LLM writes the narrative on top, and every claim in the report must cite a commit SHA or a number.

Packaged as a Claude Code skill (`.claude/skills/git-evolution-audit/SKILL.md` + `scripts/collect_metrics.sh`). Read-only: only `git log`, `git show`, `git rev-list`.

## What it is not

- **Not** "feed git log into an LLM and get insight" — a month of diffs is tens of MB, doesn't fit a prompt, and an LLM on a raw log invents "evolution" and "turning points" that aren't there.
- **Not** metrics-only (code-maat style) — numbers give the fact, not the explanation. "Component X was rewritten 16 times" is a fact; whether that was searching for form or bad design, numbers won't say.

The goal: **an explanation grounded in numbers** — not a narrative without basis, not a number without interpretation.

## How it works — three layers

1. **Metrics (deterministic, bash + awk).** One script takes `--root <path> --since <date> --until <date> --bulk-threshold K` and emits JSON: `components[]` (commits, insertions/deletions, first/last commit, biggest commit), `co_change_pairs[]` (a, b, co_commits with a < b), `commits[]`. A **bulk filter** drops commits touching more than K components (default 5) from the co-change matrix so cross-cutting refactors don't smear it. No dependencies.
2. **Deterministic commit selection.** The LLM does **not** choose what to read. Fixed rules: per-component top-N by diff size; multi-component non-bulk commits (2–4 components) as turning-point candidates; commits behind the top-5 co-change pairs. The union goes to full `git show -p`; if it exceeds the token budget, it's trimmed from the oldest end and **the report says so**.
3. **Interpretation (LLM).** A fixed report structure (scope → metrics → co-change → turning points → paradoxes → evolution → what's implied → limitations). Every claim links to a number or a SHA; `co_commits = 1` is noise (report keeps `≥ 2`); anything that "seems" true but isn't backed by numbers **stays blank** — a hole beats an ungrounded narrative.

## Usage

```bash
# runs inside a Claude Code session as a skill:
#   "audit the evolution of <dir> since <date>"
# or the metrics layer standalone (no LLM), for CI / dashboards / run-to-run diff:
.claude/skills/git-evolution-audit/scripts/collect_metrics.sh \
  --root path/to/dir --since 2026-01-01 --until 2026-06-30
```

Copy `.claude/skills/git-evolution-audit/` into a target repo's `.claude/skills/` (or point Claude Code at this repository) so the skill is discoverable.

## What it's for

Fighting **subjective drift** — when your opinion of your own architecture diverges from its real state. Especially useful for skill/agent/LLM-pipeline systems, where "how did this component evolve" is harder to answer than for classic code. A cheap quarterly artifact you keep as a baseline: next quarter, next run, the delta is visible with no special tooling.

## Where it breaks

- **Directory renames** distort history (`--follow` works for single files, not dirs; rename detection not implemented — MVP).
- **Rebase / squash / force-push** make numbers inexact where history was rewritten.
- **Binary files** count as 0/0 churn but still bump a component's commit count.
- **Content vs code** — on `outputs/` or log-style dirs, high churn is normal work, not instability; interpretation must know what kind of directory it's reading.
- **Generator/generated pairs** aren't detected (running on `website/` would "explain" generated HTML; the source is `content.md`).
- **Scale** — a whole 5-year monorepo needs budgeting (quarterly slices → meta-summary), not implemented here; realistic MVP target is directories of tens–hundreds of commits.

Context: Adam Tornhill, *Your Code as a Crime Scene* describes the quantitative techniques (churn, co-change). This tool is about the **hybrid with interpretation**, not the metrics alone.
