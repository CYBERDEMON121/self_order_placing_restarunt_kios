#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
APP_DIR=${APP_DIR:-$SCRIPT_DIR}
SERVICE_NAME=${SERVICE_NAME:-mila-restaurant}
SERVICE_USER=${SERVICE_USER:-}
SERVICE_MODE=auto
CONFIG_DIR=${CONFIG_DIR:-/etc/mila-restaurant}
CONFIG_FILE=${CONFIG_FILE:-$CONFIG_DIR/environment}
SERVICE_FILE=${SERVICE_FILE:-}
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-4567}
ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
SESSION_SECRET=${SESSION_SECRET:-}
PUBLIC_BASE_URL=${PUBLIC_BASE_URL:-}
DATABASE_FILE=${DATABASE_FILE:-}
ORDER_RECORDS_FILE=${ORDER_RECORDS_FILE:-}
BUNDLE_JOBS=${BUNDLE_JOBS:-4}
SKIP_PACKAGES=0
SUDO=()

usage() {
  printf '%s\n' \
    "Usage: $SCRIPT_NAME [options]" \
    '' \
    'Options:' \
    '  --app-dir PATH       Application directory (default: script directory)' \
    '  --host ADDRESS       Bind address (default: 0.0.0.0)' \
    '  --port PORT          Bind port (default: 4567)' \
    '  --public-url URL     Base URL encoded in QR codes' \
    '  --admin-user NAME    Admin username (default: admin)' \
    '  --service-name NAME  systemd service name (default: mila-restaurant)' \
    '  --service-user USER  User that runs the service' \
    '  --config-dir PATH    Environment file directory' \
    '  --service            Require systemd installation and startup' \
    '  --no-service         Install dependencies without creating a service' \
    '  --skip-packages      Do not install operating-system packages' \
    '  --help               Show this help'
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)
      need_value "$1" "${2:-}"
      APP_DIR=$2
      shift 2
      ;;
    --host)
      need_value "$1" "${2:-}"
      HOST=$2
      shift 2
      ;;
    --port)
      need_value "$1" "${2:-}"
      PORT=$2
      shift 2
      ;;
    --public-url)
      need_value "$1" "${2:-}"
      PUBLIC_BASE_URL=$2
      shift 2
      ;;
    --admin-user)
      need_value "$1" "${2:-}"
      ADMIN_USERNAME=$2
      shift 2
      ;;
    --service-name)
      need_value "$1" "${2:-}"
      SERVICE_NAME=$2
      shift 2
      ;;
    --service-user)
      need_value "$1" "${2:-}"
      SERVICE_USER=$2
      shift 2
      ;;
    --config-dir)
      need_value "$1" "${2:-}"
      CONFIG_DIR=$2
      CONFIG_FILE=$CONFIG_DIR/environment
      shift 2
      ;;
    --service)
      SERVICE_MODE=required
      shift
      ;;
    --no-service)
      SERVICE_MODE=disabled
      shift
      ;;
    --skip-packages)
      SKIP_PACKAGES=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

SERVICE_FILE=${SERVICE_FILE:-/etc/systemd/system/$SERVICE_NAME.service}

