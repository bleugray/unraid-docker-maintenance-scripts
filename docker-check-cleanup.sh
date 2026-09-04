#!/bin/bash

# ==============================================================================
# Unraid Docker Check / Cleanup
#
# Inspired by SpaceInvaderOne's Unraid_check_docker_script:
# https://github.com/SpaceinvaderOne/Unraid_check_docker_script
#
# This version expands the original report with:
#   - safer, explicit image cleanup control
#   - container writable-layer / RootFS reporting
#   - Docker log usage including rotated logs
#   - image size sorting
#   - named/anonymous and attached/dangling volume reporting
#   - volume mount destinations
#   - cleanup/review recommendations
#
# The script DOES NOT delete Docker volumes.
# Use unused-anonymous-volume-cleanup.sh for that task.
# ==============================================================================

remove_unused_images="no"

# Review thresholds only. They do not automatically delete anything.
writable_layer_review_mb=100
docker_log_review_mb=250
anonymous_volume_review_count=25
anonymous_volume_review_mb=100

# ==============================================================================
# Helpers
# ==============================================================================

human_bytes() {
    local bytes=${1:-0}
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1073741824)      printf "%.2f GB", b/1073741824;
        else if (b >= 1048576)   printf "%.1f MB", b/1048576;
        else if (b >= 1024)      printf "%.1f KB", b/1024;
        else                     printf "%d B", b;
    }'
}

separator() {
    echo "################################################################################"
}

# ==============================================================================
# Header
# ==============================================================================

separator
echo "# Docker Check / Cleanup"
separator
echo
echo "Host: $(hostname)"
echo "Date: $(date)"
echo

# ==============================================================================
# Cleanup
# ==============================================================================

separator
echo "# Cleanup"
separator
echo

if [[ "$remove_unused_images" == "yes" ]]; then
    echo "Unused image cleanup: ENABLED"
    echo
    echo "Removing images not referenced by any container..."
    docker image prune -af
else
    echo "Unused image cleanup: DISABLED"
    echo
    echo 'Set remove_unused_images="yes" to remove images not referenced'
    echo "by any container."
fi

echo
echo "--------------------------------------------------------------------------------"
echo

echo "Checking for unused anonymous Docker volumes..."
echo

dangling_anon_count=0
dangling_anon_kb=0

while IFS= read -r volume; do
    [[ -z "$volume" ]] && continue

    if [[ "$volume" =~ ^[0-9a-f]{64}$ ]]; then
        mountpoint=$(docker volume inspect -f '{{.Mountpoint}}' "$volume" 2>/dev/null)
        size_kb=0

        if [[ -n "$mountpoint" && -d "$mountpoint" ]]; then
            size_kb=$(du -sk "$mountpoint" 2>/dev/null | awk '{print $1}')
            size_kb=${size_kb:-0}
        fi

        ((dangling_anon_count++))
        ((dangling_anon_kb+=size_kb))
    fi
done < <(docker volume ls -q --filter dangling=true)

echo "Unused anonymous volumes found: $dangling_anon_count"
echo "Approximate total size: $((dangling_anon_kb / 1024)) MB"
echo "Anonymous volume cleanup: DISABLED"

echo
echo "--------------------------------------------------------------------------------"
echo

# ==============================================================================
# Docker Storage Summary
# ==============================================================================

separator
echo "# Docker Storage Summary"
separator
echo

docker system df

echo

# ==============================================================================
# Containers Sorted by Writable Layer Size
# ==============================================================================

separator
echo "# Containers Sorted by Writable Layer Size"
separator
echo
echo "Writable = changes stored in the container's writable layer."
echo "RootFS = total container filesystem including image layers."
echo
printf "%-12s %-12s %-32s %s\n" "WRITABLE" "ROOTFS" "CONTAINER" "IMAGE"
printf "%-12s %-12s %-32s %s\n" "------------" "------------" "--------------------------------" "-----"

