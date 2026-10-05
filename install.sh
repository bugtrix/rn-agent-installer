#!/bin/sh
# rn-agent installer.
#
#   curl -fsSL https://bugtrix.dev/rn-agent/install | sh
#
# Installs the Python agent into a private virtualenv (the same place as
# `npm install -g rn-agent`) and puts a launcher on PATH. Re-run to upgrade.
#
#   curl -fsSL https://bugtrix.dev/rn-agent/install | sh -s -- --uninstall
#
# Overrides:
#   RN_AGENT_PYTHON     interpreter to use (must be 3.11+)
#   RN_AGENT_RUNTIME    virtualenv directory
#   RN_AGENT_BIN_DIR    directory for the launcher (default: ~/.local/bin)
#   RN_AGENT_VERSION    pin a release, e.g. 0.1.0
#   RN_AGENT_PIP_SPEC   full pip requirement (overrides RN_AGENT_VERSION)
#   RN_AGENT_NO_MODIFY_PATH=1   do not edit the shell rc file

set -eu

MARKER_BEGIN="# >>> rn-agent initialize >>>"
MARKER_END="# <<< rn-agent initialize <<<"
LAUNCHER_MARK="rn-agent launcher — managed by the installer"

say() {
  printf 'rn-agent: %s\n' "$*"
}

die() {
  printf 'rn-agent: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Install rn-agent:

  curl -fsSL https://bugtrix.dev/rn-agent/install | sh

Upgrade by running the same command again.

Uninstall:

  curl -fsSL https://bugtrix.dev/rn-agent/install | sh -s -- --uninstall

The agent is installed into a private virtualenv. System Python packages
are left alone. Python 3.11 or newer is required.
EOF
}

python_ok() {
  command -v "$1" >/dev/null 2>&1 || return 1
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

find_python() {
  if [ -n "${RN_AGENT_PYTHON:-}" ]; then
    if python_ok "$RN_AGENT_PYTHON"; then
      PYTHON=$RN_AGENT_PYTHON
      return 0
    fi
    die "RN_AGENT_PYTHON=$RN_AGENT_PYTHON is not Python 3.11 or newer"
  fi

  for candidate in \
    python3.13 python3.12 python3.11 python3 python \
    /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
    /usr/local/bin/python3.13 /usr/local/bin/python3.12 /usr/local/bin/python3.11
  do
    if python_ok "$candidate"; then
      PYTHON=$candidate
      return 0
    fi
  done
  return 1
}

python_missing() {
  hint="install Python 3.11 or newer and re-run this installer"
  case "$(uname -s)" in
    Darwin) hint="brew install python@3.12" ;;
    Linux) hint="sudo apt install python3.12 python3.12-venv" ;;
  esac
  cat >&2 <<EOF
rn-agent: Python 3.11 or newer was not found on PATH.

Install it:
  $hint

Already installed somewhere else? Point the installer at it:
  curl -fsSL https://bugtrix.dev/rn-agent/install | RN_AGENT_PYTHON=/full/path/to/python3.12 sh
EOF
  exit 1
}

venv_python_path() {
  if [ -x "$1/bin/python3" ]; then
    printf '%s\n' "$1/bin/python3"
  else
    printf '%s\n' "$1/bin/python"
  fi
}

runtime_dir() {
  if [ -n "${RN_AGENT_RUNTIME:-}" ]; then
    printf '%s\n' "$RN_AGENT_RUNTIME"
    return
  fi
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "$HOME/Library/Caches/rn-agent/runtime"
      ;;
    Linux)
      printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/rn-agent/runtime"
      ;;
    *)
      die "unsupported system: $(uname -s). rn-agent installs on macOS and Linux."
      ;;
  esac
}

shell_rc() {
  shell_name=$(basename "${SHELL:-sh}")
  case "$shell_name" in
    zsh) printf '%s\n' "$HOME/.zshrc" ;;
    bash)
      if [ "$(uname -s)" = "Darwin" ]; then
        printf '%s\n' "$HOME/.bash_profile"
      else
        printf '%s\n' "$HOME/.bashrc"
      fi
      ;;
    *) printf '%s\n' "$HOME/.profile" ;;
  esac
}

shell_quote() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

on_path() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_path() {
  bin_dir=$1
  if on_path "$bin_dir"; then
    return 0
  fi

  if [ "${RN_AGENT_NO_MODIFY_PATH:-}" = "1" ]; then
    say "add this to your shell config, then open a new terminal:"
    say "  export PATH=\"$bin_dir:\$PATH\""
    return 0
  fi

  rc=$(shell_rc)
  if [ -f "$rc" ] && grep -qF "$MARKER_BEGIN" "$rc"; then
    say "PATH entry is already in $rc"
    say "open a new terminal, or run: export PATH=\"$bin_dir:\$PATH\""
    return 0
  fi

  if [ "$bin_dir" = "$HOME/.local/bin" ]; then
    path_line='export PATH="$HOME/.local/bin:$PATH"'
  else
    quoted=$(shell_quote "$bin_dir")
    path_line="export PATH='$quoted':\"\$PATH\""
  fi

  {
    printf '\n%s\n' "$MARKER_BEGIN"
    printf '%s\n' "$path_line"
    printf '%s\n' "$MARKER_END"
  } >>"$rc"
  say "added $bin_dir to PATH in $rc"
  say "open a new terminal, or run: export PATH=\"$bin_dir:\$PATH\""
}

