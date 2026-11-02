# build-ui.sh — terminal dashboard for the build scripts (zero dependencies, bash 3.2 OK).
#
# Draws a bottom-anchored dashboard while long steps run:
#
#   FineWine — CrossOver 26.3.0 Wine (x86_64) · elapsed 4:02
#     ✓ deps       0:07
#     ✓ fetch      1:42
#     ▶ build      Building Wine modules (make -j10)  ▕███████░░░░░░░░░░░░░░░░░░░▏ ~18% · 372/2056 lines
#     · package
#   ┌─ tail: make -j10 — build/build.log ──────────────────────────────────────────
#   │ clang -arch x86_64 -m64 -c -o dlls/ntdll/ntdll.o .../ntdll.c -Iinclude ...
#   │ clang -arch x86_64 -m64 -c -o dlls/ntdll/unix/loader.o ...
#   │ ...
#   └──────────────────────────────────────────────────────────────────────────────
#   ▕██████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▏  22% · elapsed 4:02 · eta ~14:20
#
# Real progress is shown wherever it is measurable, and an honest spinner
# otherwise. On completion the dashboard collapses to a single "✓ step (time)"
# line in the scrollback, so the transcript stays clean.
#
# Integration (see scripts/build-wine.sh for a worked example):
#
#   UI_SELF="$0"                       # must precede sourcing (zsh handoff, below)
#   . "$REPO/scripts/lib/build-ui.sh"
#   ui_init "FineWine — title"                       # once, before any step
#   ui_begin <label> <weight> <description>          # at the start of each step
#   ui_run <logfile> <sublabel> cmd args...          # long command, logged + pane
#   ui_end                                           # closes the step (✓ line)
#   ui_finish                                        # once, on success
#
# ui_run captures the command's output into <logfile> (plain mode also tees it
# to the terminal, exactly like the previous `... 2>&1 | tee logfile` wiring).
# The scripts keep printing their own summary lines, which appear after the
# dashboard collapses.
#
# Per-step progress knobs (plain globals; all optional; reset automatically):
#   UI_PROBE_FILE=<path> UI_PROBE_TOTAL=<bytes>   poll a growing file (downloads)
#   UI_LINES_TOTAL=<n> [UI_LINES_RE=<ere>]        percent from log line counts;
#                                                 without a total, the count is
#                                                 still shown next to a spinner
#   ui_progress <cur> <total>                     direct percent (main-shell loops)
#   ui_learn <file> <count>                       persist a line total between runs
#                                                 (e.g. lines of a successful make)
#
# Degrades gracefully: when stdout is not a TTY (GitHub Actions, pipes) or
# NO_UI=1, every call degrades to the plain "==> …" lines and tee, so CI logs
# stay complete and grep-able. Nothing here changes exit-code semantics: ui_run
# returns the command's status, and failures still abort the caller.
#
# Zsh support: the scripts are bash, and their `#!/usr/bin/env bash` shebang
# already runs them under bash when invoked normally (./scripts/build-wine.sh),
# no matter which shell the terminal runs. The one broken path is forcing
# another interpreter (e.g. `zsh scripts/build-wine.sh`): instead of failing on
# bash-isms mid-run, the guard below transparently re-executes the script under
# /bin/bash, so that invocation works identically. Sourcing this library from a
# non-bash shell fails with a pointed error rather than subtle corruption.
#
# The caller must set UI_SELF="$0" before sourcing (needed because zsh changes
# $0 to the sourced file's path inside `source`, so the library cannot recover
# the calling script's path on its own).

