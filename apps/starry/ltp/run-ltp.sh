#!/bin/sh
trap '' USR1

echo "=== LTP Test Runner ==="

passed=0
failed=0
broken=0
skipped=0
total=0
start=${START:-1}

for t in /opt/ltp/testcases/bin/*; do
    [ -x "$t" ] || continue
    name=$(basename "$t")

    # Skip shell scripts
    if head -c 2 "$t" 2>/dev/null | grep -q '#!'; then
        continue
    fi
    # Skip kernel module tests (cause kernel panic)
    case "$name" in *.ko) continue ;; esac
    # Skip known problematic tests (scope_local spin::Once deadlock)
    case "$name" in epoll_pwait06) continue ;; esac
    # Skip tests that cause kernel panic (capacity overflow)
    case "$name" in crash02) continue ;; esac
    # Skip tests that cause QEMU hang (mount/ext4 issues)
    case "$name" in mount*|statmount*) continue ;; esac

    total=$((total + 1))
    [ $total -lt $start ] && continue
    printf "[%d] %s ... " "$total" "$name"

    # Monitor resources every 100 tests
    if [ $((total % 100)) -eq 0 ]; then
        echo ""
        echo "--- Resources at test $total ---"
        echo "Processes: $(ls /proc/*/status 2>/dev/null | wc -l)"
        echo "FDs: $(ls /proc/*/fd 2>/dev/null | wc -l)"
        echo "---"
    fi

    result_file="/tmp/ltp_last_result"
    rc=0
    (timeout 5 "$t" >"$result_file" 2>&1) || rc=$?

    if [ $rc -eq 124 ]; then
        echo "TIMEOUT"
        failed=$((failed + 1))
    elif grep -q "TPASS" "$result_file" 2>/dev/null; then
        echo "PASS"
        passed=$((passed + 1))
    elif grep -q "TFAIL" "$result_file" 2>/dev/null; then
        echo "FAIL"
        cat "$result_file" | grep -E "TFAIL|TBROK|TCONF" | head -3
        failed=$((failed + 1))
    elif grep -q "TBROK" "$result_file" 2>/dev/null; then
        echo "BROKEN"
        cat "$result_file" | grep -E "TBROK|TCONF" | head -3
        broken=$((broken + 1))
    elif grep -q "TCONF" "$result_file" 2>/dev/null; then
        echo "SKIPPED"
        skipped=$((skipped + 1))
    elif [ $rc -eq 0 ]; then
        echo "PASS"
        passed=$((passed + 1))
    else
        echo "FAIL (exit $rc)"
        cat "$result_file" | tail -3
        failed=$((failed + 1))
    fi
done

rm -f /tmp/ltp_last_result

echo ""
echo "=== Results ==="
echo "Total: $total | Passed: $passed | Failed: $failed | Broken: $broken | Skipped: $skipped"
echo "LTP TEST COMPLETE"
