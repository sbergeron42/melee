#!/bin/bash
# Overnight autonomous decompilation runner.
#
# Finds undecompiled function stubs, checks GitHub for conflicts,
# then spawns Claude Code sessions to decompile each one.
# Each function gets its own worktree branch and PR.
#
# Usage:
#   ./scripts/decomp_overnight.sh                    # scan default files
#   ./scripts/decomp_overnight.sh src/melee/ft/*.c   # scan specific files
#   MODEL=sonnet ./scripts/decomp_overnight.sh                  # use a different model
#   CONTINUOUS=true CUTOFF_HOUR=8 ./scripts/decomp_overnight.sh # loop until 8 AM
#
# Prerequisites:
#   - `claude` CLI authenticated
#   - `gh` CLI authenticated
#   - `ninja` builds successfully on current master
#   - Wine Crossover installed (macOS)
#   - m2c installed: pip install "m2c @ git+https://github.com/matt-kempster/m2c.git"

set -euo pipefail

# --- Windows (MSYS/Git Bash) compatibility ---
IS_WINDOWS=false
if [[ "$OSTYPE" == msys* ]] || [[ "$OSTYPE" == cygwin* ]] || [[ "$OSTYPE" == mingw* ]]; then
    IS_WINDOWS=true
fi

# Activate venv if present (needed for pyelftools, m2c, etc.)
if [ -f ".venv/Scripts/activate" ]; then
    source .venv/Scripts/activate
elif [ -f ".venv/bin/activate" ]; then
    source .venv/bin/activate
fi

# Emulate pgrep/pkill on Windows where procps isn't available
if [ "$IS_WINDOWS" = "true" ] && ! command -v pgrep >/dev/null 2>&1; then
    pgrep() {
        local pattern=""
        while [ $# -gt 0 ]; do
            case "$1" in -f) shift ;; *) pattern="$1"; shift ;; esac
        done
        { ps 2>/dev/null; ps -W 2>/dev/null; } | grep -i "$pattern" | grep -v grep | awk '{print $1}'
    }
    pkill() {
        local signal="" pattern="" ppid=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -9) signal="-9"; shift ;;
                -f) shift ;;
                -P) ppid="$2"; shift 2 ;;
                *) pattern="$1"; shift ;;
            esac
        done
        if [ -n "$ppid" ]; then
            ps 2>/dev/null | awk -v p="$ppid" '$2==p {print $1}' | while read -r pid; do
                kill $signal "$pid" 2>/dev/null || true
            done
        elif [ -n "$pattern" ]; then
            taskkill //F //IM "${pattern}.exe" 2>/dev/null || true
            ps 2>/dev/null | grep -i "$pattern" | grep -v grep | awk '{print $1}' | while read -r pid; do
                kill $signal "$pid" 2>/dev/null || true
            done
        fi
    }
fi

# Platform-specific configure args (no Wine wrapper needed on Windows)
if [ "$IS_WINDOWS" = "true" ]; then
    CONFIGURE_ARGS=""
else
    CONFIGURE_ARGS="--wrapper wine"
fi

CHILD_PIDS=()
track_pid() { CHILD_PIDS+=("$1"); }
kill_children() {
    for pid in "${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true
        pkill -P "$pid" 2>/dev/null || true
    done
    CHILD_PIDS=()
}
cleanup() {
    local rc=$?
    trap - INT TERM EXIT
    kill_children
    pkill -P $$ 2>/dev/null || true
    # Wait for killed children to actually exit
    wait 2>/dev/null || true
    exit $rc
}

# Ctrl+C: kill active Claude session, let the script clean up gracefully
STOP_REQUESTED=false
handle_interrupt() {
    STOP_REQUESTED=true
    if [ -n "${CLAUDE_PID:-}" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        log ""
        log "  Ctrl+C received, stopping Claude session..."
        kill "$CLAUDE_PID" 2>/dev/null || true
        pkill -P "$CLAUDE_PID" 2>/dev/null || true
    else
        log ""
        log "  Ctrl+C received, finishing current step..."
    fi
}
trap handle_interrupt INT
trap cleanup TERM EXIT

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
HELPERS="$REPO_ROOT/scripts/decomp_helpers.py"

NINJA_TIMEOUT=${NINJA_TIMEOUT:-300}
NINJA_STALL_TIMEOUT=${NINJA_STALL_TIMEOUT:-15}
NINJA_MAX_RETRIES=${NINJA_MAX_RETRIES:-10}

# Kill stale processes from previous runs (exclude self)
kill_stale_processes() {
    local stale_found=false
    local self_pid=$$
    for proc in decomp_overnight decomp_helpers ninja mwcceppc; do
        local pids
        pids=$(pgrep -f "$proc" 2>/dev/null | grep -v "^${self_pid}$" || true)
        if [ -n "$pids" ]; then
            echo "$pids" | xargs kill 2>/dev/null || true
            stale_found=true
        fi
    done
    # Kill stale Wine servers that can interfere with builds
    [ "$IS_WINDOWS" != "true" ] && wineserver -k 2>/dev/null || true
    if [ "$stale_found" = "true" ]; then
        sleep 2
    fi
}
# Run ninja with a watchdog that detects stalls (no output progress for
# NINJA_STALL_TIMEOUT seconds) and auto-kills hung wine/compiler processes.
# Retries up to NINJA_MAX_RETRIES times.
# Usage: run_ninja_with_watchdog [ninja args...]
# Returns: ninja's exit code, or 1 if all retries exhausted
run_ninja_with_watchdog() {
    local attempt=0
    local ninja_rc_file stall_marker
    ninja_rc_file=$(mktemp /tmp/ninja_rc.XXXXXX)
    stall_marker=$(mktemp /tmp/ninja_progress.XXXXXX)

    while [ $attempt -lt $NINJA_MAX_RETRIES ]; do
        if [ $attempt -gt 0 ]; then
            log "  Ninja stalled, retry ${attempt}/${NINJA_MAX_RETRIES}..."
            sleep 2
        fi
        rm -f "$ninja_rc_file"
        touch "$stall_marker"

        # Subshell captures ninja's exit code; pipe shows progress
        (ninja "$@" 2>&1; echo $? > "$ninja_rc_file") \
            | python3 -u "$HELPERS" ninja-progress &
        local bg_pid=$!
        track_pid $bg_pid

        # Monitor for stalls using the .o file modification times
        local stalled=false
        local waited=0
        local last_mtime
        last_mtime=$(date +%s)
        while kill -0 $bg_pid 2>/dev/null && [ $waited -lt $NINJA_TIMEOUT ]; do
            sleep 1
            waited=$((waited + 1))
            # Check if any .o file was modified recently
            local newest
            newest=$(find build/GALE01 -name '*.o' -newer "$stall_marker" -print -quit 2>/dev/null || true)
            if [ -n "$newest" ]; then
                touch "$stall_marker"
                last_mtime=$(date +%s)
            fi
            local now elapsed
            now=$(date +%s)
            elapsed=$((now - last_mtime))
            if [ "$elapsed" -ge "$NINJA_STALL_TIMEOUT" ] && [ "$waited" -gt 5 ]; then
                stalled=true
                break
            fi
        done

        if [ "$stalled" = "true" ] || { kill -0 $bg_pid 2>/dev/null && [ $waited -ge $NINJA_TIMEOUT ]; }; then
            if [ "$stalled" = "true" ]; then
                log "  Ninja stalled (no progress for ${NINJA_STALL_TIMEOUT}s), killing..."
            else
                log "  Ninja timed out after ${NINJA_TIMEOUT}s, killing..."
            fi
            kill $bg_pid 2>/dev/null || true
            pkill -P $bg_pid 2>/dev/null || true
            pkill -f mwcceppc 2>/dev/null || true
            [ "$IS_WINDOWS" != "true" ] && wineserver -k 2>/dev/null || true
            [ "$IS_WINDOWS" != "true" ] && pkill -9 -f wine-preloader 2>/dev/null || true
            wait $bg_pid 2>/dev/null || true
            CHILD_PIDS=()  # Clear tracked PIDs after kill
            attempt=$((attempt + 1))
            continue
        fi

        wait $bg_pid 2>/dev/null || true
        CHILD_PIDS=()  # Clear tracked PIDs after ninja completes
        local ninja_exit
        ninja_exit=$(cat "$ninja_rc_file" 2>/dev/null || echo 1)
        rm -f "$ninja_rc_file" "$stall_marker"
        return "$ninja_exit"
    done

    CHILD_PIDS=()
    rm -f "$ninja_rc_file" "$stall_marker"
    log "  Ninja failed after $NINJA_MAX_RETRIES retries"
    return 1
}

kill_stale_processes

LOG_DIR="$REPO_ROOT/scripts/logs"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/overnight_$TIMESTAMP.log"

REPO="doldecomp/melee"
MODEL=${MODEL:-opus}
# Set to "all" to scan all files with stubs, or pass files as args
SCAN_MODE=${SCAN_MODE:-all}
CONTINUOUS=${CONTINUOUS:-true}
CUTOFF_HOUR=${CUTOFF_HOUR:-0}
AUTO_PUSH=${AUTO_PUSH:-false}
BATCH_SIZE=${BATCH_SIZE:-5}
PROGRESS_FILE="$LOG_DIR/progress_$(date +%Y%m%d).json"
PERMUTER_PATH=${PERMUTER_PATH:-$HOME/dev/decomp-permuter}
PERMUTER_JOBS=${PERMUTER_JOBS:-4}
PERMUTER_TIMEOUT=${PERMUTER_TIMEOUT:-300}

# Tmux mode: spawn interactive Claude Code sessions (with skills/plugins)
# Set USE_TMUX=true to enable. Attach with: tmux attach -t decomp-*
USE_TMUX=${USE_TMUX:-false}
TMUX_IDLE_TIMEOUT=${TMUX_IDLE_TIMEOUT:-120}    # seconds of no output -> assume done
TMUX_HARD_TIMEOUT=${TMUX_HARD_TIMEOUT:-3600}   # max seconds per session

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$MAIN_LOG"
}