# Any non-bash shell (zsh, ksh, …): hand the script over to /bin/bash.
if [ -z "${BASH_VERSION:-}" ]; then
  if [ -n "${UI_SELF:-}" ] && [ -f "$UI_SELF" ]; then
    exec /bin/bash "$UI_SELF" "$@"
  fi
  printf 'error: %s is bash-only — run the script directly (./scripts/…); its\n       shebang selects bash. Sourcing it into zsh is not supported.\n' \
    "${0:-build-ui.sh}" >&2
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------- state ----
UI_ACTIVE=0
UI_TITLE=""
UI_T0=0                 # epoch at ui_init
UI_H=0                  # dashboard height currently on screen (0 = not drawn)
UI_PID=""               # running ui_run child
UI_LOG=""               # current step's log file (tail pane)
UI_SUB=""               # current sub-label (pane header)
UI_STEP=-1              # index of the running step, -1 = none
UI_FRAME_N=0            # frame counter (spinner phase)
UI_N=0                  # number of registered steps
UI_LBL=() UI_W=() UI_ST=() UI_TM=() UI_TB=() UI_DESC=()   # checklist (parallel arrays)
UI_L=() UI_LN=0         # frame lines being rendered
UI_COLS=100 UI_ROWS=30
UI_UTF8=1
UI_TAIL_N=6             # log-pane height
UI_FRAME=0.12           # seconds between frames
UI_GRACE=0.3            # skip the dashboard entirely for commands faster than this

# per-step progress knobs (see header)
UI_PCT_CUR="" UI_PCT_TOT=""
UI_PROBE_FILE="" UI_PROBE_TOTAL=0
UI_LINES_RE="" UI_LINES_TOTAL=0
UI_SPCT="" UI_SDET=""   # computed per frame by _ui_step_pct

# ANSI
UI_R=$'\033[0m' UI_B=$'\033[1m' UI_D=$'\033[2m'
UI_GRN=$'\033[32m' UI_RED=$'\033[31m' UI_CYN=$'\033[36m' UI_GRY=$'\033[90m'
UI_CR=$'\r' UI_TAB=$'\t'          # pre-assigned: bash 3.2 ignores $'..' inside ${var//..}

# ------------------------------------------------------------- helpers ----
_ui_add() { UI_L[UI_LN]="$1"; UI_LN=$((UI_LN + 1)); }

_ui_rep() { # char n -> repeated string on stdout
  local o="" i=0
  while [ $i -lt "$2" ]; do o="$o$1"; i=$((i + 1)); done
  printf '%s' "$o"
}

_ui_trunc() { # string maxlen -> truncated (with ellipsis) on stdout
  local s="$1" n="$2"
  [ "$n" -ge 4 ] || n=4
  if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$((n - 1))}"; else printf '%s' "$s"; fi
}

_ui_fmt_t() { # seconds -> m:ss
  local s=${1:-0}
  [ "$s" -ge 0 ] || s=0
  printf '%d:%02d' $((s / 60)) $((s % 60))
}

_ui_c() { # status -> status character (ASCII fallback in non-UTF-8 locales)
  if [ "$UI_UTF8" = 1 ]; then
    case $1 in
      ok) printf '✓' ;; fail) printf '✗' ;; run) printf '▶' ;; skip) printf '—' ;; *) printf '·' ;;
    esac
  else
    case $1 in
      ok) printf 'done' ;; fail) printf 'FAIL' ;; run) printf '>' ;; skip) printf '-' ;; *) printf '.' ;;
    esac
  fi
}

_ui_spin() { # frame -> spinner character
  if [ "$UI_UTF8" = 1 ]; then
    case $(($1 % 8)) in
      0) printf '⠋' ;; 1) printf '⠙' ;; 2) printf '⠹' ;; 3) printf '⠸' ;;
      4) printf '⠼' ;; 5) printf '⠴' ;; 6) printf '⠦' ;; 7) printf '⠧' ;;
    esac
  else
    case $(($1 % 4)) in 0) printf '|' ;; 1) printf '/' ;; 2) printf '-' ;; 3) printf '\' ;;
    esac
  fi
}

