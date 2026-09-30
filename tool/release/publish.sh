#!/usr/bin/env bash
set -euo pipefail
: "${GITHUB_REPOSITORY:?}" "${RELEASE_TAG:?}" "${RELEASE_COMMIT:?}" "${APP_VERSION:?}" "${RUNNER_TEMP:?}"
PRERELEASE="${PRERELEASE:-true}"
REQUIRE_EXISTING_DRAFT="${REQUIRE_EXISTING_DRAFT:-false}"
DIST_DIR="${DIST_DIR:-dist}"
RELEASE_NOTES="${RELEASE_NOTES:-docs/release-notes.md}"
release_tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$GITHUB_REPOSITORY" =~ ^[[:alnum:]_.-]+/[[:alnum:]_.-]+$ ]]
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
[[ "$RELEASE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$PRERELEASE" == true || "$PRERELEASE" == false ]]
python "$release_tools/verify_dist.py" "$DIST_DIR" --version "$APP_VERSION"

if git ls-remote --exit-code origin "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
  git fetch origin "refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
  [[ "$(git rev-parse "refs/tags/$RELEASE_TAG^{commit}")" == "$RELEASE_COMMIT" ]] || { echo 'Release tag changed since validation.'; exit 1; }
fi
release_list="$RUNNER_TEMP/release-list.json"
release_json="$RUNNER_TEMP/release-by-id.json"
manifest_json="$RUNNER_TEMP/release-assets.json"
write_manifest() {
  if [[ "$REQUIRE_EXISTING_DRAFT" == true ]]; then
    python "$release_tools/draft_release.py" manifest --input "$release_json" --output "$manifest_json" --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT" --require-digests
  else
    python "$release_tools/draft_release.py" manifest --input "$release_json" --output "$manifest_json" --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT"
  fi
}
gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100" > "$release_list"
release_id=$(python "$release_tools/draft_release.py" find --input "$release_list" --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT")
if [[ -z "$release_id" ]]; then
  [[ "$REQUIRE_EXISTING_DRAFT" != true ]] || { echo 'Recovery requires the existing validated draft.'; exit 1; }
  # The release list can lag creation. Use the validated POST response rather
  # than rediscovering the new draft through an eventually consistent list.
  python "$release_tools/draft_release.py" payload --draft --output "$RUNNER_TEMP/release-create.json" --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT" --prerelease "$PRERELEASE" --notes "$RELEASE_NOTES"
  gh api --method POST "repos/$GITHUB_REPOSITORY/releases" --input "$RUNNER_TEMP/release-create.json" > "$release_json"
  release_id=$(python "$release_tools/draft_release.py" id --input "$release_json" --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT")
else
  gh api "repos/$GITHUB_REPOSITORY/releases/$release_id" > "$release_json"
fi
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || { echo 'A numeric draft release ID is required.'; exit 1; }
write_manifest
if python "$release_tools/verify_dist.py" "$DIST_DIR" --version "$APP_VERSION" --remote-manifest "$manifest_json" > "$RUNNER_TEMP/release-asset-check.log" 2>&1; then
  cat "$RUNNER_TEMP/release-asset-check.log"
else
  if [[ "$REQUIRE_EXISTING_DRAFT" == true ]]; then
    cat "$RUNNER_TEMP/release-asset-check.log"
    echo 'Existing recovery assets differ; the draft is preserved without replacement.'
    exit 1
  fi
  gh release upload "$RELEASE_TAG" "$DIST_DIR"/* --clobber
  gh api "repos/$GITHUB_REPOSITORY/releases/$release_id" > "$release_json"
  write_manifest
  python "$release_tools/verify_dist.py" "$DIST_DIR" --version "$APP_VERSION" --remote-manifest "$manifest_json"
fi
python "$release_tools/draft_release.py" payload --output "$RUNNER_TEMP/release-publish.json" --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT" --prerelease "$PRERELEASE" --notes "$RELEASE_NOTES"
gh api --method PATCH "repos/$GITHUB_REPOSITORY/releases/$release_id" --input "$RUNNER_TEMP/release-publish.json" --jq .html_url
