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
HOST_OS="$(uname -s)"
SYSTEMD_SERVICE_NAME="knot.service"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
SYSTEMD_SERVICE_FILE="${SYSTEMD_USER_DIR}/${SYSTEMD_SERVICE_NAME}"
LAUNCHD_LABEL="projects.knot.knote"
LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_FILE="${LAUNCH_AGENT_DIR}/${LAUNCHD_LABEL}.plist"

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
    "With no argument, install or upgrade Knot, enable login startup, and start the server." \
    "With --uninstall, stop the managed server and remove its startup entry and executable." \
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

systemd_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

stop_auto_start() {
  case "${HOST_OS}" in
    Linux)
      if command -v systemctl >/dev/null 2>&1 && [ -f "${SYSTEMD_SERVICE_FILE}" ]; then
        systemctl --user stop "${SYSTEMD_SERVICE_NAME}" >/dev/null 2>&1 || true
      fi
      ;;
    Darwin)
      if command -v launchctl >/dev/null 2>&1 && [ -f "${LAUNCH_AGENT_FILE}" ]; then
        launchctl bootout "gui/$(id -u)" "${LAUNCH_AGENT_FILE}" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

remove_auto_start() {
  case "${HOST_OS}" in
    Linux)
      had_auto_start="false"
      if [ -f "${SYSTEMD_SERVICE_FILE}" ]; then
        had_auto_start="true"
      fi
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now "${SYSTEMD_SERVICE_NAME}" >/dev/null 2>&1 || true
      fi
      rm -f -- "${SYSTEMD_SERVICE_FILE}"
      rm -f -- "${SYSTEMD_USER_DIR}/default.target.wants/${SYSTEMD_SERVICE_NAME}"
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
      fi
      if [ "${had_auto_start}" = "true" ]; then
        say "Removed Knot systemd user service."
      fi
      ;;
    Darwin)
      had_auto_start="false"
      if [ -f "${LAUNCH_AGENT_FILE}" ]; then
        had_auto_start="true"
      fi
      stop_auto_start
      rm -f -- "${LAUNCH_AGENT_FILE}"
      if [ "${had_auto_start}" = "true" ]; then
        say "Removed Knot LaunchAgent."
      fi
      ;;
  esac
}

enable_auto_start() {
  knot_path="$1"
  require_command sed

  case "${HOST_OS}" in
    Linux)
      require_command systemctl
      mkdir -p "${SYSTEMD_USER_DIR}"
      escaped_knot_path="$(systemd_escape "${knot_path}")"
      escaped_server_addr="$(systemd_escape "${SERVER_ADDR}")"
      escaped_service_path="$(systemd_escape "${PATH}")"
      cat >"${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Knot Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="PATH=${escaped_service_path}"
ExecStart="${escaped_knot_path}" serve --addr "${escaped_server_addr}" --no-open
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
      systemctl --user daemon-reload || fail "systemd user manager is unavailable"
      systemctl --user enable "${SYSTEMD_SERVICE_NAME}" >/dev/null || fail "could not enable Knot systemd user service"
      say "Knot Server will start automatically when you sign in."
      ;;
    Darwin)
      require_command launchctl
      require_command id
      mkdir -p "${LAUNCH_AGENT_DIR}" "${STATE_DIR}"
      escaped_knot_path="$(xml_escape "${knot_path}")"
      escaped_server_addr="$(xml_escape "${SERVER_ADDR}")"
      escaped_log_file="$(xml_escape "${LOG_FILE}")"
      escaped_service_path="$(xml_escape "${PATH}")"
      cat >"${LAUNCH_AGENT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escaped_knot_path}</string>
    <string>serve</string>
    <string>--addr</string>
    <string>${escaped_server_addr}</string>
    <string>--no-open</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${escaped_service_path}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>${escaped_log_file}</string>
  <key>StandardErrorPath</key>
  <string>${escaped_log_file}</string>
  <key>ThrottleInterval</key>
  <integer>5</integer>