_ui_bar() { # pct width -> bar on stdout
  local pct=$1 w=$2 fill empty i
  [ "$w" -ge 4 ] || w=4
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  fill=$((pct * w / 100)); empty=$((w - fill))
  if [ "$UI_UTF8" = 1 ]; then
    printf '▕'
    i=0; while [ $i -lt $fill ]; do printf '█'; i=$((i + 1)); done
    i=0; while [ $i -lt $empty ]; do printf '░'; i=$((i + 1)); done
    printf '▏'
  else
    printf '['
    i=0; while [ $i -lt $fill ]; do printf '#'; i=$((i + 1)); done
    i=0; while [ $i -lt $empty ]; do printf '.'; i=$((i + 1)); done
    printf ']'
  fi
}

_ui_size() { # refresh UI_COLS / UI_ROWS from the terminal
  local sz
  if sz=$(stty size </dev/tty 2>/dev/null) && [ -n "$sz" ]; then
    UI_ROWS=${sz% *}; UI_COLS=${sz#* }
  fi
  case "$UI_COLS" in ''|*[!0-9]*|0) UI_COLS=100 ;; esac
  case "$UI_ROWS" in ''|*[!0-9]*|0) UI_ROWS=30 ;; esac
}
_ui_num() { # varname — force the variable to a non-negative integer
  eval "case \"\${$1:-}\" in ''|*[!0-9]*) $1=0 ;; esac"
  return 0
}

# percent + detail for the running step: sets UI_SPCT (0-99 or empty when
# indeterminate) and UI_SDET (short human detail, may be empty). Priority:
# ui_progress > byte probe > line count.
_ui_step_pct() {
  local p det=""
  UI_SPCT=""; UI_SDET=""
  _ui_num UI_PCT_CUR; _ui_num UI_PCT_TOT; _ui_num UI_PROBE_TOTAL; _ui_num UI_LINES_TOTAL
  if [ -n "$UI_PCT_CUR" ] && [ "$UI_PCT_TOT" -gt 0 ]; then
    p=$((UI_PCT_CUR * 100 / UI_PCT_TOT)); det="$UI_PCT_CUR/$UI_PCT_TOT"
  elif [ -n "$UI_PROBE_FILE" ] && [ -f "$UI_PROBE_FILE" ] && [ "$UI_PROBE_TOTAL" -gt 0 ]; then
    local sz; sz=$(wc -c < "$UI_PROBE_FILE" 2>/dev/null | tr -d ' \n') || sz=0
    _ui_num sz
    p=$((sz * 100 / UI_PROBE_TOTAL))
    if [ "$UI_PROBE_TOTAL" -ge 1048576 ]; then
      det="$(printf '%d/%d MB' $((sz / 1048576)) $((UI_PROBE_TOTAL / 1048576)))"
    else
      det="$(printf '%d/%d KB' $((sz / 1024)) $((UI_PROBE_TOTAL / 1024)))"
    fi
  elif [ -n "$UI_LOG" ] && [ "$UI_LINES_TOTAL" -gt 0 ]; then
    local n=0
    if [ -n "$UI_LINES_RE" ]; then
      n=$(grep -c -e "$UI_LINES_RE" "$UI_LOG" 2>/dev/null) || n=0
    else
      n=$(wc -l < "$UI_LOG" 2>/dev/null | tr -d ' \n') || n=0
    fi
    _ui_num n
    p=$((n * 100 / UI_LINES_TOTAL)); det="$n/$UI_LINES_TOTAL lines"
  else
    return 0   # indeterminate: no percent
  fi
  [ "$p" -gt 99 ] && p=99
  [ "$p" -lt 0 ] && p=0
  UI_SPCT=$p
  UI_SDET="$det"
  return 0
}

_ui_reset_knobs() {
  UI_PCT_CUR=""; UI_PCT_TOT=""
  UI_PROBE_FILE=""; UI_PROBE_TOTAL=0
  UI_LINES_RE=""; UI_LINES_TOTAL=0
  return 0
}

