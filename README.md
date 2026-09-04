# Unraid Docker Maintenance Scripts

A small set of Bash scripts for inspecting and maintaining Docker storage on Unraid.

These scripts grew out of the excellent [`Unraid_check_docker_script`](https://github.com/SpaceinvaderOne/Unraid_check_docker_script) by **SpaceInvaderOne**. The Docker reporting has been modernized and expanded with safer anonymous-volume handling, writable-layer reporting, Docker log accounting (including rotated logs), volume mount visibility, and review recommendations.

This repository is not affiliated with or maintained by SpaceInvaderOne.

## Scripts

### `docker-check-cleanup.sh`

The main Docker health/reporting script. It reports:

- Docker storage totals (`docker system df`)
- Container writable-layer and RootFS sizes
- Containers with large writable layers
- Docker container log usage, including rotated `.1`, `.2`, etc. files
- Containers above a configurable log-review threshold
- Docker images sorted by size
- Docker volumes sorted by size
- Named vs. anonymous volumes
- Attached vs. dangling volumes
- Container mount destinations for every Docker volume
- A recommendation to run the separate anonymous-volume cleanup script when configurable thresholds are exceeded

It can optionally run:

```bash
docker image prune -af
```

That option is **disabled by default**.

The main script intentionally does **not** delete Docker volumes.

### `unused-anonymous-volume-cleanup.sh`

A focused cleanup script for stale Docker-generated anonymous volumes.

It uses multiple safeguards:

1. Docker's `dangling=true` filter limits the initial candidate list to volumes not referenced by a container.
2. Candidates must have a 64-character lowercase hexadecimal name, which is Docker's normal anonymous-volume naming pattern.
3. Each candidate is removed individually with `docker volume rm` rather than using a broad `docker volume prune -a`.
4. Docker refuses to remove a volume that becomes attached/in use.

The shared version defaults to **report-only mode**:

```bash
remove_volumes="no"
```

After reviewing the report, change it to:

```bash
remove_volumes="yes"
```

to enable deletion.

> Note: Docker does not expose an `anonymous=true` metadata flag. The 64-character lowercase-hex test is therefore a practical heuristic. A manually named volume using exactly that pattern would also match.

## Installing in Unraid User Scripts

Install the **User Scripts** plugin from Community Applications, create a new script, and paste in the contents of the desired `.sh` file.

Suggested names:

- `Docker Check Cleanup`
- `Unused Anonymous Docker Volume Cleanup`

For normal use, run `docker-check-cleanup.sh` first. If it reports:

```text
>>> ANONYMOUS VOLUME CLEANUP RECOMMENDED <<<
```

run the anonymous-volume cleanup script in report-only mode, review the candidates, and then enable deletion if appropriate.

## Default review thresholds

The main script currently uses:

```bash
writable_layer_review_mb=100
docker_log_review_mb=250
anonymous_volume_review_count=25
anonymous_volume_review_mb=100
```

These are review thresholds, not automatic failure conditions. For example, a container configured with Docker log rotation of `max-size=100m` and `max-file=3` can legitimately consume close to 300 MB across its current and rotated logs.

## Safety notes

- Persistent application data should normally live in bind mounts or explicitly named Docker volumes.
- Do not delete a named volume simply because it is currently unused unless you know what created it and whether it contains persistent data.
- The anonymous-volume cleanup script intentionally avoids `docker volume prune -a` because `-a/--all` expands cleanup to unused **named** volumes as well.
- `docker image prune -af` removes all images not referenced by any container, including older cached image versions you might otherwise use for a quick rollback.
- Large Docker writable layers are a signal to investigate whether application data, caches, downloads, or runtime files should be persisted outside the container. They are not automatically errors.
- Large Docker logs should be investigated before truncation or deletion. Prefer correcting noisy logging and configuring appropriate rotation.

## ShellCheck

GitHub Actions runs ShellCheck against all repository `.sh` files on pushes and pull requests.

## License / reuse

The scripts are provided for community use. If you redistribute or substantially modify the work derived from SpaceInvaderOne's original script, retain appropriate attribution to the upstream project.
