#!/bin/sh

set -eu

REPOSITORY="knot-projects/knote"
PROGRAM="knot"

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_command curl
require_command install
require_command tar
require_command uname
require_command awk
require_command mktemp

case "$(uname -s)" in
  Linux) target_os="linux" ;;
  Darwin) target_os="darwin" ;;
  *) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) target_arch="amd64" ;;
  arm64|aarch64) target_arch="arm64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPOSITORY}/releases/latest")"
release_tag="${latest_url##*/}"
case "${release_tag}" in
  v[0-9]*) ;;
  *) fail "could not determine the latest release" ;;
esac

target_version="${release_tag#v}"
current_path="$(command -v "${PROGRAM}" 2>/dev/null || true)"
current_version=""

if [ -n "${current_path}" ] && [ -x "${current_path}" ]; then
  current_version="$("${current_path}" version 2>/dev/null | awk 'NR == 1 { print $2 }' || true)"
fi

if [ "${current_version}" = "${target_version}" ]; then
  say "Knot ${target_version} is already installed at ${current_path}."
  exit 0
fi

if [ -n "${current_version}" ]; then
  say "Upgrading Knot ${current_version} to ${target_version}..."
else
  say "Installing Knot ${target_version}..."
fi

package_name="knot-${release_tag}-${target_os}-${target_arch}"
archive_name="${package_name}.tar.gz"
download_base="https://github.com/${REPOSITORY}/releases/download/${release_tag}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/knot-install.XXXXXX")"

cleanup() {
  rm -rf -- "${temporary_dir}"
}
trap cleanup EXIT HUP INT TERM

curl -fsSL --retry 3 --retry-delay 1 -o "${temporary_dir}/${archive_name}" "${download_base}/${archive_name}"
curl -fsSL --retry 3 --retry-delay 1 -o "${temporary_dir}/SHA256SUMS" "${download_base}/SHA256SUMS"

expected_checksum="$(awk -v name="${archive_name}" '$2 == name { print $1; exit }' "${temporary_dir}/SHA256SUMS")"
[ -n "${expected_checksum}" ] || fail "${archive_name} is missing from SHA256SUMS"

if command -v sha256sum >/dev/null 2>&1; then
  actual_checksum="$(sha256sum "${temporary_dir}/${archive_name}" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual_checksum="$(shasum -a 256 "${temporary_dir}/${archive_name}" | awk '{ print $1 }')"
else
  fail "sha256sum or shasum is required to verify the download"
fi

[ "${actual_checksum}" = "${expected_checksum}" ] || fail "checksum verification failed for ${archive_name}"
say "Checksum verified."

tar -xzf "${temporary_dir}/${archive_name}" -C "${temporary_dir}"
source_binary="${temporary_dir}/${package_name}/${PROGRAM}"
[ -f "${source_binary}" ] || fail "downloaded archive does not contain ${PROGRAM}"

if [ -n "${KNOT_INSTALL_DIR:-}" ]; then
  install_dir="${KNOT_INSTALL_DIR}"
elif [ -n "${current_path}" ]; then
  case "${current_path}" in
    /*) install_dir="$(dirname "${current_path}")" ;;
    *) fail "cannot safely replace existing command at ${current_path}" ;;
  esac
else
  install_dir="/usr/local/bin"
fi

install_path="${install_dir}/${PROGRAM}"

if [ -d "${install_dir}" ] && [ -w "${install_dir}" ]; then
  install -m 0755 "${source_binary}" "${install_path}"
elif [ ! -e "${install_dir}" ] && mkdir -p "${install_dir}" 2>/dev/null; then
  install -m 0755 "${source_binary}" "${install_path}"
elif command -v sudo >/dev/null 2>&1; then
  say "Administrator permission is required to install to ${install_dir}."
  sudo mkdir -p "${install_dir}"
  sudo install -m 0755 "${source_binary}" "${install_path}"
elif [ -z "${current_path}" ]; then
  install_dir="${HOME}/.local/bin"
  install_path="${install_dir}/${PROGRAM}"
  mkdir -p "${install_dir}"
  install -m 0755 "${source_binary}" "${install_path}"
else
  fail "cannot replace ${current_path}; rerun with sufficient permission"
fi

installed_version="$("${install_path}" version 2>/dev/null | awk 'NR == 1 { print $2 }' || true)"
[ "${installed_version}" = "${target_version}" ] || fail "installed binary failed version verification"

say "Knot ${target_version} installed at ${install_path}."
case ":${PATH}:" in
  *:"${install_dir}":*) ;;
  *) say "Add ${install_dir} to PATH before running knot." ;;
esac