# --------------------------------------------------------------- render ----
ui_render() { # redraw the UI_L lines over the previous frame (bottom-anchored)
  local n=$UI_LN i
  if [ "$UI_H" -eq 0 ]; then
    for ((i = 0; i < n; i++)); do
      if [ $i -lt $((n - 1)) ]; then printf '%s\n' "${UI_L[i]}"; else printf '%s' "${UI_L[i]}"; fi
    done
  else
    printf '\033[%dA' $((UI_H - 1))
    for ((i = 0; i < n; i++)); do
      printf '\r\033[K%s' "${UI_L[i]}"
      [ $i -lt $((n - 1)) ] && printf '\n'
    done
    if [ "$n" -lt "$UI_H" ]; then   # region shrank: clear the leftover lines
      for ((i = n; i < UI_H; i++)); do
        printf '\r\033[K'
        [ $i -lt $((UI_H - 1)) ] && printf '\n'
      done
    fi
  fi
  UI_H=$n
  return 0
}

ui_clear_dash() { # erase the dashboard, then collapse the freed rows upward (DL)
  local i
  if [ "$UI_H" -gt 0 ]; then
    printf '\033[%dA' $((UI_H - 1))
    for ((i = 0; i < UI_H; i++)); do
      printf '\r\033[K'
      [ $i -lt $((UI_H - 1)) ] && printf '\n'
    done
    # Reclaim the H-1 blank rows above the cursor so the transcript shows only
    # the "✓ step" lines instead of holes (ECMA-48 Delete Line; ignored by any
    # terminal that does not implement it). UI_NO_RECLAIM=1 disables this.
    if [ "${UI_NO_RECLAIM:-0}" != "1" ] && [ "$UI_H" -gt 1 ]; then
      printf '\033[%dA' $((UI_H - 1))
      for ((i = 0; i < UI_H - 1; i++)); do printf '\033[M'; done
      printf '\r'
    fi
    UI_H=0
  fi
  return 0
}