[[ $(uname -s) == Linux ]] || fail 'This installer supports Linux only.'
[[ "$SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail 'Invalid systemd service name.'
[[ "$PORT" =~ ^[0-9]+$ ]] || fail 'PORT must be a number.'
[[ "$BUNDLE_JOBS" =~ ^[1-9][0-9]*$ ]] || fail 'BUNDLE_JOBS must be a positive integer.'

if [[ "$APP_DIR" != /* ]]; then
  APP_DIR="$PWD/$APP_DIR"
fi
[[ -d "$APP_DIR" ]] || fail "Application directory does not exist: $APP_DIR"
APP_DIR=$(cd -- "$APP_DIR" && pwd -P)
[[ -f "$APP_DIR/app.rb" && -f "$APP_DIR/Gemfile" ]] || fail 'app.rb and Gemfile must be in the application directory.'

for value in "$APP_DIR" "$CONFIG_DIR" "$CONFIG_FILE" "$SERVICE_FILE" "$HOST" "$PORT"; do
  [[ "$value" != *[$' \t\r\n']* ]] || fail "This installer cannot use whitespace in: $value"
done

if [[ -z "$DATABASE_FILE" ]]; then
  DATABASE_FILE="$APP_DIR/restaurant.sqlite3"
elif [[ "$DATABASE_FILE" != /* ]]; then
  DATABASE_FILE="$APP_DIR/$DATABASE_FILE"
fi
if [[ -z "$ORDER_RECORDS_FILE" ]]; then
  ORDER_RECORDS_FILE="$APP_DIR/order_records.json"
elif [[ "$ORDER_RECORDS_FILE" != /* ]]; then
  ORDER_RECORDS_FILE="$APP_DIR/$ORDER_RECORDS_FILE"
fi

if [[ -z "$PUBLIC_BASE_URL" ]]; then
  detected_ip=$(hostname -I 2>/dev/null || true)
  detected_ip=${detected_ip%% *}
  [[ -n "$detected_ip" ]] || detected_ip=127.0.0.1
  PUBLIC_BASE_URL="http://$detected_ip:$PORT"
fi
[[ "$PUBLIC_BASE_URL" != *$'\n'* && "$PUBLIC_BASE_URL" != *$'\r'* ]] || fail 'PUBLIC_BASE_URL cannot contain a newline.'

if [[ -z "$ADMIN_PASSWORD" ]]; then
  [[ -t 0 ]] || fail 'Set ADMIN_PASSWORD in the environment or run interactively.'
  read -r -s -p 'Admin password: ' ADMIN_PASSWORD
  printf '\n'
  read -r -s -p 'Confirm admin password: ' confirm_password
  printf '\n'
  [[ -n "$ADMIN_PASSWORD" && "$ADMIN_PASSWORD" == "$confirm_password" ]] || fail 'Passwords did not match.'
fi
[[ "$ADMIN_PASSWORD" != *$'\n'* && "$ADMIN_PASSWORD" != *$'\r'* ]] || fail 'ADMIN_PASSWORD cannot contain a newline.'

if [[ "$EUID" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 && SUDO=(sudo)
fi

if [[ -z "$SERVICE_USER" ]]; then
  if [[ -n "${SUDO_USER:-}" ]]; then
    SERVICE_USER=$SUDO_USER
  elif [[ "$EUID" -ne 0 ]]; then
    SERVICE_USER=$(id -un)
  fi
fi

as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  elif [[ ${#SUDO[@]} -gt 0 ]]; then
    "${SUDO[@]}" "$@"
  else
    fail 'Root privileges are required for this step.'
  fi
}

install_system_dependencies() {
  [[ "$SKIP_PACKAGES" -eq 0 ]] || return 0
  if command -v apt-get >/dev/null 2>&1; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ruby ruby-dev build-essential libsqlite3-dev pkg-config ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y ruby ruby-devel gcc make sqlite-devel pkgconf-pkg-config ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y ruby ruby-devel gcc make sqlite-devel pkgconfig ca-certificates
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -Sy --noconfirm ruby base-devel sqlite pkgconf
  elif command -v apk >/dev/null 2>&1; then
    as_root apk add --no-cache ruby ruby-dev build-base sqlite-dev pkgconf ca-certificates
  elif command -v zypper >/dev/null 2>&1; then
    as_root zypper --non-interactive install ruby ruby-devel gcc make sqlite3-devel pkg-config ca-certificates
  else
    fail 'No supported package manager was found. Use --skip-packages and install Ruby/build tools manually.'
  fi
}

install_system_dependencies
command -v ruby >/dev/null 2>&1 || fail 'Ruby was not installed.'
command -v gem >/dev/null 2>&1 || fail 'RubyGems was not installed.'

user_gem_bin=$(ruby -rrubygems -e 'print File.join(Gem.user_dir, "bin")')
export PATH="$user_gem_bin:$PATH"
hash -r
if ! command -v bundle >/dev/null 2>&1; then
  if [[ "$EUID" -eq 0 ]]; then
    gem install bundler --no-document || fail 'Unable to install Bundler for root.'
  else
    gem install --user-install bundler --no-document || fail 'Unable to install Bundler for the current user.'
  fi
fi
command -v bundle >/dev/null 2>&1 || fail 'Bundler is not available.'

cd -- "$APP_DIR"
bundle config set --local path "$APP_DIR/vendor/bundle"
bundle install --jobs "$BUNDLE_JOBS" --retry 3
BUNDLE_BIN=$(command -v bundle)
[[ -n "$BUNDLE_BIN" ]] || fail 'Unable to locate Bundler.'
bundle exec ruby -c app.rb
bundle exec ruby -e "require 'sqlite3'; require 'rqrcode'; require 'sinatra/base'; puts 'Dependencies are ready.'"

install_service() {
  [[ "$EUID" -eq 0 ]] || fail 'Systemd installation must run as root. Use sudo or run with --no-service.'
  command -v systemctl >/dev/null 2>&1 || fail 'systemctl was not found; use --no-service for a local install.'
  [[ -n "$SERVICE_USER" ]] || fail 'Set SERVICE_USER or pass --service-user when running directly as root.'
  id "$SERVICE_USER" >/dev/null 2>&1 || fail "Service user does not exist: $SERVICE_USER"
  SERVICE_GROUP=$(id -gn "$SERVICE_USER")
  if [[ "$EUID" -eq 0 && "$SERVICE_USER" != root ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$SERVICE_USER" -- test -w "$APP_DIR" || fail "$SERVICE_USER must have write access to $APP_DIR."
    if [[ -e "$DATABASE_FILE" ]]; then
      runuser -u "$SERVICE_USER" -- test -w "$DATABASE_FILE" || fail "$SERVICE_USER must have write access to $DATABASE_FILE."
    fi
    if [[ -e "$ORDER_RECORDS_FILE" ]]; then
      runuser -u "$SERVICE_USER" -- test -w "$ORDER_RECORDS_FILE" || fail "$SERVICE_USER must have write access to $ORDER_RECORDS_FILE."
    fi
  fi

  if [[ -z "$SESSION_SECRET" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      SESSION_SECRET=$(openssl rand -hex 64)
    else
      SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
    fi
  fi
  [[ "$SESSION_SECRET" != *$'\n'* && "$SESSION_SECRET" != *$'\r'* ]] || fail 'SESSION_SECRET cannot contain a newline.'

  install -d -m 0750 "$CONFIG_DIR"
  env_quote() {
    local value=${1-}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
  }
  umask 077
  {
    printf 'ADMIN_USERNAME=%s\n' "$(env_quote "$ADMIN_USERNAME")"
    printf 'ADMIN_PASSWORD=%s\n' "$(env_quote "$ADMIN_PASSWORD")"
    printf 'SESSION_SECRET=%s\n' "$(env_quote "$SESSION_SECRET")"
    printf 'PUBLIC_BASE_URL=%s\n' "$(env_quote "$PUBLIC_BASE_URL")"
    printf 'RACK_ENV=%s\n' "$(env_quote production)"
    printf 'DATABASE_FILE=%s\n' "$(env_quote "$DATABASE_FILE")"
    printf 'ORDER_RECORDS_FILE=%s\n' "$(env_quote "$ORDER_RECORDS_FILE")"
    printf 'BUNDLE_GEMFILE=%s\n' "$(env_quote "$APP_DIR/Gemfile")"
    printf 'BUNDLE_PATH=%s\n' "$(env_quote "$APP_DIR/vendor/bundle")"
  } > "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"

  install -d -m 0755 "$(dirname -- "$SERVICE_FILE")"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mila's Restaurant kiosk
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$APP_DIR
EnvironmentFile=$CONFIG_FILE
ExecStart=$BUNDLE_BIN exec ruby $APP_DIR/app.rb -o $HOST -p $PORT
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=20
NoNewPrivileges=true
PrivateTmp=true
UMask=0077
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME.service"
  systemctl is-active --quiet "$SERVICE_NAME.service" || fail "Service failed to start: $SERVICE_NAME"
  printf 'Service installed: %s\n' "$SERVICE_NAME"
  printf 'Configuration: %s\n' "$CONFIG_FILE"
}

if [[ "$SERVICE_MODE" == required ]]; then
  install_service
elif [[ "$SERVICE_MODE" == auto && "$EUID" -eq 0 && -x "$(command -v systemctl 2>/dev/null || true)" ]]; then
  install_service
else
  printf 'Dependencies installed. Service setup was skipped.\n'
  printf 'Run locally with: cd %q && bundle exec ruby app.rb -o %q -p %q\n' "$APP_DIR" "$HOST" "$PORT"
  printf 'Set ADMIN_PASSWORD, SESSION_SECRET, and PUBLIC_BASE_URL before starting the app.\n'
  exit 0
fi

printf 'Application URL: %s\n' "$PUBLIC_BASE_URL"
printf 'QR base URL: %s\n' "$PUBLIC_BASE_URL"
printf 'Admin login: %s\n' "$ADMIN_USERNAME"
printf 'Set ADMIN_PASSWORD and SESSION_SECRET only in the protected environment file.\n'