container_tmp=$(mktemp)
trap 'rm -f "$container_tmp" "$log_tmp" "$image_tmp" "$volume_tmp" 2>/dev/null' EXIT

while IFS= read -r container_id; do
    [[ -z "$container_id" ]] && continue

    read -r size_rw size_root name image < <(
        docker inspect --size -f '{{.SizeRw}} {{.SizeRootFs}} {{.Name}} {{.Config.Image}}' "$container_id" 2>/dev/null
    )

    size_rw=${size_rw:-0}
    size_root=${size_root:-0}
    name=${name#/}

    printf "%s|%s|%s|%s\n" "$size_rw" "$size_root" "$name" "$image" >> "$container_tmp"
done < <(docker ps -aq)

sort -t'|' -k1,1nr "$container_tmp" | while IFS='|' read -r size_rw size_root name image; do
    printf "%-12s %-12s %-32s %s\n" "$(human_bytes "$size_rw")" "$(human_bytes "$size_root")" "$name" "$image"
done

echo
separator
echo "# Containers With Writable Layers >= ${writable_layer_review_mb} MB"
separator
echo

writable_threshold_bytes=$((writable_layer_review_mb * 1024 * 1024))
writable_found=0

while IFS='|' read -r size_rw _size_root name image; do
    if (( size_rw >= writable_threshold_bytes )); then
        printf "%-12s %-32s %s\n" "$(human_bytes "$size_rw")" "$name" "$image"
        ((writable_found++))
    fi
done < <(sort -t'|' -k1,1nr "$container_tmp")

if (( writable_found == 0 )); then
    echo "None"
fi

echo

# ==============================================================================
# Docker Container Log Usage
# ==============================================================================

separator
echo "# Docker Container Log Usage"
separator
echo
echo "TOTAL LOGS includes the current Docker log plus rotated logs"
echo "such as .1, .2, etc. when present."
echo
printf "%-12s %-8s %-32s %-12s %s\n" "TOTAL LOGS" "FILES" "CONTAINER" "DRIVER" "CURRENT LOG"
printf "%-12s %-8s %-32s %-12s %s\n" "------------" "--------" "--------------------------------" "------------" "-----------"

log_tmp=$(mktemp)
total_log_bytes=0
largest_log_bytes=0
largest_log_container="None"
log_threshold_bytes=$((docker_log_review_mb * 1024 * 1024))
log_over_threshold=0

while IFS= read -r container_id; do
    [[ -z "$container_id" ]] && continue

    name=$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null)
    name=${name#/}
    driver=$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$container_id" 2>/dev/null)
    logpath=$(docker inspect -f '{{.LogPath}}' "$container_id" 2>/dev/null)

    bytes=0
    files=0

    if [[ -n "$logpath" && "$logpath" != "<no value>" ]]; then
        logdir=$(dirname "$logpath")
        logfile=$(basename "$logpath")

        if [[ -d "$logdir" ]]; then
            while IFS= read -r logfile_path; do
                [[ -z "$logfile_path" ]] && continue
                file_bytes=$(stat -c '%s' "$logfile_path" 2>/dev/null || echo 0)
                ((bytes+=file_bytes))
                ((files++))
            done < <(find "$logdir" -maxdepth 1 -type f -name "${logfile}*" -print 2>/dev/null)
        fi
    fi

    ((total_log_bytes+=bytes))

    if (( bytes > largest_log_bytes )); then
        largest_log_bytes=$bytes
        largest_log_container=$name
    fi

    if (( bytes >= log_threshold_bytes )); then
        ((log_over_threshold++))
    fi

    printf "%s|%s|%s|%s|%s\n" "$bytes" "$files" "$name" "$driver" "$logpath" >> "$log_tmp"
done < <(docker ps -aq)

sort -t'|' -k1,1nr "$log_tmp" | while IFS='|' read -r bytes files name driver logpath; do
    (( bytes == 0 )) && continue
    printf "%-12s %-8s %-32s %-12s %s\n" "$(human_bytes "$bytes")" "$files" "$name" "$driver" "$logpath"
done

echo
echo "Total Docker container logs: $(human_bytes "$total_log_bytes")"
echo "Largest log consumer: $largest_log_container ($(human_bytes "$largest_log_bytes"))"
echo "Review threshold: ${docker_log_review_mb} MB"
echo "Containers above threshold: $log_over_threshold"

echo
separator
echo "# Containers With Docker Logs >= ${docker_log_review_mb} MB"
separator
echo

if (( log_over_threshold == 0 )); then
    echo "None"
else
    while IFS='|' read -r bytes files name driver _logpath; do
        if (( bytes >= log_threshold_bytes )); then
            printf "%-12s %-8s %-32s %s\n" "$(human_bytes "$bytes")" "$files" "$name" "$driver"
        fi
    done < <(sort -t'|' -k1,1nr "$log_tmp")
fi

echo

# ==============================================================================
# Docker Images Sorted by Size
# ==============================================================================

separator
echo "# Docker Images Sorted by Size"
separator
echo
printf "%-12s %-14s %s\n" "SIZE" "IMAGE ID" "REPOSITORY / TAG"
printf "%-12s %-14s %s\n" "------------" "--------------" "----------------"

image_tmp=$(mktemp)

while IFS='|' read -r image_id repo_tag; do
    [[ -z "$image_id" ]] && continue
    bytes=$(docker image inspect -f '{{.Size}}' "$image_id" 2>/dev/null)
    bytes=${bytes:-0}
    short_id=${image_id:0:12}
    printf "%s|%s|%s\n" "$bytes" "$short_id" "$repo_tag" >> "$image_tmp"
done < <(docker image ls --format '{{.ID}}|{{.Repository}}:{{.Tag}}')

sort -t'|' -k1,1nr "$image_tmp" | while IFS='|' read -r bytes image_id repo_tag; do
    printf "%-12s %-14s %s\n" "$(human_bytes "$bytes")" "$image_id" "$repo_tag"
done

echo

# ==============================================================================
# Docker Volumes
# ==============================================================================

separator
echo "# Docker Volumes"
separator
echo
echo "TYPE:"
echo "named = explicitly named Docker volume"
echo "anonymous = Docker-generated 64-character volume name"
echo
echo "STATUS:"
echo "attached = referenced by at least one container"
echo "dangling = not referenced by any container"
echo
echo "MOUNT(S):"
echo "Shows the container name and destination path for each volume."
echo
printf "%-10s %-10s %-12s %-42s %-30s %s\n" "TYPE" "STATUS" "SIZE" "VOLUME" "CONTAINER(S)" "MOUNT(S)"
printf "%-10s %-10s %-12s %-42s %-30s %s\n" "----------" "----------" "----------" "------------------------------------------" "------------------------------" "--------"

volume_tmp=$(mktemp)
total_volumes=0
named_volumes=0
anonymous_volumes=0
dangling_volumes=0
dangling_anonymous_volumes=0

while IFS= read -r volume; do
    [[ -z "$volume" ]] && continue
    ((total_volumes++))

    if [[ "$volume" =~ ^[0-9a-f]{64}$ ]]; then
        volume_type="anonymous"
        ((anonymous_volumes++))
    else
        volume_type="named"
        ((named_volumes++))
    fi

    mapfile -t attached_ids < <(docker ps -aq --filter volume="$volume")

    if (( ${#attached_ids[@]} > 0 )); then
        status="attached"
    else
        status="dangling"
        ((dangling_volumes++))
        if [[ "$volume_type" == "anonymous" ]]; then
            ((dangling_anonymous_volumes++))
        fi
    fi

    mountpoint=$(docker volume inspect -f '{{.Mountpoint}}' "$volume" 2>/dev/null)
    size_kb=0
    if [[ -n "$mountpoint" && -d "$mountpoint" ]]; then
        size_kb=$(du -sk "$mountpoint" 2>/dev/null | awk '{print $1}')
        size_kb=${size_kb:-0}
    fi
    size_bytes=$((size_kb * 1024))

    containers="-"
    mounts="-"

    if (( ${#attached_ids[@]} > 0 )); then
        containers=""
        mounts=""

        for container_id in "${attached_ids[@]}"; do
            cname=$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null)
            cname=${cname#/}

            if [[ -n "$containers" ]]; then
                containers+=","
            fi
            containers+="$cname"

            while IFS= read -r destination; do
                [[ -z "$destination" ]] && continue
                if [[ -n "$mounts" ]]; then
                    mounts+=", "
                fi
                mounts+="$cname:$destination"
            done < <(docker inspect -f "{{range .Mounts}}{{if eq .Name \"$volume\"}}{{.Destination}}{{println}}{{end}}{{end}}" "$container_id" 2>/dev/null)
        done
    fi

    printf "%s|%s|%s|%s|%s|%s\n" "$size_bytes" "$volume_type" "$status" "$volume" "$containers" "$mounts" >> "$volume_tmp"
done < <(docker volume ls -q)

sort -t'|' -k1,1nr "$volume_tmp" | while IFS='|' read -r size_bytes volume_type status volume containers mounts; do
    printf "%-10s %-10s %-12s %-42s %-30s %s\n" "$volume_type" "$status" "$(human_bytes "$size_bytes")" "$volume" "$containers" "$mounts"
done

echo
separator
echo "# Volume Summary"
separator
echo
echo "Total Docker volumes: $total_volumes"
echo "Named volumes: $named_volumes"
echo "Anonymous volumes: $anonymous_volumes"
echo "Dangling volumes: $dangling_volumes"
echo "Dangling anonymous volumes: $dangling_anonymous_volumes"

echo

# ==============================================================================
# Health / Cleanup Summary
# ==============================================================================

separator
echo "# Health / Cleanup Summary"
separator
echo

if [[ "$remove_unused_images" == "yes" ]]; then
    echo "Unused image cleanup: ENABLED"
else
    echo "Unused image cleanup: DISABLED"
fi

echo "Anonymous volume cleanup: DISABLED"

anonymous_volume_review_size_kb=$((anonymous_volume_review_mb * 1024))
if (( dangling_anon_count >= anonymous_volume_review_count || dangling_anon_kb >= anonymous_volume_review_size_kb )); then
    echo "Volume cleanup recommendation: Review recommended"
    echo
    echo ">>> ANONYMOUS VOLUME CLEANUP RECOMMENDED <<<"
    echo
    echo "Unused anonymous volumes: $dangling_anon_count"
    echo "Approximate size: $((dangling_anon_kb / 1024)) MB"
    echo
    echo "Run the separate:"
    echo "Unused Anonymous Docker Volume Cleanup"
    echo
    echo "script in REPORT ONLY mode first, review the candidates,"
    echo "then enable removal if appropriate."
else
    echo "Volume cleanup recommendation: None"
fi

echo
echo "Docker container logs: $(human_bytes "$total_log_bytes")"
echo "Largest log consumer: $largest_log_container ($(human_bytes "$largest_log_bytes"))"

if (( log_over_threshold > 0 )); then
    echo
    echo ">>> DOCKER LOG REVIEW RECOMMENDED <<<"
    echo
    echo "Containers >= ${docker_log_review_mb} MB: $log_over_threshold"
    echo
    echo "Review the:"
    echo "Containers With Docker Logs >= ${docker_log_review_mb} MB"
    echo
    echo "section above."
    echo
    echo "Large logs are not automatically deleted."
    echo "Review the container's logging behavior and Docker"
    echo "log rotation settings before taking action."
else
    echo "Docker log review recommendation: None"
fi

echo
separator
echo "# Done"
separator
