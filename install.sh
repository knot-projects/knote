#!/bin/sh

set -eu

: "${HOME:?HOME must be set}"

REPOSITORY="knot-projects/knote"
PROGRAM="knot"
INSTALL_DIR="${KNOT_INSTALL_DIR:-${HOME}/.local/bin}"
INSTALL_PATH="${INSTALL_DIR}/${PROGRAM}"
STATE_DIR="${KNOT_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/knot}"
PID_FILE="${STATE_DIR}/server.pid"
LOG_FILE="${STATE_DIR}/server.log"
SERVER_ADDR="${KNOT_ADDR:-127.0.0.1:7330}"
SERVER_URL="http://${SERVER_ADDR}"

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

usage() {
  printf '%s\n' \
    "Usage: install.sh [--uninstall]" \
    "" \
    "With no argument, install or upgrade Knot and start the server." \
    "With --uninstall, stop the managed server and remove the executable." \
    "No root or sudo access is used."
}

managed_binary() {
  if [ -x "${INSTALL_PATH}" ]; then
    printf '%s\n' "${INSTALL_PATH}"
    return
  fi
  command -v "${PROGRAM}" 2>/dev/null || true
}

server_is_ready() {
  curl -fsS --max-time 2 "${SERVER_URL}/api/auth/status" >/dev/null 2>&1
}

stop_knot() {
  knot_path="$1"
  require_command ps

  if [ ! -f "${PID_FILE}" ]; then
    if server_is_ready; then
      fail "Knot Server is running at ${SERVER_URL}, but no managed PID was found; stop that process manually and retry"
    fi
    return
  fi

  IFS= read -r server_pid <"${PID_FILE}" || server_pid=""
  case "${server_pid}" in
    ""|*[!0-9]*)
      rm -f -- "${PID_FILE}"
      fail "invalid managed server PID"
      ;;
  esac

  if ! kill -0 "${server_pid}" 2>/dev/null; then
    rm -f -- "${PID_FILE}"
    return
  fi

  process_command="$(ps -p "${server_pid}" -o command= 2>/dev/null || true)"
  case "${process_command}" in
    "${knot_path} serve"*) ;;
    *) fail "PID ${server_pid} does not belong to the managed Knot Server" ;;
  esac

  say "Stopping Knot Server (PID ${server_pid})..."
  kill "${server_pid}"
  attempts=0
  while kill -0 "${server_pid}" 2>/dev/null && [ "${attempts}" -lt 15 ]; do
    sleep 1
    attempts=$((attempts + 1))
  done

  if kill -0 "${server_pid}" 2>/dev/null; then
    fail "Knot Server did not stop within 15 seconds"
  fi

  rm -f -- "${PID_FILE}"
  say "Knot Server stopped."
}

start_knot() {
  knot_path="$1"
  if [ "${KNOT_NO_START:-}" = "1" ]; then
    return
  fi
  if server_is_ready; then
    say "Knot Server is already running at ${SERVER_URL}."
    return
  fi

  require_command nohup
  mkdir -p "${STATE_DIR}"
  say "Starting Knot Server at ${SERVER_URL}..."
  nohup "${knot_path}" serve --addr "${SERVER_ADDR}" --no-open >"${LOG_FILE}" 2>&1 &
  server_pid=$!
  printf '%s\n' "${server_pid}" >"${PID_FILE}"

  attempts=0
  while [ "${attempts}" -lt 30 ]; do
    if server_is_ready; then
      say "Knot Server started (PID ${server_pid})."
      say "Log: ${LOG_FILE}"
      return
    fi
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      rm -f -- "${PID_FILE}"
      if command -v tail >/dev/null 2>&1; then
        tail -n 20 "${LOG_FILE}" >&2 || true
      fi
      fail "Knot Server exited before becoming ready"
    fi
    sleep 1
    attempts=$((attempts + 1))
  done

  kill "${server_pid}" 2>/dev/null || true
  rm -f -- "${PID_FILE}"
  fail "Knot Server did not become ready within 30 seconds"
}