write_launcher() {
  cli=$1
  launcher=$2
  quoted=$(shell_quote "$cli")
  mkdir -p "$(dirname "$launcher")"
  cat >"$launcher" <<EOF
#!/bin/sh
# $LAUNCHER_MARK
exec '$quoted' "\$@"
EOF
  chmod 755 "$launcher"
}

pip_spec() {
  if [ -n "${RN_AGENT_PIP_SPEC:-}" ]; then
    printf '%s\n' "$RN_AGENT_PIP_SPEC"
    return
  fi
  if [ -n "${RN_AGENT_VERSION:-}" ]; then
    printf '%s\n' "rn-agent==$RN_AGENT_VERSION"
    return
  fi
  printf '%s\n' "rn-agent"
}

install_agent() {
  if [ "$(id -u)" -eq 0 ]; then
    say "running as root; the command will be installed for root only"
  fi

  case "$(uname -s)" in
    Darwin | Linux) ;;
    *) die "unsupported system: $(uname -s). rn-agent installs on macOS and Linux." ;;
  esac

  find_python || python_missing
  version=$("$PYTHON" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
  say "using Python $version ($PYTHON)"

  runtime=$(runtime_dir)
  bindir=${RN_AGENT_BIN_DIR:-$HOME/.local/bin}
  venv_python=$(venv_python_path "$runtime")
  cli=$runtime/bin/rn-agent
  launcher=$bindir/rn-agent
  spec=$(pip_spec)

  recreate=0
  if [ ! -x "$venv_python" ]; then
    recreate=1
  elif ! "$venv_python" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    recreate=1
  else
    venv_base=$("$venv_python" -c 'import sys; print(sys.base_prefix)')
    selected=$("$PYTHON" -c 'import sys; print(sys.prefix)')
    if [ "$venv_base" != "$selected" ]; then
      recreate=1
    fi
  fi

  if [ "$recreate" -eq 1 ]; then
    if [ -e "$runtime" ]; then
      if [ -f "$runtime/pyvenv.cfg" ] || [ -z "$(ls -A "$runtime" 2>/dev/null || true)" ]; then
        rm -rf "$runtime"
      else
        die "refusing to replace $runtime (not a virtualenv)"
      fi
    fi
    say "creating runtime in $runtime"
    if ! "$PYTHON" -m venv "$runtime"; then
      printf '%s\n' "rn-agent: could not create the Python virtual environment." >&2
      if [ "$(uname -s)" = "Linux" ]; then
        printf '%s\n' "rn-agent: on Debian/Ubuntu you may need: sudo apt install python3-venv" >&2
      fi
      exit 1
    fi
    venv_python=$(venv_python_path "$runtime")
  fi

  say "installing $spec"
  if ! "$venv_python" -m pip install --disable-pip-version-check --upgrade "$spec"; then
    printf '%s\n' "rn-agent: could not install the rn-agent Python package." >&2
    printf '%s\n' "rn-agent: check your network, or install it directly: pipx install rn-agent" >&2
    exit 1
  fi

  if [ ! -x "$cli" ]; then
    die "installation finished but $cli is missing"
  fi

  write_launcher "$cli" "$launcher"
  installed=$("$launcher" --version 2>&1) || die "installed, but \`$launcher --version\` failed: $installed"
  say "ready — $installed"
  say "command: $launcher"
  ensure_path "$bindir"
  say "open a React Native project and run: rn-agent"
}

strip_rc() {
  rc=$1
  [ -f "$rc" ] || return 0
  grep -qF "$MARKER_BEGIN" "$rc" || return 0
  tmp=$(mktemp)
  awk '
    index($0, begin) { skip = 1; next }
    index($0, end) { skip = 0; next }
    skip != 1 { print }
  ' begin="$MARKER_BEGIN" end="$MARKER_END" "$rc" >"$tmp"
  mv "$tmp" "$rc"
  say "removed PATH entry from $rc"
}

uninstall_agent() {
  runtime=$(runtime_dir)
  bindir=${RN_AGENT_BIN_DIR:-$HOME/.local/bin}
  launcher=$bindir/rn-agent

  if [ -f "$launcher" ] && grep -qF "$LAUNCHER_MARK" "$launcher"; then
    rm -f "$launcher"
    say "removed $launcher"
  elif [ -L "$launcher" ]; then
    target=$(readlink "$launcher" || true)
    case "$target" in
      "$runtime"/*)
        rm -f "$launcher"
        say "removed $launcher"
        ;;
    esac
  fi

  if [ -f "$runtime/pyvenv.cfg" ]; then
    rm -rf "$runtime"
    say "removed $runtime"
  fi

  strip_rc "$HOME/.zshrc"
  strip_rc "$HOME/.bashrc"
  strip_rc "$HOME/.bash_profile"
  strip_rc "$HOME/.profile"
  say "uninstalled"
}

main() {
  action=install
  for arg in "$@"; do
    case "$arg" in
      --uninstall) action=uninstall ;;
      -h | --help) action=help ;;
      *) die "unknown option: $arg (try --help)" ;;
    esac
  done

  case "$action" in
    help) usage ;;
    uninstall) uninstall_agent ;;
    install) install_agent ;;
  esac
}

main "$@"
