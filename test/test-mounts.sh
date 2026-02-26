#!/usr/bin/env bash
# Test mount mode parsing from ~/.yolo/mounts.
# Verifies :ro/:rw suffix detection, comment stripping, whitespace handling.
# Usage: ./test/test-mounts.sh
set -euo pipefail

BOLD='' RESET='' GREEN='' RED=''
if [ -t 1 ]; then
    BOLD='\033[1m' RESET='\033[0m'
    GREEN='\033[32m' RED='\033[31m'
fi

pass() { echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; FAILURES=$((FAILURES + 1)); }

FAILURES=0
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

# Create real directories so the -e check passes
mkdir -p "$TMPDIR/bare-path" "$TMPDIR/rw-path" "$TMPDIR/ro-path" \
         "$TMPDIR/comment-path" "$TMPDIR/ws-path"

# ─── Helper: run the parsing logic against a mounts file ─────────────────────

parse_mounts() {
    local mounts_file="$1"
    local MOUNTS=()
    local HOME="$TMPDIR"  # override HOME so ~ expands to our temp dir

    while IFS= read -r mount_path || [ -n "$mount_path" ]; do
        mount_path="${mount_path%%#*}"   # strip comments
        mount_path="${mount_path%"${mount_path##*[! ]}"}"  # trim trailing whitespace
        mount_path="${mount_path#"${mount_path%%[! ]*}"}"  # trim leading whitespace
        [ -z "$mount_path" ] && continue
        # Detect :rw or :ro suffix (default: ro)
        mode="ro"
        if [[ "$mount_path" == *:rw ]]; then
            mode="rw"
            mount_path="${mount_path%:rw}"
        elif [[ "$mount_path" == *:ro ]]; then
            mount_path="${mount_path%:ro}"
        fi
        # Trim trailing whitespace from path (handles "~/path :rw")
        mount_path="${mount_path%"${mount_path##*[! ]}"}"
        # Expand ~ to $HOME
        mount_path="${mount_path/#\~/$HOME}"
        if [ -e "$mount_path" ]; then
            MOUNTS+=("${mount_path}:${mount_path}:${mode}")
        fi
    done < "$mounts_file"

    printf '%s\n' "${MOUNTS[@]}"
}

# ─── Test cases ──────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Mount mode parsing${RESET}"

# 1. Bare path → :ro
echo "$TMPDIR/bare-path" > "$TMPDIR/mounts"
result=$(parse_mounts "$TMPDIR/mounts")
if [[ "$result" == *":ro" ]]; then
    pass "Bare path defaults to :ro"
else
    fail "Bare path defaults to :ro — got: $result"
fi

# 2. Path with :rw → :rw
echo "$TMPDIR/rw-path:rw" > "$TMPDIR/mounts"
result=$(parse_mounts "$TMPDIR/mounts")
if [[ "$result" == *":rw" ]]; then
    pass "Path with :rw suffix mounts read-write"
else
    fail "Path with :rw suffix mounts read-write — got: $result"
fi

# 3. Path with :ro → :ro
echo "$TMPDIR/ro-path:ro" > "$TMPDIR/mounts"
result=$(parse_mounts "$TMPDIR/mounts")
if [[ "$result" == *":ro" ]]; then
    pass "Path with :ro suffix mounts read-only"
else
    fail "Path with :ro suffix mounts read-only — got: $result"
fi

# 4. Path with :rw and trailing comment → :rw
echo "$TMPDIR/comment-path:rw  # writable" > "$TMPDIR/mounts"
result=$(parse_mounts "$TMPDIR/mounts")
if [[ "$result" == *":rw" ]]; then
    pass ":rw with trailing comment"
else
    fail ":rw with trailing comment — got: $result"
fi

# 5. Path with :rw and leading/trailing whitespace → :rw
echo "  $TMPDIR/ws-path:rw  " > "$TMPDIR/mounts"
result=$(parse_mounts "$TMPDIR/mounts")
if [[ "$result" == *":rw" ]]; then
    pass ":rw with surrounding whitespace"
else
    fail ":rw with surrounding whitespace — got: $result"
fi

# 6. Path with space before :rw suffix → :rw (path trimmed)
echo "$TMPDIR/ws-path :rw" > "$TMPDIR/mounts"
result=$(parse_mounts "$TMPDIR/mounts")
if [[ "$result" == *"$TMPDIR/ws-path:$TMPDIR/ws-path:rw"* ]]; then
    pass ":rw with space before suffix"
else
    fail ":rw with space before suffix — got: $result"
fi

# 7. Tilde expansion with :rw
mkdir -p "$TMPDIR/tilde-path"
echo "~/tilde-path:rw" > "$TMPDIR/mounts"
result=$(parse_mounts "$TMPDIR/mounts")
if [[ "$result" == *"$TMPDIR/tilde-path"*":rw" ]]; then
    pass "Tilde expansion with :rw"
else
    fail "Tilde expansion with :rw — got: $result"
fi

# 8. Blank lines and comment-only lines are skipped
cat > "$TMPDIR/mounts" << EOF

# this is a comment
   # indented comment

$TMPDIR/bare-path
EOF
result=$(parse_mounts "$TMPDIR/mounts")
count=$(echo "$result" | grep -c ':' || true)
if [[ "$count" -eq 1 ]]; then
    pass "Blank lines and comments are skipped"
else
    fail "Blank lines and comments are skipped — got $count mounts"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