uninstall_knot() {
  installed_path="$(managed_binary)"
  if [ -z "${installed_path}" ]; then
    say "Knot is not installed."
    return
  fi

  case "${installed_path}" in
    /*) ;;
    *) fail "cannot safely remove command at ${installed_path}" ;;
  esac

  installed_identity="$("${installed_path}" version 2>/dev/null || true)"
  case "${installed_identity}" in
    knot\ *) ;;
    *) fail "${installed_path} does not identify itself as Knot" ;;
  esac

  stop_knot "${installed_path}"
  installed_dir="$(dirname "${installed_path}")"
  [ -w "${installed_dir}" ] || fail "cannot remove ${installed_path} without elevated permission"
  rm -f -- "${installed_path}"

  say "Knot executable removed from ${installed_path}."
  say "User data was kept."
}

install_or_upgrade() {
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

  release_json="$(curl -fsSL --retry 3 --retry-delay 1 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: Knot-Installer" \
    "https://api.github.com/repos/${REPOSITORY}/releases/latest")"
  release_tag="$(
    printf '%s\n' "${release_json}" |
      awk '{
        marker = "\"tag_name\":"
        start = index($0, marker)
        if (start == 0) exit
        value = substr($0, start + length(marker))
        sub(/^[[:space:]]*\"/, "", value)
        finish = index(value, "\"")
        if (finish > 1) print substr(value, 1, finish - 1)
      }'
  )"
  case "${release_tag}" in
    v[0-9]*) ;;
    *) fail "could not determine the latest release" ;;
  esac

  target_version="${release_tag#v}"
  current_version=""
  upgrading="false"
  if [ -x "${INSTALL_PATH}" ]; then
    current_version="$("${INSTALL_PATH}" version 2>/dev/null | awk 'NR == 1 { print $2 }' || true)"
  fi

  if [ "${current_version}" = "${target_version}" ]; then
    say "Knot ${target_version} is already installed at ${INSTALL_PATH}."
    start_knot "${INSTALL_PATH}"
    return
  fi

  if [ -n "${current_version}" ]; then
    say "Upgrading Knot ${current_version} to ${target_version}..."
    upgrading="true"
  else
    say "Installing Knot ${target_version}..."
  fi

  package_name="knot-${release_tag}-${target_os}-${target_arch}"
  archive_name="${package_name}.tar.gz"
  download_base="https://github.com/${REPOSITORY}/releases/download/${release_tag}"
  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/knot-install.XXXXXX")"

  cleanup() {
    if [ -n "${temporary_dir:-}" ] && [ -d "${temporary_dir}" ]; then
      rm -rf -- "${temporary_dir}"
    fi
  }
  trap cleanup EXIT HUP INT TERM

  asset_marker="\"name\":\"${archive_name}\""
  expected_checksum="$(
    printf '%s\n' "${release_json}" |
      awk -v marker="${asset_marker}" '{
        start = index($0, marker)
        if (start == 0) exit
        value = substr($0, start + length(marker))
        digest_marker = "\"digest\":\"sha256:"
        digest_start = index(value, digest_marker)
        if (digest_start == 0) exit
        print substr(value, digest_start + length(digest_marker), 64)
      }'
  )"
  case "${expected_checksum}" in
    ""|*[!0-9a-f]*) fail "GitHub release metadata has no valid SHA-256 digest for ${archive_name}" ;;
  esac
  [ "${#expected_checksum}" -eq 64 ] || fail "GitHub release metadata has an invalid SHA-256 digest for ${archive_name}"

  curl -fsSL --retry 3 --retry-delay 1 -o "${temporary_dir}/${archive_name}" "${download_base}/${archive_name}"

  if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum="$(sha256sum "${temporary_dir}/${archive_name}" | awk '{ print $1 }')"
  elif command -v shasum >/dev/null 2>&1; then
    actual_checksum="$(shasum -a 256 "${temporary_dir}/${archive_name}" | awk '{ print $1 }')"
  else
    fail "sha256sum or shasum is required to verify the download"
  fi

  [ "${actual_checksum}" = "${expected_checksum}" ] || fail "checksum verification failed for ${archive_name}"
  say "Checksum verified against GitHub release metadata."

  tar -xzf "${temporary_dir}/${archive_name}" -C "${temporary_dir}"
  source_binary="${temporary_dir}/${package_name}/${PROGRAM}"
  [ -f "${source_binary}" ] || fail "downloaded archive does not contain ${PROGRAM}"

  if [ "${upgrading}" = "true" ]; then
    stop_knot "${INSTALL_PATH}"
  fi

  mkdir -p "${INSTALL_DIR}"
  [ -w "${INSTALL_DIR}" ] || fail "install directory is not writable: ${INSTALL_DIR}"
  install -m 0755 "${source_binary}" "${INSTALL_PATH}"

  installed_version="$("${INSTALL_PATH}" version 2>/dev/null | awk 'NR == 1 { print $2 }' || true)"
  [ "${installed_version}" = "${target_version}" ] || fail "installed binary failed version verification"

  say "Knot ${target_version} installed at ${INSTALL_PATH}."
  case ":${PATH}:" in
    *:"${INSTALL_DIR}":*) ;;
    *) say "Add ${INSTALL_DIR} to PATH: export PATH=\"${INSTALL_DIR}:\$PATH\"" ;;
  esac

  cleanup
  temporary_dir=""
  start_knot "${INSTALL_PATH}"
}

case "${1:-}" in
  "")
    install_or_upgrade
    ;;
  --uninstall)
    [ "$#" -eq 1 ] || fail "--uninstall does not accept additional arguments"
    uninstall_knot
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    fail "unknown argument: $1"
    ;;
esac
