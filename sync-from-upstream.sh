#!/bin/bash
set -e

BRANCH_NAME="sync-downstream-$(date +%Y%m%d-%H%M)"

echo "🔄 Starting upstream sync..."
echo ""

git fetch upstream
git fetch downstream
git checkout downstream/main
git switch -c "$BRANCH_NAME"

echo ""
echo "🔀 Merging upstream/main..."
git merge upstream/main --no-commit

echo ""
echo "📝 Resolving README.md conflict..."
git checkout --theirs README.md

echo ""
echo "📦 Syncing Go dependencies..."
go mod tidy
go mod vendor

echo ""
echo "📄 Regenerating README with downstream naming..."
make update-readme-tools

echo ""
echo "➕ Staging changes..."
git add README.md vendor/

echo ""
echo "✅ Merge prepared on branch: $BRANCH_NAME"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff --staged"
echo "  2. Commit the merge: git commit"
echo "  3. Push to downstream: git push downstream $BRANCH_NAME"