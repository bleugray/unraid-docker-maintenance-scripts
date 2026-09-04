#!/bin/bash

# ============================================================
# Unused Anonymous Docker Volume Cleanup
#
# remove_volumes="no"  = report only
# remove_volumes="yes" = delete unused anonymous volumes
# verbose="no"         = summary only
# verbose="yes"        = list every matching volume
# ============================================================

remove_volumes="no"
verbose="no"

echo "============================================================"
echo "Unused Anonymous Docker Volumes"
echo "============================================================"
echo

count=0
total_kb=0
removed=0
failed=0

# "dangling=true" limits the initial list to volumes that are
# not currently referenced by a container.
for v in $(docker volume ls -q --filter dangling=true); do

    # Docker anonymous volumes normally use a 64-character lowercase
    # hexadecimal name. This prevents ordinary named volumes from being
    # considered for deletion.
    if [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then

        mp=$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null)

        if [ -n "$mp" ] && [ -d "$mp" ]; then
            size=$(du -sk "$mp" 2>/dev/null | awk '{print $1}')
            size=${size:-0}
        else
            size=0
        fi

        if [[ "$verbose" == "yes" ]]; then
            printf "%10s KB  %s\n" "$size" "$v"
        fi

        ((count++))
        ((total_kb+=size))

        if [[ "$remove_volumes" == "yes" ]]; then
            # Re-check that the volume is still unused immediately before
            # deletion. Docker will also refuse to remove an in-use volume.
            if [ -z "$(docker ps -aq --filter volume="$v")" ]; then
                if docker volume rm "$v" >/dev/null 2>&1; then
                    ((removed++))
                else
                    ((failed++))
                    echo "WARNING: Could not remove $v"
                fi
            else
                ((failed++))
                echo "WARNING: $v became attached; skipped"
            fi
        fi
    fi
done

echo
echo "============================================================"
echo "Unused anonymous volumes found: $count"
echo "Approximate total size:         $((total_kb / 1024)) MB"

if [[ "$remove_volumes" == "yes" ]]; then
    echo "Volumes removed:                $removed"
    if (( failed > 0 )); then
        echo "Volumes skipped/failed:         $failed"
    fi
else
    echo "Mode:                           REPORT ONLY"
    echo
    echo 'Set remove_volumes="yes" to enable cleanup.'
fi

echo "============================================================"
