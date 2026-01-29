# Syncing from Upstream to Downstream

This document describes the process for syncing changes from the upstream repository to the downstream repository.

## Overview

The downstream repository maintains customizations (e.g., different naming conventions like "ossm" instead of "kiali") while periodically pulling in changes from upstream. This creates predictable merge conflicts, especially in generated files like `README.md`.

## Prerequisites

Ensure you have both remotes configured:

```bash
git remote -v
```

You should see:
- `upstream` - pointing to the upstream repository
- `downstream` - pointing to the downstream repository

If not configured:

```bash
git remote add upstream <upstream-repo-url>
git remote add downstream <downstream-repo-url>
```

## Automated Sync (Recommended)

Use the provided script for automated syncing:

```bash
./sync-from-upstream.sh
```

This script will:
1. Fetch from both upstream and downstream remotes
2. Create a timestamped sync branch (e.g., `sync-downstream-20260129-1430`)
3. Merge upstream/main without auto-committing
4. Resolve the README.md conflict automatically
5. Sync Go dependencies (`go mod tidy` and `go mod vendor`)
6. Regenerate README.md with downstream naming conventions
7. Stage all changes for review

After the script completes:

```bash
# Review the changes
git diff --staged

# If everything looks good, commit
git commit

# Push to downstream
git push downstream sync-downstream-YYYYMMDD-HHMM
```

## Manual Sync

If you prefer to sync manually or need to troubleshoot:

```bash
# Fetch latest changes
git fetch upstream
git fetch downstream

# Start from downstream main
git checkout downstream/main
git switch -c sync-downstream-YYYYMMDD

# Merge upstream (will show conflicts)
git merge upstream/main --no-commit

# Resolve README conflict (we'll regenerate it anyway)
git checkout --theirs README.md

# IMPORTANT: Sync dependencies BEFORE regenerating README
# The README generation tool needs consistent vendor directory
go mod tidy
go mod vendor

# Regenerate README with downstream naming
make update-readme-tools

# Stage changes
git add README.md vendor/

# Commit the merge
git commit
```

## Why This Order Matters

The order of operations is critical:

1. **`go mod tidy` and `go mod vendor` BEFORE `make update-readme-tools`**

   The README generation is done by a Go tool (`internal/tools/update-readme/main.go`). If the vendor directory is out of sync with `go.mod`, the tool will fail with "inconsistent vendoring" errors.

2. **Regenerate README AFTER resolving conflicts**

   Both upstream and downstream auto-generate `README.md` via `make update-readme-tools`. The downstream version includes different naming (e.g., "ossm" vs "kiali"). Rather than manually resolving conflicts, we regenerate the entire file with downstream naming after merging code changes.

## Understanding README Conflicts

The README.md file is **generated** by running:

```bash
make update-readme-tools
```

Both upstream and downstream run this command, but with different configurations:
- **Upstream**: Uses standard Kubernetes naming (e.g., "kiali")
- **Downstream**: Uses downstream-specific naming (e.g., "ossm")

This means:
- Every sync will have a README.md conflict (expected behavior)
- We don't manually resolve the conflict - we regenerate the file
- The `git checkout --theirs README.md` step just clears the conflict marker
- The `make update-readme-tools` step regenerates with correct downstream naming

## Common Issues

### "inconsistent vendoring" Error

**Problem**: Running `make update-readme-tools` before `go mod vendor`

**Solution**: Always run `go mod tidy && go mod vendor` before `make update-readme-tools`

### Unexpected README Content

**Problem**: README doesn't have downstream naming conventions

**Solution**: Ensure you're running `make update-readme-tools` on the downstream branch after merging, not before

### Merge Conflicts in Code Files

**Problem**: The sync script assumes only README.md conflicts

**Solution**: If there are code conflicts:
1. The script will stop at the merge step
2. Manually resolve code conflicts
3. Continue with the remaining steps from the manual sync workflow

## Testing the Sync

Before pushing, verify:

1. **README has downstream naming**:
   ```bash
   grep -i "ossm" README.md  # Should find downstream-specific terms
   ```

2. **Vendor directory is consistent**:
   ```bash
   go mod verify
   go mod vendor  # Should show "no changes"
   ```

3. **Tests pass**:
   ```bash
   make test
   ```

4. **Build succeeds**:
   ```bash
   make build
   ```

## Pushing to Downstream

After committing the merge:

```bash
# Push the sync branch
git push downstream sync-downstream-YYYYMMDD-HHMM

# Create a PR in the downstream repository
# Review and merge the PR
```

## Troubleshooting

If something goes wrong during the sync:

```bash
# Abort the merge and start over
git merge --abort
git switch main
git branch -D sync-downstream-YYYYMMDD
```

Then retry the sync process.

## Questions?

For issues specific to the sync process, consult the team or check the upstream repository's documentation.