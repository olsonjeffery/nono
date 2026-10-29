#!/bin/bash
# shellcheck disable=SC2088 # User-facing test descriptions intentionally use ~ notation.
# Supervisor FD Pass-Through Tests
#
# By default `nono run` closes every descriptor above stdio in the sandboxed
# child (nolabs-ai/nono#2176). With `--allow-inherit-fd <FD>` a
# parent-provided descriptor survives exec at the same number so agent
# harnesses that drive processes over side-channel descriptors work under the
# supervisor. Without the flag the child must not be able to reach a
# parent-provided descriptor, and fd numbers that are not open in the nono
# process are rejected before launch.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/test_helpers.sh"

echo ""
echo -e "${BLUE}Supervisor FD Pass-Through Tests${NC}"

verify_nono_binary
if ! require_working_sandbox "fd pass-through suite"; then
    print_summary
    exit 0
fi

# Create test fixtures
TMPDIR=$(setup_test_dir)
trap 'cleanup_test_dir "$TMPDIR"' EXIT

echo ""
echo "Test directory: $TMPDIR"
echo ""

# A descriptor number that is known closed in this shell, for the validation
# tests. Start above the range the test harness is likely to hold open.
UNKNOWN_FD=42
while [[ -e "/proc/$$/fd/$UNKNOWN_FD" ]]; do
    UNKNOWN_FD=$((UNKNOWN_FD + 1))
done

# Parent-provided descriptor survives exec with --allow-inherit-fd

echo "Descriptor pass-through"

FD_PASS_MARK="$TMPDIR/pass.txt"
exec 9>"$FD_PASS_MARK"
run_test "parent descriptor survives exec with --allow-inherit-fd" 0 \
    "$NONO_BIN" run --allow "$TMPDIR" --allow-inherit-fd 9 -- sh -c 'echo fd-pass >&9'
exec 9>&-

FD_PASS_CONTENT=$(cat "$FD_PASS_MARK" 2>/dev/null || echo "")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$FD_PASS_CONTENT" == *fd-pass* ]]; then
    echo -e "  ${GREEN}PASS${NC}: child wrote through the inherited descriptor"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}FAIL${NC}: child could not write through the inherited descriptor"
    echo "       Marker content: '$FD_PASS_CONTENT'"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Two explicitly passed descriptors, one flag each

FD_PASS2A_MARK="$TMPDIR/pass2a.txt"
FD_PASS2B_MARK="$TMPDIR/pass2b.txt"
exec 7>"$FD_PASS2A_MARK"
exec 8>"$FD_PASS2B_MARK"
run_test "repeated --allow-inherit-fd flags all pass through" 0 \
    "$NONO_BIN" run --allow "$TMPDIR" \
    --allow-inherit-fd 7 --allow-inherit-fd 8 \
    -- sh -c 'echo alpha >&7; echo beta >&8'
exec 7>&-
exec 8>&-

FD_A_CONTENT=$(cat "$FD_PASS2A_MARK" 2>/dev/null || echo "")
FD_B_CONTENT=$(cat "$FD_PASS2B_MARK" 2>/dev/null || echo "")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$FD_A_CONTENT" == *alpha* && "$FD_B_CONTENT" == *beta* ]]; then
    echo -e "  ${GREEN}PASS${NC}: both inherited descriptors reached the child"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}FAIL${NC}: expected both descriptors to reach the child"
    echo "       Marker A content: '$FD_A_CONTENT'"
    echo "       Marker B content: '$FD_B_CONTENT'"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Without --allow-inherit-fd the child must not reach the descriptor

echo ""
echo "Default sweep (fail closed)"

: > "$FD_PASS_MARK"
exec 9>"$FD_PASS_MARK"
expect_failure "descriptor is closed in the child without the flag" \
    "$NONO_BIN" run --allow "$TMPDIR" -- sh -c 'echo nope >&9'
exec 9>&-

FD_CLOSED_CONTENT=$(cat "$FD_PASS_MARK" 2>/dev/null || echo "")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$FD_CLOSED_CONTENT" ]]; then
    echo -e "  ${GREEN}PASS${NC}: nothing reached the swept descriptor"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}FAIL${NC}: the swept descriptor must be closed in the child"
    echo "       Marker content: '$FD_CLOSED_CONTENT'"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Requested fd numbers are validated before launch: fail closed, loud errors

expect_output_contains "closed descriptor number is rejected before launch" \
    "is not open in the nono process" \
    "$NONO_BIN" run --allow "$TMPDIR" \
    --allow-inherit-fd "$UNKNOWN_FD" -- sh -c 'true'

expect_output_contains "stdio numbers are rejected with a clear error" \
    "descriptors above stdio" \
    "$NONO_BIN" run --allow "$TMPDIR" \
    --allow-inherit-fd 1 -- sh -c 'true'

# wrap preserves inherited descriptors unconditionally and has no flag

expect_output_contains "wrap rejects --allow-inherit-fd" \
    "unexpected argument" \
    "$NONO_BIN" wrap --allow "$TMPDIR" \
    --allow-inherit-fd "$UNKNOWN_FD" -- sh -c 'true'

print_summary