ui_draw() {
  _ui_size
  local cols=$UI_COLS rows=$UI_ROWS
  local now; now=$(date +%s)
  local el=$((now - UI_T0))
  _ui_step_pct
  local sp=$UI_SPCT spd=$UI_SDET

  # overall percent: completed steps count fully, the running step by its pct
  local total_w=0 done_w=0 i
  for ((i = 0; i < UI_N; i++)); do
    total_w=$((total_w + ${UI_W[i]}))
    case "${UI_ST[i]}" in
      ok)  done_w=$((done_w + ${UI_W[i]})) ;;
      run) done_w=$((done_w + ${UI_W[i]} * ${sp:-0} / 100)) ;;
    esac
  done
  local opct=0
  [ "$total_w" -gt 0 ] && opct=$((done_w * 100 / total_w))
  [ "$opct" -gt 100 ] && opct=100

  UI_LN=0
  # 1 — title
  _ui_add "$(printf '%s  %s%s%s  %s· elapsed %s%s' \
    "$UI_B" "$UI_CYN" "$( _ui_trunc "$UI_TITLE" $((cols - 30)) )" "$UI_R" \
    "$UI_GRY" "$( _ui_fmt_t "$el" )" "$UI_R")"

  # 2 — step checklist
  local maxl=0 lbl
  for ((i = 0; i < UI_N; i++)); do
    [ "${#UI_LBL[i]}" -gt "$maxl" ] && maxl=${#UI_LBL[i]}
  done
  for ((i = 0; i < UI_N; i++)); do
    lbl=$(printf '%-*s' "$maxl" "${UI_LBL[i]}")
    case "${UI_ST[i]}" in
      ok)
        _ui_add "$(printf '  %s%s%s %s%s  %s%s%s' \
          "$UI_GRN" "$( _ui_c ok )" "$UI_R" "$UI_GRY" "$lbl" \
          "$UI_GRY" "$( _ui_fmt_t "${UI_TM[i]}" )" "$UI_R")"
        ;;
      fail)
        _ui_add "$(printf '  %s%s%s %s%s%s' \
          "$UI_RED" "$( _ui_c fail )" "$UI_R" "$UI_RED" "$lbl" "$UI_R")"
        ;;
      skip)
        _ui_add "$(printf '  %s%s %s%s  %sskipped%s' \
          "$UI_GRY" "$( _ui_c skip )" "$lbl" "$UI_D" "$UI_R" "$UI_R")"
        ;;
      run)
        local bar det="" descw
        # width budget: 2 indent + "▶ " + label + desc + 2 + bar+pct + det ≤ cols-1
        local bw=$((cols - maxl - 60))
        [ "$bw" -ge 8 ] || bw=8
        [ "$bw" -le 30 ] || bw=30
        descw=$((cols - maxl - bw - 31))
        [ "$descw" -ge 8 ] || descw=8
        if [ -n "$sp" ]; then
          bar="$( _ui_bar "$sp" "$bw" ) ${sp}%"
        else
          bar="$( _ui_spin "$UI_FRAME_N" )"
        fi
        [ -n "$spd" ] && det="$(printf ' %s· %s%s' "$UI_GRY" "$( _ui_trunc "$spd" 16 )" "$UI_R")"
        _ui_add "$(printf '  %s%s%s%s %s%s%s' \
          "$UI_CYN$UI_B" "$( _ui_c run )" "$UI_R" "$UI_CYN" "$lbl" "$UI_R" \
          "$UI_D" "$( _ui_trunc "${UI_DESC[i]}" "$descw" )" "$UI_R")  $bar$det"
        ;;
      *)
        _ui_add "$(printf '  %s%s %s%s%s' \
          "$UI_GRY" "$( _ui_c pend )" "$lbl" "$UI_D" "$UI_R")"
        ;;
    esac
  done

  # 3 — log tail pane ("small sub-section with the logs scrolling up")
  local maxtn=$((rows - UI_N - 6))
  [ "$maxtn" -ge 2 ] || maxtn=2
  local tn=$UI_TAIL_N
  [ "$tn" -le "$maxtn" ] || tn=$maxtn
  local head="tail: ${UI_SUB:-step} — $UI_LOG"
  head=$( _ui_trunc "$head" $((cols - 12)) )
  # "  ┌─ " + head + " " + fill must stay ≤ cols-1 (wrapping would break the redraw)
  local fill=$((cols - 7 - ${#head}))
  [ "$fill" -ge 1 ] || fill=1
  _ui_add "$(printf '  %s┌─ %s %s%s' "$UI_GRY" "$head" "$( _ui_rep '─' "$fill" )" "$UI_R")"
  local line shown=0
  if [ -s "$UI_LOG" ]; then
    while IFS= read -r line; do
      line=${line//$UI_CR/}; line=${line//$UI_TAB/  }
      _ui_add "$(printf '  %s│%s %s' "$UI_GRY" "$UI_R" "$( _ui_trunc "$line" $((cols - 6)) )")"
      shown=$((shown + 1))
      [ "$shown" -ge "$tn" ] && break
    done < <(tail -n "$tn" "$UI_LOG" 2>/dev/null)
  fi
  while [ "$shown" -lt "$tn" ]; do
    if [ "$shown" -eq 0 ]; then
      _ui_add "$(printf '  %s│%s %s(waiting for output…)%s' "$UI_GRY" "$UI_R" "$UI_D" "$UI_R")"
    else
      _ui_add "$(printf '  %s│%s' "$UI_GRY" "$UI_R")"
    fi
    shown=$((shown + 1))
  done
  _ui_add "$(printf '  %s└%s%s' "$UI_GRY" "$( _ui_rep '─' $((cols - 4)) )" "$UI_R")"

  # 4 — overall bar
  local bw=$((cols - 48))
  [ "$bw" -ge 10 ] || bw=10
  [ "$bw" -le 40 ] || bw=40
  local eta=""
  if [ "$opct" -ge 3 ] && [ "$opct" -lt 100 ]; then
    eta="$(printf ' %s· eta ~%s%s' "$UI_GRY" "$( _ui_fmt_t $((el * (100 - opct) / opct)) )" "$UI_R")"
  fi
  _ui_add "$(printf '  %s %s%d%%%s %s· %s elapsed%s%s' \
    "$( _ui_bar "$opct" "$bw" )" "$UI_B" "$opct" "$UI_R" \
    "$UI_GRY" "$( _ui_fmt_t "$el" )" "$eta" "$UI_R")"

  UI_FRAME_N=$((UI_FRAME_N + 1))
  ui_render
  return 0
}

# ------------------------------------------------------------ public API ----
ui_init() { # [title] — enable the dashboard when stdout is an interactive TTY
  UI_TITLE="${1:-build}"
  UI_T0=$(date +%s)
  local cm; cm=$(locale charmap 2>/dev/null) || cm=""
  case "$cm" in ''|*UTF*|*utf*) UI_UTF8=1 ;; *) UI_UTF8=0 ;; esac
  if [ -t 1 ] && [ -z "${NO_UI:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    UI_ACTIVE=1
    trap 'ui_cleanup' EXIT
    trap 'ui_cleanup; exit 130' INT
    trap 'ui_cleanup; exit 143' TERM
    printf '\033[?25l'   # hide the cursor while frames are drawn
  else
    UI_ACTIVE=0
    printf '\n\033[1m==> %s\033[0m\n' "$UI_TITLE"
  fi
  return 0
}

ui_begin() { # label [weight] [description] — register/start a checklist step
  local label="$1" w="${2:-10}" desc="${3:-$1}"
  local i=-1 j
  for ((j = 0; j < UI_N; j++)); do
    if [ "${UI_LBL[j]}" = "$label" ]; then i=$j; break; fi
  done
  if [ "$i" -lt 0 ]; then
    i=$UI_N
    UI_LBL[i]="$label"; UI_W[i]="$w"; UI_DESC[i]="$desc"
    UI_ST[i]="pending"; UI_TM[i]=0
    UI_N=$((UI_N + 1))
  fi
  UI_STEP=$i
  UI_ST[i]="run"
  UI_TB[i]=$(date +%s)
  _ui_reset_knobs
  if [ "$UI_ACTIVE" != 1 ]; then
    printf '\n\033[1m==> %s\033[0m\n' "$desc"
  fi
  return 0
}

ui_run() { # logfile sublabel cmd args... — run a command, logged; animate while it runs
  local logf="$1" sub="$2"; shift 2
  if [ $# -eq 0 ]; then printf 'ui_run: no command given\n' >&2; return 2; fi
  if ! : > "$logf" 2>/dev/null; then printf 'error: cannot write %s\n' "$logf" >&2; return 1; fi
  local rc=0
  if [ "$UI_ACTIVE" != 1 ] || [ "$UI_STEP" -lt 0 ]; then
    # plain mode: stream through tee, exactly like the wiring this replaces
    # (pipefail makes rc the command's status; `|| rc=$?` keeps `set -e` callers alive)
    rc=0
    "$@" 2>&1 | tee "$logf" || rc=$?
    _ui_reset_knobs
    return "$rc"
  fi
  UI_LOG="$logf"; UI_SUB="$sub"
  ( "$@" ) >"$logf" 2>&1 &
  UI_PID=$!
  sleep "$UI_GRACE"   # let fast commands finish without a dashboard flash
  if kill -0 "$UI_PID" 2>/dev/null; then
    while kill -0 "$UI_PID" 2>/dev/null; do
      ui_draw
      sleep "$UI_FRAME"
    done
  fi
  rc=0; wait "$UI_PID" 2>/dev/null || rc=$?
  UI_PID=""
  ui_clear_dash
  _ui_reset_knobs
  if [ "$rc" -ne 0 ]; then
    UI_ST[UI_STEP]="fail"
    printf '  %s%s%s %s — %s exited %d; last lines of %s:\n' \
      "$UI_RED" "$( _ui_c fail )" "$UI_R" "${UI_LBL[UI_STEP]}" "$sub" "$rc" "$logf"
    tail -n 12 "$logf" 2>/dev/null | tr -d '\r' | sed 's/^/      /' || true
  fi
  return "$rc"
}

ui_end() { # [rc] — close the current step (✓ line; failure already shown by ui_run)
  local rc="${1:-0}" i=$UI_STEP
  if [ "$i" -lt 0 ]; then return 0; fi
  local now; now=$(date +%s)
  if [ "$rc" -eq 0 ] && [ "${UI_ST[i]}" != "fail" ]; then
    UI_ST[i]="ok"
    UI_TM[i]=$((now - ${UI_TB[i]:-$now}))
    if [ "$UI_ACTIVE" = 1 ]; then
      printf '  %s%s%s %s%s%s %s(%s)%s\n' \
        "$UI_GRN" "$( _ui_c ok )" "$UI_R" "$UI_B" "${UI_LBL[i]}" "$UI_R" \
        "$UI_D" "$( _ui_fmt_t "${UI_TM[i]}" )" "$UI_R"
    fi
  else
    UI_ST[i]="fail"
    if [ "$UI_ACTIVE" = 1 ]; then
      printf '  %s%s%s %s%s%s\n' \
        "$UI_RED" "$( _ui_c fail )" "$UI_R" "$UI_B" "${UI_LBL[i]}" "$UI_R"
    fi
  fi
  UI_STEP=-1
  return 0
}

ui_skip() { # mark the current step as skipped (e.g. optional payload not found)
  local i=$UI_STEP
  if [ "$i" -lt 0 ]; then return 0; fi
  UI_ST[i]="skip"
  if [ "$UI_ACTIVE" = 1 ]; then
    printf '  %s%s %s%s%s %s(skipped)%s\n' \
      "$UI_GRY" "$( _ui_c skip )" "$UI_B" "${UI_LBL[i]}" "$UI_R" "$UI_D" "$UI_R"
  fi
  UI_STEP=-1
  return 0
}

ui_progress() { # cur total — direct percent for the running step
  UI_PCT_CUR="$1"; UI_PCT_TOT="$2"
  _ui_num UI_PCT_CUR; _ui_num UI_PCT_TOT
  return 0
}

ui_learn() { # file count — persist a learned line total (e.g. successful make length)
  local f="$1" n="$2"
  _ui_num n
  if [ "$n" -gt 0 ]; then printf '%s\n' "$n" > "$f" 2>/dev/null || true; fi
  return 0
}

ui_cleanup() { # restore the terminal; report a step interrupted mid-run
  trap - EXIT INT TERM
  if [ -n "${UI_PID:-}" ]; then
    kill "$UI_PID" 2>/dev/null || true
    wait "$UI_PID" 2>/dev/null || true
    UI_PID=""
  fi
  ui_clear_dash
  printf '\033[?25h'
  local i=${UI_STEP:--1}
  if [ "$i" -ge 0 ] && [ "${UI_ST[i]:-}" = "run" ]; then
    printf '  %s%s%s %s%s%s %sinterrupted%s\n' \
      "$UI_RED" "$( _ui_c fail )" "$UI_R" "$UI_B" "${UI_LBL[i]}" "$UI_R" "$UI_D" "$UI_R"
  fi
  return 0
}

ui_finish() { # on success: restore the terminal and print the total time
  if [ "$UI_ACTIVE" != 1 ]; then return 0; fi
  trap - EXIT INT TERM
  ui_clear_dash
  printf '\033[?25h'
  local el=$(( $(date +%s) - UI_T0 ))
  printf '  %s%s%s finished in %s%s%s\n' \
    "$UI_GRN" "$( _ui_c ok )" "$UI_R" "$UI_D" "$( _ui_fmt_t "$el" )" "$UI_R"
  return 0
}
