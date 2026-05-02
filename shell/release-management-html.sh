#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSET_NAME="management.html"
ASSET_PATH="dist/${ASSET_NAME}"
REMOTE="origin"
REPO=""
SKIP_INSTALL=0
ALLOW_DIRTY=0

usage() {
  cat <<EOF
Usage:
  shell/${SCRIPT_NAME} <version> [options]

Examples:
  shell/${SCRIPT_NAME} v6.10.0-usage.2
  shell/${SCRIPT_NAME} v6.10.0-usage.2 --skip-install
  shell/${SCRIPT_NAME} v6.10.0-usage.2 --repo uluckyXH/Cli-Proxy-API-Management-Center

Options:
  --repo <owner/repo>   GitHub repository for the release. Defaults to parsing origin.
  --remote <name>       Git remote used to check whether the tag exists. Default: origin.
  --skip-install        Skip npm ci and use existing node_modules.
  --allow-dirty         Allow releasing from a dirty working tree.
  -h, --help            Show this help message.

Environment:
  REPO=<owner/repo>      Same as --repo.
  REMOTE=<name>          Same as --remote.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

parse_origin_repo() {
  local url owner_repo
  url="$(git remote get-url "${REMOTE}" 2>/dev/null || true)"
  [[ -n "${url}" ]] || return 1

  case "${url}" in
    git@github.com:*)
      owner_repo="${url#git@github.com:}"
      owner_repo="${owner_repo%.git}"
      ;;
    https://github.com/*)
      owner_repo="${url#https://github.com/}"
      owner_repo="${owner_repo%.git}"
      ;;
    *)
      return 1
      ;;
  esac

  [[ "${owner_repo}" == */* ]] || return 1
  printf '%s\n' "${owner_repo}"
}

version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      REPO="$2"
      shift 2
      ;;
    --remote)
      [[ $# -ge 2 ]] || die "--remote requires a value"
      REMOTE="$2"
      shift 2
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [[ -n "${version}" ]]; then
        die "unexpected argument: $1"
      fi
      version="$1"
      shift
      ;;
  esac
done

[[ -n "${version}" ]] || {
  usage
  exit 1
}
[[ "${version}" == v* ]] || die "version must start with v, for example v6.10.0-usage.2"

require_command git
require_command npm
require_command gh
require_command shasum

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a Git repository"
cd "${repo_root}"

[[ -f package.json ]] || die "package.json not found; run this script from the frontend repository"

if [[ -z "${REPO}" ]]; then
  REPO="$(parse_origin_repo || true)"
fi
[[ -n "${REPO}" ]] || die "cannot infer GitHub repo from ${REMOTE}; pass --repo owner/repo"

if [[ "${ALLOW_DIRTY}" != "1" && -n "$(git status --porcelain)" ]]; then
  git status --short
  die "working tree is dirty. Commit/stash changes or pass --allow-dirty intentionally."
fi

target_commit="$(git rev-parse HEAD)"

info "Release target"
printf 'Version: %s\n' "${version}"
printf 'Repo:    %s\n' "${REPO}"
printf 'Remote:  %s\n' "${REMOTE}"
printf 'Commit:  %s\n' "$(git rev-parse --short HEAD)"

if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
  die "local tag already exists: ${version}"
fi

if git ls-remote --exit-code --tags "${REMOTE}" "refs/tags/${version}" >/dev/null 2>&1; then
  die "remote tag already exists on ${REMOTE}: ${version}"
fi

if gh release view "${version}" --repo "${REPO}" >/dev/null 2>&1; then
  die "GitHub Release already exists: ${version}"
fi

info "Checking GitHub CLI auth"
gh auth status >/dev/null

if [[ "${SKIP_INSTALL}" == "1" ]]; then
  info "Skipping npm ci"
else
  info "Installing dependencies with npm ci"
  npm ci
fi

info "Building single-file management UI"
VERSION="${version}" npm run build

[[ -f dist/index.html ]] || die "build did not produce dist/index.html"

info "Preparing release asset"
cp dist/index.html "${ASSET_PATH}"
sha256="$(shasum -a 256 "${ASSET_PATH}" | awk '{print $1}')"
ls -lh "${ASSET_PATH}"
printf 'SHA256: %s\n' "${sha256}"

notes="Management Center ${version}

- Built from commit $(git rev-parse --short HEAD)
- Asset: ${ASSET_NAME}
- SHA256: ${sha256}
"

info "Creating GitHub Release"
gh release create "${version}" "${ASSET_PATH}" \
  --repo "${REPO}" \
  --target "${target_commit}" \
  --title "${version}" \
  --notes "${notes}"

info "Release complete"
printf 'Release: https://github.com/%s/releases/tag/%s\n' "${REPO}" "${version}"