# Abort if worktree is dirty (instead of the old git stash approach)
check_worktree_clean() {
    if ! git diff --quiet HEAD 2>/dev/null; then
        log "ERROR: Working tree is dirty. Commit or stash changes before running."
        log "  (This script no longer auto-stashes to avoid reverting its own edits.)"
        exit 1
    fi
}

CUTOFF_EPOCH=$(python3 "$HELPERS" cutoff-epoch "$CUTOFF_HOUR")

past_cutoff() {
    [ "$(date +%s)" -ge "$CUTOFF_EPOCH" ]
}

# Resolve OAuth token (same logic as statusline.sh)
get_oauth_token() {
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        echo "${CLAUDE_CODE_OAUTH_TOKEN:-}"
        return 0
    fi
    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            local token
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi
    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        local token
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi
    echo ""
}

# Fetch and log usage from the OAuth API. Sets USAGE_WEEKLY_PCT.
USAGE_WEEKLY_PCT=0
check_usage() {
    local token
    token=$(get_oauth_token)
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log "  [usage] Could not resolve OAuth token"
        return
    fi
    local response
    response=$(curl -s --max-time 5 \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1.34" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    if [ -z "$response" ] || ! echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
        log "  [usage] Failed to fetch usage data"
        return
    fi
    local five_pct seven_pct five_reset seven_reset
    five_pct=$(echo "$response" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    seven_pct=$(echo "$response" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    five_reset=$(echo "$response" | jq -r '.five_hour.resets_at // "?"')
    seven_reset=$(echo "$response" | jq -r '.seven_day.resets_at // "?"')
    USAGE_WEEKLY_PCT=$seven_pct
    log "  [usage] current: ${five_pct}% (resets ${five_reset}) | weekly: ${seven_pct}% (resets ${seven_reset})"
}

progress_save() {
    python3 "$HELPERS" progress-save "$PROGRESS_FILE" "$1" "$2"
}

# Look up a single function's result in the parsed RESULT_LINE.
# Returns "success" or "failure". Defaults to "success" if not found
# (single-function batches rarely emit per-function lines).
get_func_result() {
    local fname="$1"
    local result
    result=$(echo "$RESULT_LINE" | grep "^func_${fname}=" | sed "s/^func_${fname}=//" | head -1 || true)
    echo "${result:-success}"
}

progress_already_tried() {
    [ -f "$PROGRESS_FILE" ] && python3 "$HELPERS" progress-check "$PROGRESS_FILE" "$1" 2>/dev/null
}

# Parse results from plain text tmux output (strips ANSI codes).
# Output format matches parse-result: status=, context=, func_*= lines.
parse_text_result() {
    local log_file="$1"

    # Prefer the clean result file written by Claude (no TUI artifacts)
    local result_file="/tmp/decomp_result.txt"
    if [ -f "$result_file" ]; then
        local clean
        clean=$(cat "$result_file")
        rm -f "$result_file"

        local context_line
        context_line=$(echo "$clean" | grep "^CONTEXT:" | tail -1 || true)
        [ -n "$context_line" ] && echo "context=${context_line#CONTEXT: }"

        local results_line
        results_line=$(echo "$clean" | grep "^RESULTS:" | tail -1 || true)
        if [ -n "$results_line" ]; then
            if echo "$results_line" | grep -q "SUCCESS"; then
                echo "status=success"
            else
                local best
                best=$(echo "$results_line" | grep -oE 'best=[0-9.]+' | head -1 | sed 's/best=//' || true)
                echo "status=failure best=${best:-?}"
            fi
            echo "$results_line" | grep -oE '[A-Za-z_][A-Za-z_0-9]*=(SUCCESS|FAILURE)' | while read -r part; do
                local fname fstatus
                fname=$(echo "$part" | sed 's/=.*//')
                fstatus=$(echo "$part" | sed 's/.*=//')
                [ "$fstatus" = "SUCCESS" ] && echo "func_${fname}=success" || echo "func_${fname}=failure"
            done
            return
        fi
    fi

    # Fallback: parse from TUI log (lossy — words may be concatenated)
    if [ ! -f "$log_file" ]; then
        echo "status=error"
        return
    fi
    local clean
    clean=$(perl -pe 's/\e\[\??[0-9;]*[a-zA-Z]//g; s/\e\][^\x07]*\x07//g; s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g; s/\x1b.//g' "$log_file")

    local context_line
    context_line=$(echo "$clean" | grep "^CONTEXT:" | tail -1 || true)
    if [ -n "$context_line" ]; then
        echo "context=${context_line#CONTEXT: }"
    fi

    local results_line
    results_line=$(echo "$clean" | grep "^RESULTS:" | tail -1 || true)
    if [ -z "$results_line" ]; then
        echo "status=error"
        return
    fi

    # Overall status: success if any function succeeded
    if echo "$results_line" | grep -q "SUCCESS"; then
        echo "status=success"
    else
        local best
        best=$(echo "$results_line" | grep -oE 'best=[0-9.]+' | head -1 | sed 's/best=//' || echo "?")
        echo "status=failure best=$best"
    fi

    # Per-function results: func1=SUCCESS func2=FAILURE(best=XX%)
    echo "$results_line" | grep -oE '[A-Za-z_][A-Za-z_0-9]*=(SUCCESS|FAILURE)' | while read -r part; do
        local fname fstatus
        fname=$(echo "$part" | sed 's/=.*//')
        fstatus=$(echo "$part" | sed 's/.*=//')
        if [ "$fstatus" = "SUCCESS" ]; then
            echo "func_${fname}=success"
        else
            echo "func_${fname}=failure"
        fi
    done
}

cleanup_worktree() {
    local branch_name="$1"
    local wt_path
    wt_path=$(git worktree list --porcelain 2>/dev/null | grep -F "$branch_name" | head -1 | sed 's/worktree //' || true)
    if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
        git worktree remove "$wt_path" --force 2>/dev/null || true
    fi
}

cleanup_stale_worktrees() {
    log "Cleaning up stale worktrees..."
    for wt in $(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/worktree //' | grep -vxF "$REPO_ROOT"); do
        if [ ! -d "$wt" ]; then
            continue
        fi
        wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$wt_branch" == decomp-* ]] || [[ "$wt_branch" == worktree-decomp-* ]]; then
            # Check for src/ commits not yet in upstream (the actual decomp work)
            src_ahead=$(git log --format="%H" upstream/master.."$wt_branch" -- src/ 2>/dev/null | wc -l | tr -d ' ' || echo 0)
            if [ "$src_ahead" -eq 0 ]; then
                log "  Removing stale worktree: $wt ($wt_branch, no new src/ work)"
                git worktree remove "$wt" --force 2>/dev/null || true
            else
                log "  Keeping worktree with src/ commits: $wt ($wt_branch, $src_ahead src/ commits)"
            fi
        fi
    done
    git worktree prune 2>/dev/null || true
}

# Collect source files to scan
if [ $# -gt 0 ]; then
    SOURCE_FILES=("$@")
elif [ "$SCAN_MODE" = "all" ]; then
    SOURCE_FILES=()
    while IFS= read -r f; do SOURCE_FILES+=("$f"); done < <(grep -rl '/// #' src/melee/ --include='*.c' 2>/dev/null)
else
    SOURCE_FILES=(src/melee/ft/chara/ftCommon/ftCo_Attack100.c)
fi

if [ "$USE_TMUX" = "true" ] && ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: USE_TMUX=true but tmux is not installed"
    exit 1
fi

log "=== Overnight Decomp Runner ==="
log "Scanning ${#SOURCE_FILES[@]} files"
log "Model: $MODEL"
if [ "$USE_TMUX" = "true" ]; then
    log "Tmux mode: ON (attach with: tmux attach -t decomp-*)"
fi
if [ "$CONTINUOUS" = "true" ]; then
    log "Continuous mode: ON (cutoff: $(date -r "$CUTOFF_EPOCH" '+%H:%M' 2>/dev/null || date -d "@$CUTOFF_EPOCH" '+%H:%M' 2>/dev/null || echo "$CUTOFF_HOUR:00"))"
fi

check_worktree_clean
cleanup_stale_worktrees

# Seed build cache if already built — avoids unnecessary full rebuild on first iteration
if [ -f "$REPO_ROOT/build.ninja" ]; then
    NINJA_DRY=$(ninja -n 2>&1 || true)
    if echo "$NINJA_DRY" | grep -q "no work to do"; then
        LAST_BUILT_HEAD=$(git rev-parse HEAD)
        log "Build already clean, seeded cache at $LAST_BUILT_HEAD"
    fi
fi

TOTAL_SUCCESSES=0
TOTAL_FAILURES=0

# Draft PR for live progress tracking (persistent across runs)
DRAFT_STATUS_FILE="$LOG_DIR/draft_status.json"
DRAFT_PR_NUMBER=""
DRAFT_BRANCH="wip/pending-matches"

# Initialize empty status file, and clear stale "pending" entries from crashed runs
[ -f "$DRAFT_STATUS_FILE" ] || echo '[]' > "$DRAFT_STATUS_FILE"
python3 "$HELPERS" draft-pr-clear-pending "$DRAFT_STATUS_FILE" 2>/dev/null || true

draft_pr_set_status() {
    # Usage: draft_pr_set_status <func_name> <file> <status> [detail] [context]
    python3 "$HELPERS" draft-pr-set-status "$DRAFT_STATUS_FILE" "$1" "$2" "$3" "${4:-}" "${5:-}"
}

draft_pr_update() {
    [ -z "$DRAFT_PR_NUMBER" ] && return
    local body
    body=$(python3 "$HELPERS" draft-pr-body "$DRAFT_STATUS_FILE" 2>/dev/null) || return
    gh api "repos/$REPO/pulls/$DRAFT_PR_NUMBER" -X PATCH \
        -f body="$body" >/dev/null 2>&1 || log "  (draft PR update failed)"
}

# Cherry-pick successful commits from a worktree branch onto wip/pending-matches.
# Returns 0 if at least one commit was cherry-picked, 1 otherwise.
cherry_pick_to_draft() {
    local src_branch="$1"
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    # Get commits unique to the worktree branch (src/ only)
    local commits
    commits=$(git rev-list --reverse upstream/master.."$src_branch" 2>/dev/null || true)
    if [ -z "$commits" ]; then
        log "  (no commits to cherry-pick from $src_branch)"
        return 1
    fi

    # Stash dirty working tree so we can switch branches cleanly
    local stashed=false
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git stash push -m "overnight-cherry-pick-stash" >> "$MAIN_LOG" 2>&1 && stashed=true
    fi

    git checkout "$DRAFT_BRANCH" 2>/dev/null || {
        log "  WARNING: could not checkout $DRAFT_BRANCH for cherry-pick"
        [ "$stashed" = "true" ] && git stash pop >> "$MAIN_LOG" 2>&1 || true
        git checkout "$current_branch" 2>/dev/null || git checkout master 2>/dev/null
        return 1
    }

    local picked=false
    while IFS= read -r commit; do
        [ -z "$commit" ] && continue
        # Only cherry-pick if the commit touches src/ files
        if git diff-tree --no-commit-id --name-only -r "$commit" | grep -q '^src/'; then
            if git cherry-pick "$commit" >> "$MAIN_LOG" 2>&1; then
                picked=true
            else
                log "  WARNING: cherry-pick failed for $commit, aborting"
                git cherry-pick --abort 2>/dev/null || true
                break
            fi
        fi
    done <<< "$commits"

    if [ "$picked" = "true" ]; then
        git push origin "$DRAFT_BRANCH" >> "$MAIN_LOG" 2>&1 || log "  WARNING: push to $DRAFT_BRANCH failed"
        log "  Cherry-picked to $DRAFT_BRANCH and pushed"
    fi

    git checkout "$current_branch" 2>/dev/null || git checkout master 2>/dev/null
    [ "$stashed" = "true" ] && git stash pop >> "$MAIN_LOG" 2>&1 || true
    [ "$picked" = "true" ]
}

setup_draft_pr() {
    # Find existing draft PR for wip/pending-matches
    local fork_owner
    fork_owner=$(gh api user --jq '.login' 2>/dev/null || git remote get-url origin | sed 's|.*[:/]\([^/]*\)/.*|\1|')

    if git ls-remote --heads origin "$DRAFT_BRANCH" 2>/dev/null | grep -qF "pending-matches"; then
        DRAFT_PR_NUMBER=$(gh pr list --repo "$REPO" --state open \
            --json number,headRefName --jq '.[] | select(.headRefName=="wip/pending-matches") | .number' 2>/dev/null || echo "")
        if [ -n "$DRAFT_PR_NUMBER" ]; then
            log "Resuming draft PR #$DRAFT_PR_NUMBER ($DRAFT_BRANCH)"
            return
        fi
    fi

    # Branch doesn't exist or no PR — create both
    if ! git rev-parse --verify "$DRAFT_BRANCH" >/dev/null 2>&1; then
        git branch "$DRAFT_BRANCH" upstream/master 2>/dev/null
    fi
    git push -u origin "$DRAFT_BRANCH" 2>/dev/null || { log "WARNING: could not push $DRAFT_BRANCH"; return; }

    local body
    body=$(python3 "$HELPERS" draft-pr-body "$DRAFT_STATUS_FILE" 2>/dev/null || echo "## Pending Matches\n(starting...)")
    DRAFT_PR_NUMBER=$(gh pr create --repo "$REPO" --head "$fork_owner:$DRAFT_BRANCH" --draft \
        --title "Match progress" \
        --body "$body" 2>/dev/null | grep -oE '[0-9]+$' || echo "")
    if [ -n "$DRAFT_PR_NUMBER" ]; then
        log "Created draft PR #$DRAFT_PR_NUMBER"
    else
        log "WARNING: could not create draft PR"
    fi
}

setup_draft_pr
# Push cleaned draft PR body (pending entries were cleared above) so that
# github-exclusions doesn't pick up stale "pending" entries from the PR body
draft_pr_update

# Recover work from branches left behind by interrupted runs
recover_interrupted_work() {
    log "Checking for interrupted work..."
    local recovered=0
    local branches
    branches=$(git branch --list 'decomp-*' 'worktree-decomp-*' 2>/dev/null | sed 's/^[+* ]*//' || true)
    if [ -z "$branches" ]; then
        log "  No leftover branches found."
        return 0
    fi
    log "  Found branches: $(echo "$branches" | tr '\n' ' ')"
    while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        # Only care about branches with src/ commits ahead of upstream
        local src_count
        src_count=$(git log --format="%H" upstream/master.."$branch" -- src/ 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        if [ "$src_count" -eq 0 ]; then
            # No src/ work — clean up the branch and worktree
            log "  Cleaning up empty branch $branch"
            cleanup_worktree "$branch"
            git branch -D "$branch" 2>/dev/null || true
            continue
        fi

        # Check if these commits are already on the draft branch
        local new_count=0
        while IFS= read -r sha; do
            [ -z "$sha" ] && continue
            if ! git branch --contains "$sha" 2>/dev/null | grep -qF "$DRAFT_BRANCH"; then
                new_count=$((new_count + 1))
            fi
        done < <(git log --format="%H" upstream/master.."$branch" -- src/ 2>/dev/null)

        if [ "$new_count" -eq 0 ]; then
            log "  Branch $branch: all $src_count src/ commit(s) already on $DRAFT_BRANCH, cleaning up"
            cleanup_worktree "$branch"
            git branch -D "$branch" 2>/dev/null || true
            continue
        fi

        log "  Recovering $branch ($new_count new src/ commit(s))..."
        cherry_pick_to_draft "$branch" || log "  (cherry-pick to draft failed, keeping branch)"

        # Extract function names from commit messages and update status
        # Match both "Decomp funcName" and "decompile funcName" patterns
        while IFS= read -r msg; do
            local func_name
            func_name=$(echo "$msg" | sed -n 's/.*[Dd]ecomp[ile]* \([^ ]*\).*/\1/p')
            [ -z "$func_name" ] && continue
            local src_file
            src_file=$(git log --format="" --name-only upstream/master.."$branch" -- 'src/*.c' 2>/dev/null | head -1 || true)
            draft_pr_set_status "$func_name" "${src_file:-unknown}" "matched" "100% (recovered)" || true
            progress_save "$func_name" "success" || true
            recovered=$((recovered + 1))
        done < <(git log --format="%s" upstream/master.."$branch" -- src/ 2>/dev/null)

        cleanup_worktree "$branch"
        git branch -D "$branch" 2>/dev/null || true
    done <<< "$branches"

    if [ "$recovered" -gt 0 ]; then
        log "  Recovered $recovered function(s) from interrupted runs"
        draft_pr_update || true
    fi
    return 0
}
recover_interrupted_work

while true; do
    if [ "$STOP_REQUESTED" = "true" ]; then
        log "Stopping (user interrupt)."
        break
    fi
    if past_cutoff; then
        log "Past cutoff time, stopping."
        break
    fi

    # 1. Ensure we're on a clean master, synced with upstream
    log "Updating master..."
    git checkout master 2>/dev/null || git checkout main 2>/dev/null
    if git remote get-url upstream >/dev/null 2>&1; then
        log "Fetching upstream..."
        git fetch upstream 2>/dev/null || true
        pre_rebase_head=$(git rev-parse HEAD)
        git rebase upstream/master 2>&1 | tee -a "$MAIN_LOG" || {
            log "WARNING: upstream rebase failed, continuing with current master"
            git rebase --abort 2>/dev/null || true
        }
        # Force-push to fork only if rebase moved HEAD
        if [ "$(git rev-parse HEAD)" != "$pre_rebase_head" ]; then
            git push --force origin master 2>&1 | tee -a "$MAIN_LOG" || log "WARNING: force-push to fork failed"
        fi
    else
        git pull --ff-only 2>/dev/null || true
    fi

    # 2. Build to make sure master is clean
    log "Building master to verify clean state..."
    CURRENT_HEAD=$(git rev-parse HEAD)
    if [ "$CURRENT_HEAD" != "${LAST_BUILT_HEAD:-}" ]; then
        # Check if any source files changed (skip rebuild for script-only changes)
        SOURCE_CHANGED=true
        if [ -n "${LAST_BUILT_HEAD:-}" ]; then
            if ! git diff --name-only "$LAST_BUILT_HEAD" "$CURRENT_HEAD" | grep -qE '\.(c|h|cpp|hpp)$'; then
                SOURCE_CHANGED=false
            fi
        fi
        if [ "$SOURCE_CHANGED" = "true" ]; then
            log "  Running configure.py..."
            python3 configure.py $CONFIGURE_ARGS 2>&1 >> "$MAIN_LOG"
            log "  Running ninja (timeout: ${NINJA_TIMEOUT}s)..."
            if ! run_ninja_with_watchdog; then
                log "  Build failed, retrying with clean state..."
                [ "$IS_WINDOWS" != "true" ] && wineserver -k 2>/dev/null || true
                [ "$IS_WINDOWS" != "true" ] && pkill -9 -f wine-preloader 2>/dev/null || true
                sleep 3
                python3 configure.py $CONFIGURE_ARGS 2>&1 >> "$MAIN_LOG"
                log "  Running ninja (retry)..."
                if ! run_ninja_with_watchdog; then
                    log "ERROR: Master doesn't build clean after retry. Aborting."; exit 1
                fi
            fi
            log "Master builds OK"
        else
            log "  Only non-source files changed, skipping rebuild"
        fi
        LAST_BUILT_HEAD=$CURRENT_HEAD
    else
        log "Master unchanged, skipping rebuild"
    fi

    # 3. Find stubs
    log "Finding stubs..."
    STUBS_JSON=$(python3 scripts/find_stubs.py "${SOURCE_FILES[@]}") || {
        log "ERROR: find_stubs.py failed (exit code $?)"
        log "  Output: $STUBS_JSON"
        exit 1
    }
    STUB_COUNT=$(echo "$STUBS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    log "Found $STUB_COUNT stubs total"

    # 4. Check GitHub for open PRs and issues to avoid conflicts
    log "Checking GitHub for existing work..."
    EXCLUDED=$(python3 "$HELPERS" github-exclusions "$REPO" 2>/dev/null || echo '[]')
    log "Excluded $(echo "$EXCLUDED" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))") functions from open PRs/issues"

    # Collect functions that already have decomp branches (with or without worktree- prefix)
    BRANCH_FUNCS=$(git branch --list 'decomp-*' 'worktree-decomp-*' 2>/dev/null | sed 's/^[+* ]*//' | sed 's/^worktree-//' | sed 's/^decomp-//' | sort -u)

    # 5. Filter stubs: remove excluded, enforce size limit, exclude already-attempted
    TARGETS=$(echo "$STUBS_JSON" | python3 "$HELPERS" filter-stubs "$EXCLUDED" "$BRANCH_FUNCS" "$PROGRESS_FILE" "$BATCH_SIZE" "$DRAFT_STATUS_FILE")

    # 6. Pick the next target(s) to decompile
    BATCH=$(echo "$TARGETS" | python3 -c "
import json, sys
targets = json.load(sys.stdin)
if not targets:
    sys.exit(1)
print(json.dumps(targets))
" 2>/dev/null) || {
        log "No targets to decompile."
        break
    }

    BATCH_COUNT=$(echo "$BATCH" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    FIRST_NAME=$(echo "$BATCH" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['name'])")
    FUNC_FILE=$(echo "$BATCH" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['file'])")

    # Validate FUNC_FILE path
    if [[ "$FUNC_FILE" != src/* ]]; then
        log "  ERROR: FUNC_FILE '$FUNC_FILE' does not start with src/, skipping"
        continue
    fi

    # Derive paths from the file
    ASM_FILE="build/GALE01/asm/${FUNC_FILE#src/}"
    ASM_FILE="${ASM_FILE%.c}.s"
    OBJ_FILE="build/GALE01/${FUNC_FILE%.c}.o"
    COMMIT_PREFIX=$(echo "${FUNC_FILE#src/melee/}" | sed 's|/|_|g' | sed 's|\.c||')
    HEADER_FILE="${FUNC_FILE%.c}.h"

    BRANCH_NAME="decomp-$FIRST_NAME"
    FUNC_LOG="$LOG_DIR/${FIRST_NAME}_$TIMESTAMP.log"

    # Build batch summary for logging
    BATCH_NAMES=$(echo "$BATCH" | python3 -c "import json,sys; [print(f['name'],f['size']) for f in json.load(sys.stdin)]")
    log ""
    if [ "$BATCH_COUNT" -gt 1 ]; then
        log "━━━ Batch of $BATCH_COUNT functions from $(basename "$FUNC_FILE") ━━━"
    fi
    echo "$BATCH_NAMES" | while read -r bname bsize; do
        log "  $bname (${bsize} bytes)"
    done

    # Mark functions as pending in draft PR
    while IFS= read -r pname; do
        draft_pr_set_status "$pname" "$FUNC_FILE" "pending"
    done < <(echo "$BATCH" | python3 -c "import json,sys; [print(f['name']) for f in json.load(sys.stdin)]")
    draft_pr_update

    # Check if branch already exists (local or remote)
    if git rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1 || \
       git ls-remote --heads origin "$BRANCH_NAME" 2>/dev/null | grep -q "$BRANCH_NAME"; then
        log "  Branch $BRANCH_NAME already exists, skipping"
        progress_save "$FIRST_NAME" "skipped"
        continue
    fi

    # Build trimmed context (stubs + nearby examples) instead of full file
    ALL_FUNC_NAMES=$(echo "$BATCH" | python3 -c "import json,sys; print(' '.join(f['name'] for f in json.load(sys.stdin)))")
    # shellcheck disable=SC2086
    CONTEXT_C=$(python3 "$HELPERS" trim-context "$FUNC_FILE" $ALL_FUNC_NAMES 2>/dev/null || cat "$FUNC_FILE" 2>/dev/null || echo "(file not found)")
    CONTEXT_H=$(cat "$HEADER_FILE" 2>/dev/null || echo "(no header)")

    # Build per-function context (asm + m2c for each target)
    FUNC_SECTIONS=""
    while IFS= read -r func_json; do
        fname=$(echo "$func_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
        fsize=$(echo "$func_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['size'])")
        fline=$(echo "$func_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['line'])")

        func_asm=$(python3 "$HELPERS" extract-asm "$ASM_FILE" "$fname" 2>/dev/null || echo "(asm extraction failed)")
        func_m2c=$(python3 -m m2c.main --target ppc-mwcc-c \
            --context "$REPO_ROOT/build/ctx.c" \
            --function "$fname" \
            "$REPO_ROOT/$ASM_FILE" 2>/dev/null || echo "(m2c failed)")

        FUNC_SECTIONS="${FUNC_SECTIONS}
--- $fname ($fsize bytes, stub at line $fline) ---

ASSEMBLY:
$func_asm

m2c DECOMPILATION:
$func_m2c
"
    done < <(echo "$BATCH" | python3 -c "import json,sys; [print(json.dumps(f)) for f in json.load(sys.stdin)]")

    # Resolve callee signatures for all target functions
    # shellcheck disable=SC2086
    CALLEE_SIGS=$(python3 "$REPO_ROOT/scripts/resolve_callees.py" "$ASM_FILE" $ALL_FUNC_NAMES 2>/dev/null || echo "(callee resolution failed)")

    # Resolve SDA float constants from the asm file
    # shellcheck disable=SC2086
    SDA_CONSTANTS=$(python3 "$HELPERS" resolve-sda-constants "$ASM_FILE" $ALL_FUNC_NAMES 2>/dev/null || echo "(no SDA constants)")

    # Extract main struct definition based on module prefix
    MODULE_PREFIX=$(echo "${FUNC_FILE#src/melee/}" | sed 's|/.*||')
    STRUCT_NAME=""
    case "$MODULE_PREFIX" in
        it) STRUCT_NAME="Item" ;;
        ft) STRUCT_NAME="Fighter" ;;
        gr) STRUCT_NAME="Ground" ;;
    esac
    MAIN_STRUCT=""
    if [ -n "$STRUCT_NAME" ]; then
        TYPES_HEADER="src/melee/$MODULE_PREFIX/types.h"
        if [ -f "$TYPES_HEADER" ]; then
            MAIN_STRUCT=$(python3 "$HELPERS" extract-struct "$TYPES_HEADER" "$STRUCT_NAME" 2>/dev/null || echo "")
        fi
    fi

    # mwcc_debug is available for debugging mismatches during iteration

    # Build worktree link commands (junctions on Windows, symlinks on Unix)
    if [ "$IS_WINDOWS" = "true" ]; then
        WORKTREE_LINK_CMDS="export MSYS=winsymlinks:native
   ln -s $REPO_ROOT/orig orig
   ln -s $REPO_ROOT/build build
   ln -s $REPO_ROOT/tools tools
   ln -s $REPO_ROOT/.venv .venv"
    else
        WORKTREE_LINK_CMDS="ln -s $REPO_ROOT/orig orig
   ln -s $REPO_ROOT/build build
   ln -s $REPO_ROOT/tools tools
   ln -s $REPO_ROOT/.venv .venv"
    fi

    # Build the list of all function names for the prompt
    ALL_NAMES_LIST=$(echo "$BATCH" | python3 -c "
import json, sys
for f in json.load(sys.stdin):
    print(f'  - {f[\"name\"]} ({f[\"size\"]} bytes, stub marker /// #{f[\"name\"]} at line {f[\"line\"]})')
")

    # Build optional permuter hint (only included if PERMUTER_PATH is set)
    PERMUTER_HINT=""
    if [ -n "$PERMUTER_PATH" ] && [ -f "$PERMUTER_PATH/permuter.py" ]; then
        PERMUTER_HINT="
   FOR REMAINING REGISTER ALLOCATION DIFFERENCES (90%+ match but still stuck): The decomp-permuter
   can automatically find source mutations that coax the compiler into the right register choices.
   # From the worktree root, import the function (creates nonmatchings/FUNC_NAME/):
   python3 $PERMUTER_PATH/import.py $FUNC_FILE $ASM_FILE
   # Run permuter — stops automatically when score=0 (perfect match):
   timeout $PERMUTER_TIMEOUT python3 $PERMUTER_PATH/permuter.py -j$PERMUTER_JOBS --stop-on-zero nonmatchings/FUNC_NAME/
   # When score=0 is printed, the winning code is in nonmatchings/FUNC_NAME/base.c
   # Diff it against the original to find the minimal change, apply to $FUNC_FILE, verify.
   # Clean up: rm -rf nonmatchings/
   Only use the permuter AFTER exhausting manual approaches — it finds matches mechanically,
   not by understanding. Integrate only the minimal change needed (e.g. one PERM_GENERAL macro)."
    fi

    PROMPT="You are autonomously decompiling functions for the Melee decompilation project.
You must work completely autonomously — no human will intervene.
When prompted to choose between options (e.g. by skills or plan mode), always choose the
recommended option. If no option is marked as recommended, use your best judgment and proceed
immediately — never wait for human input.

IMPORTANT: Before starting work, use the superpowers:brainstorming skill to analyze the task,
then use the superpowers:writing-plans skill to create an implementation plan. Execute the plan
using the superpowers:executing-plans skill. These skills are available via the Skill tool.

TARGETS (decompile ALL of these):
$ALL_NAMES_LIST
FILE: $FUNC_FILE
OBJ: $OBJ_FILE

=== CALLEE SIGNATURES (called functions — no need to grep for these) ===
$CALLEE_SIGS

=== SDA CONSTANTS (float/double values used by these functions) ===
$SDA_CONSTANTS

=== SOURCE FILE (trimmed context with stubs and nearby examples) ===
$CONTEXT_C

=== HEADER FILE ($HEADER_FILE) ===
$CONTEXT_H
$([ -n "$MAIN_STRUCT" ] && printf '\n=== MAIN STRUCT (%s from %s/types.h) ===\n%s' "$STRUCT_NAME" "$MODULE_PREFIX" "$MAIN_STRUCT" || true)

=== PER-FUNCTION ASSEMBLY AND m2c OUTPUT ===
$FUNC_SECTIONS

WORKFLOW:

0. WORKTREE SETUP: You are in a git worktree. First, share dirs from the main repo:
   rm -rf orig build tools .venv
   $WORKTREE_LINK_CMDS
   cp $REPO_ROOT/build.ninja build.ninja
   cp $REPO_ROOT/objdiff.json objdiff.json 2>/dev/null || true
   cp $REPO_ROOT/permuter_settings.toml permuter_settings.toml 2>/dev/null || true
   DO NOT run configure.py — it is already done. Just use ninja to compile after editing.

1. FOR EACH FUNCTION, clean up the m2c output using patterns from the source context:
   - Use gobj->user_data style (not GET_FIGHTER) when nearby functions do
   - Replace hex motion state IDs with ftCo_MS_* enums — BUT VERIFY THE NUMERIC VALUE.
     Count from ftCo_MS_DeadDown=0 in ftCommon/forward.h. A wrong enum is a guaranteed mismatch.
   - Replace unk fields with named fields from ft/types.h
   - Use the correct mv.co.UNION.field (check ftCommon/types.h)
   - m2c \"&~1\" on a byte means clear LSB. In PPC bitfield order, LSB = x_b7 (NOT x_b0!)
   - Check if PAD_STACK(8) is needed by comparing frame sizes in the asm

2. IMPLEMENT: Replace EACH \"/// #FUNC_NAME\" stub marker with your code.
   Update header declarations if they use UNK_RET/UNK_PARAMS.

3. BUILD just the target object: ninja $OBJ_FILE 2>&1 | tail -10
   Do NOT run a bare 'ninja' — it will rebuild everything due to worktree timestamps.
   The build MUST succeed (ninja exit code 0).

4. CHECK MATCH for each function using verify_match.py, which checks BOTH instruction
   bytes AND relocation targets (i.e. that bl instructions call the correct function):
   python3 $REPO_ROOT/scripts/verify_match.py $OBJ_FILE ${OBJ_FILE/src/obj} FUNC_NAME1 FUNC_NAME2 ...
   The OBJ_FILE is your compiled .o; the obj/ path is the expected .o from the original game.
   A function is matched when verify_match.py prints \"OK\". Register swaps are OK.
   A \"RELOC MISMATCH\" means you're calling the wrong function — this MUST be fixed.

5. IF NOT MATCHED: Read the verify_match.py output carefully.
   - \"WRONG TARGET: bl X should be Y\" — you called the wrong function. Fix the call.
   - \"SIZE MISMATCH\" or low match % — compare instruction-by-instruction:
     python3 $REPO_ROOT/scripts/compare_bytes.py $OBJ_FILE FUNC_NAME
     (Do NOT write inline pyelftools scripts — always use compare_bytes.py.)
   Common fixes: wrong enum value, wrong bitfield bit, missing PAD_STACK, wrong inline usage.

   FOR REGISTER ALLOCATION ISSUES: Run the MWCC debug tool to see compiler internals:
     $REPO_ROOT/scripts/mwcc_debug.sh compile $FUNC_FILE
   Then read scripts/mwcc_debug/pcdump_\$(basename $FUNC_FILE .c).txt and search for
   your function. Key passes: AFTER REGISTER COLORING (shows physical register assignment),
   FINAL CODE (what gets emitted). This reveals why the compiler chose specific registers.
$PERMUTER_HINT
6. ITERATE up to 5 times per function. If still not 100%, revert ONLY that function's changes.

7. FOR EACH FUNCTION AT 100% MATCH:
   - Run: git clang-format
   - Stage and commit EACH matched function separately:
     git add $FUNC_FILE \${FUNC_FILE%.c}.h
     git commit -m \"$COMMIT_PREFIX: decompile FUNC_NAME

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>\"

8. FOR FUNCTIONS NOT AT 100%: Revert their changes:
   git checkout -- .

9. OUTPUT: Write results to a file AND print them (the file is the reliable source):
   echo 'CONTEXT: ...' > /tmp/decomp_result.txt
   echo 'RESULTS: ...' >> /tmp/decomp_result.txt
   cat /tmp/decomp_result.txt

   a. A CONTEXT line with 1-2 sentences describing what these functions do IN THE GAME.
      Describe the player-visible behavior — the move, the stage hazard, the menu interaction.
      Do NOT describe the C code, structs, registers, compiler tricks, or decompilation process.
      Write for a Melee player, not a programmer. Examples:
      CONTEXT: Kirby's Final Cutter — transitions from the rising slash to the downward plunge.
      CONTEXT: Goomba enemy on Mushroom Kingdom — initializes patrol direction when spawning.
      CONTEXT: Onett stage — plays collision sound effects when cars hit the road barriers.
   b. A RESULTS line (must be the very last line):
      RESULTS: func1=SUCCESS func2=FAILURE(best=XX.X%) func3=SUCCESS"

    check_usage

    if [ "$USE_TMUX" = "true" ]; then

    # === TMUX MODE: Interactive Claude Code session with skills/plugins ===
    FUNC_STREAM_LOG="$LOG_DIR/${FIRST_NAME}_${TIMESTAMP}_tmux.log"
    : > "$FUNC_STREAM_LOG"
    RATE_LIMITED=false

    TMUX_SESSION="decomp-$(echo "$FIRST_NAME" | tr -cd '[:alnum:]-' | head -c 30)"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    PROMPT_FILE=$(mktemp /tmp/decomp_prompt.XXXXXX)
    printf '%s' "$PROMPT" > "$PROMPT_FILE"

    # Discover installed plugins to forward into tmux sessions
    PLUGIN_ARGS=""
    PLUGIN_CACHE="$HOME/.claude/plugins/cache"
    if [ -d "$PLUGIN_CACHE" ]; then
        for plugin_dir in "$PLUGIN_CACHE"/*/*/*; do
            if [ -d "$plugin_dir" ] && [ -f "$plugin_dir/package.json" ]; then
                PLUGIN_ARGS="$PLUGIN_ARGS --plugin-dir $plugin_dir"
            fi
        done
    fi

    TMUX_WRAPPER=$(mktemp /tmp/decomp_wrapper.XXXXXX)
    cat > "$TMUX_WRAPPER" <<WRAPPER_EOF
#!/bin/bash
unset CLAUDECODE ANTHROPIC_API_KEY
script -q -F "$FUNC_STREAM_LOG" claude \\
    --model "$MODEL" \\
    --permission-mode bypassPermissions \\
    -w "$BRANCH_NAME" \\
    --verbose${PLUGIN_ARGS:+ \\
    $PLUGIN_ARGS}
WRAPPER_EOF
    chmod +x "$TMUX_WRAPPER"

    WT_PROJECT="decomp-${BRANCH_NAME}"

    log "  Starting tmux session: $TMUX_SESSION"
    log "  Attach with: tmux attach -t $TMUX_SESSION"
    tmux new-session -d -s "$TMUX_SESSION" -x 200 -y 50 "$TMUX_WRAPPER"

    # Wait for Claude to fully initialize (plugins, hooks, system reminders)
    log "  Waiting for Claude to initialize..."
    sleep 20 || true

    # Send the prompt via keystrokes — Claude starts in plan mode,
    # will use superpowers to brainstorm/plan, then exit plan mode to execute
    tmux send-keys -t "$TMUX_SESSION" -l "MANDATORY FIRST STEP: Invoke the Skill tool with skill='superpowers:brainstorming' BEFORE doing anything else. This is not optional. After brainstorming, enter plan mode with EnterPlanMode, then read $PROMPT_FILE and write your plan. Exit plan mode and execute. Do NOT skip these steps." || true
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" Enter || true
    log "  Prompt sent to Claude"

    TAIL_PID=""

    # Monitor for completion with clean status output
    TMUX_MIN_RUNTIME=${TMUX_MIN_RUNTIME:-60}
    TMUX_START=$(date +%s)
    LAST_SIZE=0
    LAST_TOOL_COUNT=0
    LAST_MATCH_PCT=""
    IDLE_COUNT=0

    while tmux has-session -t "$TMUX_SESSION" 2>/dev/null; do
        if [ "$STOP_REQUESTED" = "true" ]; then
            tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
            break
        fi

        ELAPSED=$(( $(date +%s) - TMUX_START ))
        CURRENT_SIZE=$(wc -c < "$FUNC_STREAM_LOG" 2>/dev/null || echo 0)

        # Print clean status every 30s when log has grown
        if [ "$CURRENT_SIZE" -ne "$LAST_SIZE" ] && [ $((ELAPSED % 30)) -lt 6 ] && [ "$ELAPSED" -ge 20 ]; then
            # Count tool calls and extract latest match percentage
            STRIPPED=$(perl -pe 's/\e\[\??[0-9;]*[a-zA-Z]//g; s/\e\][^\x07]*\x07//g; s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g' "$FUNC_STREAM_LOG" 2>/dev/null)
            TOOL_COUNT=$(echo "$STRIPPED" | grep -coE '⏺(Bash|Read|Edit|Write|Search|Grep|Glob|Agent|Skill)' 2>/dev/null || echo 0)
            MATCH_PCT=$(echo "$STRIPPED" | grep -oE '[0-9]+\.[0-9]+%' 2>/dev/null | tail -1 || true)
            TOKENS=$(echo "$STRIPPED" | grep -oE '[0-9]+tokens' 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)

            if [ "$TOOL_COUNT" -ne "$LAST_TOOL_COUNT" ]; then
                STATUS="  ${ELAPSED}s elapsed, ${TOOL_COUNT} tool calls"
                [ -n "$TOKENS" ] && STATUS="$STATUS, ${TOKENS} tokens"
                [ -n "$MATCH_PCT" ] && STATUS="$STATUS, last match: ${MATCH_PCT}"
                log "$STATUS"
                LAST_TOOL_COUNT=$TOOL_COUNT
            fi
        fi

        # Auto-approve plan mode exit prompts ("Would you like to proceed?")
        if [ "$ELAPSED" -ge "$TMUX_MIN_RUNTIME" ]; then
            PANE_TEXT=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null || true)
            if echo "$PANE_TEXT" | grep -q "Would you like to proceed"; then
                log "  Plan ready, auto-approving execution..."
                tmux send-keys -t "$TMUX_SESSION" Enter 2>/dev/null || true
            fi
        fi

        # Only check for RESULTS after minimum runtime (prompt echoes the template)
        if [ "$ELAPSED" -ge "$TMUX_MIN_RUNTIME" ]; then
            if sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g; s/\x1b\\[[0-9;]*[mK]//g' \
                    "$FUNC_STREAM_LOG" 2>/dev/null | grep -q "^RESULTS:"; then
                log "  Results detected, giving Claude 30s to finish..."
                sleep 30
                tmux send-keys -t "$TMUX_SESSION" "/exit" Enter 2>/dev/null || true
                sleep 5
                tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
                break
            fi
        fi

        # Idle timeout: no new output for TMUX_IDLE_TIMEOUT seconds
        # (only after min runtime to avoid killing during prompt loading)
        if [ "$ELAPSED" -ge "$TMUX_MIN_RUNTIME" ]; then
            if [ "$CURRENT_SIZE" -eq "$LAST_SIZE" ]; then
                IDLE_COUNT=$((IDLE_COUNT + 1))
            else
                IDLE_COUNT=0
                LAST_SIZE=$CURRENT_SIZE
            fi
            if [ $((IDLE_COUNT * 5)) -ge "$TMUX_IDLE_TIMEOUT" ]; then
                log "  No output for ${TMUX_IDLE_TIMEOUT}s, assuming done"
                tmux send-keys -t "$TMUX_SESSION" "/exit" Enter 2>/dev/null || true
                sleep 5
                tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
                break
            fi
        fi

        # Hard timeout
        if [ "$ELAPSED" -ge "$TMUX_HARD_TIMEOUT" ]; then
            log "  Hard timeout (${TMUX_HARD_TIMEOUT}s), killing session"
            tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
            break
        fi

        sleep 5
    done

    [ -n "$TAIL_PID" ] && kill $TAIL_PID 2>/dev/null || true

    CLAUDE_EXIT=0
    rm -f "$PROMPT_FILE" "$TMUX_WRAPPER"
    log "  tmux session ended"

    # LLM-review worktree observations: keep only useful decomp knowledge
    CLAUDE_MEM_DB="$HOME/.claude-mem/claude-mem.db"
    if [ -f "$CLAUDE_MEM_DB" ]; then
        OBS_COUNT=$(sqlite3 "$CLAUDE_MEM_DB" "SELECT COUNT(*) FROM observations WHERE project = '$WT_PROJECT';" 2>/dev/null || echo 0)
        if [ "$OBS_COUNT" -gt 0 ]; then
            OBS_JSON=$(sqlite3 -json "$CLAUDE_MEM_DB" "
                SELECT id, title, type, files_modified FROM observations WHERE project = '$WT_PROJECT';
            " 2>/dev/null)
            REVIEW_PROMPT="You are reviewing observations from a Melee decompilation session for the function ${FUNC_NAME}.
These observations were recorded by an AI assistant during the session. Most are noise.

KEEP observations about:
- Struct/type layouts, field offsets, type definitions discovered
- Match strategies (PAD_STACK, register tricks, compiler quirks)
- Function signatures and calling conventions discovered
- Patterns reusable across future decompilations

DISCARD observations about:
- Build/infrastructure issues (wine, wibo, ninja, configure)
- Commit confirmations, git operations
- Plan creation/update notices
- Meta-observations about tooling or workflow
- Observations about files outside src/melee/

Return ONLY a JSON array of integer IDs to keep. If none are worth keeping, return [].
Example: [742, 745]

Observations:
${OBS_JSON}"
            KEEP_IDS=$(echo "$REVIEW_PROMPT" | claude -p --model haiku 2>/dev/null | grep -o '\[.*\]' | head -1)
            if [ -n "$KEEP_IDS" ] && [ "$KEEP_IDS" != "[]" ]; then
                # Convert JSON array [1,2,3] to SQL IN list (1,2,3)
                SQL_IDS=$(echo "$KEEP_IDS" | tr -d '[]' | tr -s ' ')
                MERGED=$(sqlite3 "$CLAUDE_MEM_DB" "
                    UPDATE observations SET project = 'melee'
                    WHERE project = '$WT_PROJECT' AND id IN ($SQL_IDS);
                    SELECT changes();
                " 2>/dev/null || echo 0)
                [ "$MERGED" -gt 0 ] && log "  [claude-mem] Kept $MERGED/$OBS_COUNT observations (LLM-reviewed)"
            else
                log "  [claude-mem] Discarded all $OBS_COUNT observations (LLM-reviewed)"
            fi
            # Delete remaining worktree observations
            sqlite3 "$CLAUDE_MEM_DB" "
                DELETE FROM observations WHERE project = '$WT_PROJECT';
            " 2>/dev/null || true
        fi
    fi

    # Strip ANSI codes for readable log
    sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g; s/\x1b\\[[0-9;]*[mK]//g' \
        "$FUNC_STREAM_LOG" > "$FUNC_LOG" 2>/dev/null || cp "$FUNC_STREAM_LOG" "$FUNC_LOG"
    log "  [tokens] (not available in tmux mode)"

    else

    # === HEADLESS MODE: claude -p with stream-json ===
    log "  Spawning Claude session..."
    FUNC_STREAM_LOG="$LOG_DIR/${FIRST_NAME}_${TIMESTAMP}_stream.jsonl"

    MAX_RETRIES=5
    RETRY=0
    BACKOFF=120  # start at 2 minutes
    RATE_LIMITED=false

    while true; do
        set +e
        log "  Claude session started..."

        # Run claude in background so Ctrl+C reaches the script
        DONE_FLAG=$(mktemp /tmp/decomp_done.XXXXXX)
        rm -f "$DONE_FLAG"
        env -u CLAUDECODE -u ANTHROPIC_API_KEY claude -p \
            --model "$MODEL" \
            --permission-mode bypassPermissions \
            --verbose --output-format stream-json \
            -w "$BRANCH_NAME" \
            "$PROMPT" > "$FUNC_STREAM_LOG" 2>&1 &
        CLAUDE_PID=$!
        track_pid $CLAUDE_PID

        # Stream live summaries while claude runs; writes done flag on result event
        python3 -u "$HELPERS" stream-monitor "$FUNC_STREAM_LOG" "$CLAUDE_PID" "$DONE_FLAG" &
        MONITOR_PID=$!
        track_pid $MONITOR_PID

        # Wait for claude, but kill it if result event arrives and it keeps running
        GOT_RESULT=false
        while kill -0 $CLAUDE_PID 2>/dev/null; do
            if [ -f "$DONE_FLAG" ]; then
                GOT_RESULT=true
                log "  Result received, giving Claude 10s to finish..."
                sleep 10
                if kill -0 $CLAUDE_PID 2>/dev/null; then
                    log "  Killing Claude (still running after result)"
                    kill $CLAUDE_PID 2>/dev/null
                    pkill -P $CLAUDE_PID 2>/dev/null
                fi
                break
            fi
            sleep 1
        done
        wait $CLAUDE_PID 2>/dev/null
        CLAUDE_EXIT=$?
        kill $MONITOR_PID 2>/dev/null; wait $MONITOR_PID 2>/dev/null
        rm -f "$DONE_FLAG"
        set -e
        log "  Claude session exited (code: $CLAUDE_EXIT)"

        # Skip rate limit check if we already got a result event — a 529 mid-session
        # shouldn't trigger a retry when the session actually completed successfully
        if [ "$GOT_RESULT" = "true" ]; then
            log "  (result event received, skipping rate limit check)"
            break
        fi

        # Check for rate limit in output (exclude normal status:"allowed" events)
        if grep -v '"status":"allowed"' "$FUNC_STREAM_LOG" 2>/dev/null | grep -qi "hit your limit\|rate.limit\|resets [0-9]"; then
            RETRY=$((RETRY + 1))
            if [ "$RETRY" -gt "$MAX_RETRIES" ]; then
                log "  Rate limited $MAX_RETRIES times, giving up"
                RATE_LIMITED=true
                break
            fi
            RESET_WAIT=$(python3 "$HELPERS" parse-rate-limit "$FUNC_STREAM_LOG" "$BACKOFF" 2>/dev/null || echo "$BACKOFF")
            log "  Rate limited (attempt $RETRY/$MAX_RETRIES). Sleeping ${RESET_WAIT}s until reset..."
            sleep "$RESET_WAIT"
            BACKOFF=$((BACKOFF * 2))
            # Clean up failed worktree before retry
            cleanup_worktree "$BRANCH_NAME"
            git branch -D "$BRANCH_NAME" 2>/dev/null || true
            git branch -D "worktree-$BRANCH_NAME" 2>/dev/null || true
            continue
        fi
        break
    done

    # Extract readable log from stream
    python3 "$HELPERS" extract-log "$FUNC_STREAM_LOG" "$FUNC_LOG" 2>/dev/null || true

    # Sum token usage
    FUNC_TOKENS=$(python3 "$HELPERS" token-usage "$FUNC_STREAM_LOG" 2>/dev/null || echo "tokens=unknown")
    log "  [tokens] $FUNC_TOKENS"

    fi # end USE_TMUX

    # Ctrl+C during Claude session: clean up and exit gracefully
    if [ "$STOP_REQUESTED" = "true" ]; then
        log "  Interrupted by user, cleaning up..."
        cleanup_worktree "$BRANCH_NAME"
        git branch -D "$BRANCH_NAME" 2>/dev/null || true
        git branch -D "worktree-$BRANCH_NAME" 2>/dev/null || true
        while IFS= read -r fname; do
            draft_pr_set_status "$fname" "$FUNC_FILE" "failed" "interrupted" || true
        done < <(echo "$BATCH" | python3 -c "import json,sys; [print(f['name']) for f in json.load(sys.stdin)]")
        draft_pr_update || true
        break
    fi

    # Skip result parsing if we were rate limited — don't save progress so it's retried
    if [ "$RATE_LIMITED" = "true" ]; then
        log "  Skipped (rate limited), will retry next run"
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
        # Remove pending entries for this batch
        while IFS= read -r fname; do
            draft_pr_set_status "$fname" "$FUNC_FILE" "failed" "rate limited"
        done < <(echo "$BATCH" | python3 -c "import json,sys; [print(f['name']) for f in json.load(sys.stdin)]")
        draft_pr_update
        continue
    fi

    # Parse result
    if [ "$USE_TMUX" = "true" ]; then
        RESULT_LINE=$(parse_text_result "$FUNC_STREAM_LOG")
    else
        RESULT_LINE=$(python3 "$HELPERS" parse-result "$FUNC_STREAM_LOG" 2>/dev/null || echo "status=error")
    fi
    RESULT_STATUS=$(echo "$RESULT_LINE" | sed -n 's/^status=//p' | head -1)
    RESULT_CONTEXT=$(echo "$RESULT_LINE" | sed -n 's/^context=//p' | head -1)

    if [ "$RESULT_STATUS" = "success" ]; then
        log "  ✓ SUCCESS!"

        # Find the worktree branch (claude --worktree prefixes with "worktree-")
        WT_BRANCH=$(git branch --list "*${BRANCH_NAME}*" 2>/dev/null | grep -v '^\*' | head -1 | sed 's/^[+* ]*//' || echo "$BRANCH_NAME")
        if [ -n "$WT_BRANCH" ] && [ "$AUTO_PUSH" = "true" ]; then
            log "  Pushing branch $WT_BRANCH..."
            git push -u origin "$WT_BRANCH" 2>&1 | tail -2 | tee -a "$MAIN_LOG"

            # Derive PR title from source file basename
            FILE_BASENAME=$(basename "$FUNC_FILE" .c)
            if [ "$BATCH_COUNT" -gt 1 ]; then
                PR_TITLE="$FILE_BASENAME: match $BATCH_COUNT functions"
                PR_FUNCS=$(echo "$BATCH" | python3 -c "import json,sys; print('\n'.join(f'- \`{f[\"name\"]}\` ({f[\"size\"]} bytes)' for f in json.load(sys.stdin)))")
            else
                PR_TITLE="$FILE_BASENAME: match $FIRST_NAME"
                PR_FUNCS="- \`$FIRST_NAME\` — 100% match"
            fi

            # Build optional game context section
            PR_CONTEXT=""
            if [ -n "$RESULT_CONTEXT" ]; then
                PR_CONTEXT="
## What these functions do
$RESULT_CONTEXT
"
            fi

            log "  Creating PR..."
            PR_URL=$(gh pr create \
                --repo "$REPO" \
                --head "$WT_BRANCH" \
                --title "$PR_TITLE" \
                --body "$(cat <<EOF
## Summary
$PR_FUNCS

## Verification
- \`main.dol: OK\` (SHA1 verified)
- \`fuzzy_match_percent: 100.0\`
${PR_CONTEXT}
🤖 Generated with [Claude Code](https://claude.ai/claude-code)
EOF
)" 2>&1) || PR_URL="(PR creation failed)"
            log "  PR: $PR_URL"
        elif [ -n "$WT_BRANCH" ]; then
            log "  Branch ready: $WT_BRANCH (push with: git push -u origin $WT_BRANCH)"
        fi
        # Clean up worktree (branch with commit persists)
        cleanup_worktree "$BRANCH_NAME"

        # Cherry-pick matched commits onto the draft PR branch
        if [ -n "$WT_BRANCH" ]; then
            if cherry_pick_to_draft "$WT_BRANCH"; then
                # Clean up the per-function branch now that commits are on wip/pending-matches
                git branch -D "$WT_BRANCH" 2>/dev/null || true
                # Create draft PR now if it wasn't created earlier (wip/pending-matches now has commits)
                [ -z "$DRAFT_PR_NUMBER" ] && setup_draft_pr
            else
                log "  Keeping branch $WT_BRANCH (cherry-pick failed — PR manually or next run)"
            fi
        fi

        BATCH_SUCCESSES=0
        BATCH_FAILURES=0
        while IFS= read -r fname; do
            if [ "$(get_func_result "$fname")" = "success" ]; then
                progress_save "$fname" "success"
                draft_pr_set_status "$fname" "$FUNC_FILE" "matched" "100%" "$RESULT_CONTEXT"
                BATCH_SUCCESSES=$((BATCH_SUCCESSES + 1))
            else
                progress_save "$fname" "failure"
                draft_pr_set_status "$fname" "$FUNC_FILE" "failed" "partial batch"
                BATCH_FAILURES=$((BATCH_FAILURES + 1))
            fi
        done < <(echo "$BATCH" | python3 -c "import json,sys; [print(f['name']) for f in json.load(sys.stdin)]")
        TOTAL_SUCCESSES=$((TOTAL_SUCCESSES + BATCH_SUCCESSES))
        TOTAL_FAILURES=$((TOTAL_FAILURES + BATCH_FAILURES))
        draft_pr_update
    else
        BEST=$(echo "$RESULT_LINE" | sed -n 's/.*best=//p' || true)
        if [ -n "$BEST" ]; then
            log "  ✗ FAILED (best: ${BEST}%)"
        else
            log "  ✗ FAILED (no results — session timed out or crashed)"
        fi
        # Clean up worktree and branch
        cleanup_worktree "$BRANCH_NAME"
        git branch -D "$BRANCH_NAME" 2>/dev/null || true
        TOTAL_FAILURES=$((TOTAL_FAILURES + BATCH_COUNT))
        while IFS= read -r fname; do
            progress_save "$fname" "failure"
            draft_pr_set_status "$fname" "$FUNC_FILE" "failed" "best ${BEST}%"
        done < <(echo "$BATCH" | python3 -c "import json,sys; [print(f['name']) for f in json.load(sys.stdin)]")
        draft_pr_update
    fi

    log "  Log: $FUNC_LOG"

    # Kill any lingering child processes before next iteration
    kill_children

    if [ "$CONTINUOUS" != "true" ]; then
        break
    fi
done

log ""
log "━━━━━━━━━━━━━━━━━━━━━"
log "TOTAL RESULTS: $TOTAL_SUCCESSES succeeded, $TOTAL_FAILURES failed"
log "Progress file: $PROGRESS_FILE"
log "Log dir: $LOG_DIR"
if [ -n "$DRAFT_PR_NUMBER" ]; then
    # Final update with all results
    draft_pr_update
    log "Draft PR: https://github.com/$REPO/pull/$DRAFT_PR_NUMBER"
fi