</dict>
</plist>
EOF
      say "Knot Server will start automatically when you sign in."
      ;;
    *)
      fail "unsupported operating system: ${HOST_OS}"
      ;;
  esac
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
  if [ "${KNOT_NO_START:-}" = "1" ]; then
    return
  fi
  if server_is_ready; then
    say "Knot Server is already running at ${SERVER_URL}."
    return
  fi

  say "Starting Knot Server at ${SERVER_URL}..."
  case "${HOST_OS}" in
    Linux)
      systemctl --user start "${SYSTEMD_SERVICE_NAME}" || fail "could not start Knot systemd user service"
      ;;
    Darwin)
      launchctl bootstrap "gui/$(id -u)" "${LAUNCH_AGENT_FILE}" || fail "could not load Knot LaunchAgent"
      ;;
    *)
      fail "unsupported operating system: ${HOST_OS}"
      ;;
  esac

  attempts=0
  while [ "${attempts}" -lt 30 ]; do
    if server_is_ready; then
      say "Knot Server started in the background."
      return
    fi
    sleep 1
    attempts=$((attempts + 1))
  done

  if [ "${HOST_OS}" = "Darwin" ] && command -v tail >/dev/null 2>&1; then
    tail -n 20 "${LOG_FILE}" >&2 || true
  elif [ "${HOST_OS}" = "Linux" ]; then
    systemctl --user status "${SYSTEMD_SERVICE_NAME}" --no-pager >&2 || true
  fi
  stop_auto_start
  fail "Knot Server did not become ready within 30 seconds"
}

uninstall_knot() {
  installed_path="$(managed_binary)"
  if [ -z "${installed_path}" ]; then
    remove_auto_start
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

  remove_auto_start
  stop_knot "${installed_path}"
  installed_dir="$(dirname "${installed_path}")"
  [ -w "${installed_dir}" ] || fail "cannot remove ${installed_path} without elevated permission"
  rm -f -- "${installed_path}"

  say "Knot executable removed from ${installed_path}."
  say "User data was kept."
}

install_or_upgrade() {
  require_command curl
  require_command chmod
  require_command install
  require_command uname
  require_command awk
  require_command mktemp

  case "${HOST_OS}" in
    Linux) target_os="linux" ;;
    Darwin) target_os="darwin" ;;
    *) fail "unsupported operating system: ${HOST_OS}" ;;
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
    stop_auto_start
    stop_knot "${INSTALL_PATH}"
    enable_auto_start "${INSTALL_PATH}"
    start_knot
    return
  fi

  if [ -n "${current_version}" ]; then
    say "Upgrading Knot ${current_version} to ${target_version}..."
    upgrading="true"
  else
    say "Installing Knot ${target_version}..."
  fi

  asset_name="knot-${release_tag}-${target_os}-${target_arch}"
  download_base="https://github.com/${REPOSITORY}/releases/download/${release_tag}"
  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/knot-install.XXXXXX")"

  cleanup() {
    if [ -n "${temporary_dir:-}" ] && [ -d "${temporary_dir}" ]; then
      rm -rf -- "${temporary_dir}"
    fi
  }
  trap cleanup EXIT HUP INT TERM

  asset_marker="\"name\":\"${asset_name}\""
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
    ""|*[!0-9a-f]*) fail "GitHub release metadata has no valid SHA-256 digest for ${asset_name}" ;;
  esac
  [ "${#expected_checksum}" -eq 64 ] || fail "GitHub release metadata has an invalid SHA-256 digest for ${asset_name}"

  source_binary="${temporary_dir}/${asset_name}"
  curl -fsSL --retry 3 --retry-delay 1 -o "${source_binary}" "${download_base}/${asset_name}"

  if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum="$(sha256sum "${source_binary}" | awk '{ print $1 }')"
  elif command -v shasum >/dev/null 2>&1; then
    actual_checksum="$(shasum -a 256 "${source_binary}" | awk '{ print $1 }')"
  else
    fail "sha256sum or shasum is required to verify the download"
  fi

  [ "${actual_checksum}" = "${expected_checksum}" ] || fail "checksum verification failed for ${asset_name}"
  say "Checksum verified against GitHub release metadata."

  chmod 0755 "${source_binary}"
  downloaded_version="$("${source_binary}" version 2>/dev/null | awk 'NR == 1 { print $2 }' || true)"
  [ "${downloaded_version}" = "${target_version}" ] || fail "downloaded binary failed version verification"

  if [ "${upgrading}" = "true" ]; then
    stop_auto_start
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
  enable_auto_start "${INSTALL_PATH}"
  start_knot
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
