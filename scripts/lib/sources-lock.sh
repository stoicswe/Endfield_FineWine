# sources-lock.sh — reads finewine-sources.lock and checks against it. Sourced by the FineWine
# build scripts after they have set REPO.
#
#   lock_load                         set every KEY in the lock file that the environment has
#                                     not set already
#   lock_check <what> <got> <want>    stop (or with FINEWINE_UNLOCKED=1, warn) when a fetched
#                                     commit is not the pinned one
#   lock_check_brew <formula> <major> stop (or warn) when Homebrew's version of a tool has
#                                     another major version
LOCK_FILE="${FINEWINE_LOCK_FILE:-$REPO/finewine-sources.lock}"

lock_load(){
  [ -f "$LOCK_FILE" ] || { echo "ERROR: no $LOCK_FILE" >&2; exit 1; }
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in ''|*[!A-Za-z0-9_]*) echo "ERROR: $LOCK_FILE: bad line: $line" >&2; exit 1 ;; esac
    # what the environment says wins: a one-off build of something else
    if [ -z "${!key+x}" ]; then printf -v "$key" '%s' "$value"; export "${key?}"; fi
  done < "$LOCK_FILE"
}

lock_fail(){
  if [ "${FINEWINE_UNLOCKED:-0}" = "1" ]; then
    echo "WARNING: $* (FINEWINE_UNLOCKED=1, carrying on)" >&2
  else
    echo "ERROR: $*" >&2
    echo "       finewine-sources.lock names what FineWine is built from; change it there to move" >&2
    echo "       to another version, or set FINEWINE_UNLOCKED=1 for a one-off build." >&2
    exit 1
  fi
}

lock_check(){
  local what="$1" got="$2" want="$3"
  [ -n "$want" ] || return 0
  case "$got" in
    "$want"*) return 0 ;;   # a full commit; also accepts an abbreviation of it being asked for
  esac
  lock_fail "$what is at $got, but finewine-sources.lock pins $want"
}

lock_check_brew(){
  local formula="$1" want="$2" got
  [ -n "$want" ] || return 0
  got="$("${BREW:-brew}" list --versions "$formula" 2>/dev/null | awk '{print $NF}')"
  [ -n "$got" ] || { lock_fail "Homebrew's $formula is not installed"; return 0; }
  [ "${got%%.*}" = "$want" ] || lock_fail "Homebrew's $formula is $got; finewine-sources.lock expects major version $want"
  echo "$formula $got"
}
