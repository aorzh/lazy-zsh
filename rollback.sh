#!/usr/bin/env bash
# lazy-zsh / rollback.sh
# Undo install.sh and go back to bash.
#
# Usage:
#   ./rollback.sh                    show the plan, ask, then roll back
#   ./rollback.sh -y                 do not ask
#   ./rollback.sh --purge-packages   also apt-remove packages that install.sh installed
#
# Nothing is deleted: everything removed goes to ~/lazy-zsh-rollback-<timestamp>/

set -euo pipefail

NAME="lazy-zsh"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$NAME"
TS="$(date +%Y%m%d-%H%M%S)"
TRASH="$HOME/$NAME-rollback-$TS"
MARKER_RE='lazy-zsh|setup-zsh\.sh'
OMZ_TEMPLATE_RE='Path to your [Oo]h[ -][Mm]y[ -][Zz]sh installation'

ASSUME_YES=0; PURGE=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --purge-packages) PURGE=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "Run it as your normal user, not root." >&2
  exit 1
fi

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
state() { if [[ -s "$STATE_DIR/$1" ]]; then cat "$STATE_DIR/$1"; fi; }
to_trash() { mkdir -p "$TRASH"; mv "$1" "$TRASH/"; }
oldest_backup() { compgen -G "$1.bak.*" | sort | head -n1 || true; }

# --- what was there before install.sh
NO_STATE=0; [[ -d "$STATE_DIR" ]] || NO_STATE=1
case "$(state omz_preexisting)" in
  yes) OMZ_OURS=0 ;;
  *)   OMZ_OURS=1 ;;   # "no", or unknown (installed by an older version)
esac

# A backup is the user's original file unless it is ours or the oh-my-zsh template
is_original() {
  local f="$1"
  [[ -n "$f" ]] || return 1
  grep -qE "$MARKER_RE" "$f" && return 1
  if [[ $OMZ_OURS -eq 1 ]] && grep -qE "$OMZ_TEMPLATE_RE" "$f"; then return 1; fi
  return 0
}

CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
TARGET_SHELL="$(state original_shell)"
if [[ -z "$TARGET_SHELL" || "$TARGET_SHELL" == *zsh ]]; then
  if [[ "$CURRENT_SHELL" != *zsh ]]; then TARGET_SHELL="$CURRENT_SHELL"
  elif [[ -x /bin/bash ]]; then TARGET_SHELL=/bin/bash
  else TARGET_SHELL="$(command -v bash)"
  fi
fi
# /bin/bash and /usr/bin/bash are the same file on merged-/usr systems
[[ "$(readlink -f "$CURRENT_SHELL")" == "$(readlink -f "$TARGET_SHELL")" ]] && TARGET_SHELL="$CURRENT_SHELL"

INSTALL_TS="$(state install_ts)"
if [[ -z "$INSTALL_TS" && -f "$HOME/.zsh_history.bash-imported" ]]; then
  INSTALL_TS="$(stat -c %Y "$HOME/.zsh_history.bash-imported")"
fi

# --- plan
PLAN=()
[[ "$CURRENT_SHELL" != "$TARGET_SHELL" ]] && PLAN+=("change default shell: $CURRENT_SHELL -> $TARGET_SHELL")
for f in .zshrc .zsh_aliases; do
  p="$HOME/$f"; b="$(oldest_backup "$p")"
  if is_original "$b"; then PLAN+=("restore ~/$f from your original backup")
  elif [[ -e "$p" ]] && grep -qE "$MARKER_RE" "$p"; then PLAN+=("remove ~/$f (created by $NAME)")
  fi
done
grep -qsE "# added by ($MARKER_RE)" "$HOME/.zprofile" && PLAN+=("remove the $NAME lines from ~/.zprofile")
if [[ -e "$HOME/.zsh_history" ]]; then
  if [[ -n "$INSTALL_TS" ]]; then
    PLAN+=("copy commands typed in zsh since install to ~/.bash_history")
  else
    PLAN+=("(install time unknown: zsh history is NOT copied back to bash)")
  fi
  if [[ -n "$(oldest_backup "$HOME/.zsh_history")" ]]; then   # history is backed up only before import
    PLAN+=("restore ~/.zsh_history from the backup made before import")
  else
    PLAN+=("remove ~/.zsh_history")
  fi
fi
if [[ -d "$HOME/.oh-my-zsh" && $OMZ_OURS -eq 1 ]]; then
  note=""; [[ $NO_STATE -eq 1 ]] && note=" (no install record, assuming $NAME installed it)"
  PLAN+=("remove ~/.oh-my-zsh$note")
fi
compgen -G "$HOME/.zcompdump*" >/dev/null && PLAN+=("remove ~/.zcompdump* (zsh completion cache)")
PKGS=()
if [[ $PURGE -eq 1 ]]; then
  mapfile -t PKGS < <(state packages_installed | sort -u)
  if (( ${#PKGS[@]} )); then PLAN+=("apt remove: ${PKGS[*]}")
  else PLAN+=("(no record of packages installed by $NAME: nothing to remove)")
  fi
fi

if (( ${#PLAN[@]} == 0 )); then
  log "Nothing to roll back."
  exit 0
fi

echo "Rollback plan:"
printf '  - %s\n' "${PLAN[@]}"
echo "  Everything removed goes to $TRASH"
echo
if [[ $ASSUME_YES -eq 0 ]]; then
  if [[ ! -t 0 ]]; then echo "Not a terminal: re-run with -y to confirm." >&2; exit 1; fi
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Aborted."; exit 1; }
fi

# --- 1. default shell first, so nothing points to a removed zsh
if [[ "$CURRENT_SHELL" != "$TARGET_SHELL" ]]; then
  log "Changing default shell to $TARGET_SHELL (your password will be asked)"
  chsh -s "$TARGET_SHELL"
fi

# --- 2. config files
for f in .zshrc .zsh_aliases; do
  p="$HOME/$f"; b="$(oldest_backup "$p")"
  if is_original "$b"; then
    [[ -e "$p" ]] && to_trash "$p"
    cp -a "$b" "$p"
    log "restored ~/$f"
  elif [[ -e "$p" ]] && grep -qE "$MARKER_RE" "$p"; then
    to_trash "$p"
    log "removed ~/$f"
  fi
  for x in $(compgen -G "$p.bak.*" || true); do to_trash "$x"; done
done

if grep -qsE "# added by ($MARKER_RE)" "$HOME/.zprofile"; then
  mkdir -p "$TRASH"; cp -a "$HOME/.zprofile" "$TRASH/"
  sed -i -E "/# added by ($MARKER_RE)/,+1d" "$HOME/.zprofile"
  if ! grep -q '[^[:space:]]' "$HOME/.zprofile"; then
    rm -f "$HOME/.zprofile"      # only our lines were there; a copy is in $TRASH
  fi
  for x in $(compgen -G "$HOME/.zprofile.bak.*" || true); do to_trash "$x"; done
  log "cleaned ~/.zprofile"
fi

# --- 3. history: commands typed in zsh go back to bash
if [[ -e "$HOME/.zsh_history" ]]; then
  if [[ -n "$INSTALL_TS" ]]; then
    python3 - "$HOME/.zsh_history" "$HOME/.bash_history" "$INSTALL_TS" <<'PY'
import re, sys

zh, bh, since = sys.argv[1], sys.argv[2], int(sys.argv[3])
raw = open(zh, "rb").read()

# undo zsh "metafication": 0x83 + (byte ^ 0x20) -> byte
out, i = bytearray(), 0
while i < len(raw):
    if raw[i] == 0x83 and i + 1 < len(raw):
        out.append(raw[i + 1] ^ 0x20); i += 2
    else:
        out.append(raw[i]); i += 1

entries = []
for line in bytes(out).split(b"\n"):
    if entries and entries[-1][1].endswith(b"\\"):      # multi-line command
        entries[-1] = (entries[-1][0], entries[-1][1][:-1] + b"\n" + line)
        continue
    m = re.match(rb": (\d+):\d+;(.*)", line, re.S)
    if m:
        entries.append((int(m.group(1)), m.group(2)))

new = [cmd for ts, cmd in entries if ts >= since and cmd.strip()]
if new:
    prefix = b""
    try:
        with open(bh, "rb") as f:
            f.seek(-1, 2)
            if f.read(1) != b"\n":
                prefix = b"\n"
    except OSError:
        pass
    with open(bh, "ab") as f:
        f.write(prefix + b"\n".join(new) + b"\n")
print(f"copied {len(new)} commands to {bh}")
PY
  fi
  b="$(oldest_backup "$HOME/.zsh_history")"
  to_trash "$HOME/.zsh_history"
  if [[ -n "$b" ]]; then cp -a "$b" "$HOME/.zsh_history"; log "restored ~/.zsh_history"; fi
  for x in $(compgen -G "$HOME/.zsh_history.bak.*" || true); do to_trash "$x"; done
fi
[[ -e "$HOME/.zsh_history.bash-imported" ]] && to_trash "$HOME/.zsh_history.bash-imported"

# --- 4. oh-my-zsh
if [[ -d "$HOME/.oh-my-zsh" && $OMZ_OURS -eq 1 ]]; then
  to_trash "$HOME/.oh-my-zsh"
  log "removed ~/.oh-my-zsh"
fi

for x in $(compgen -G "$HOME/.zcompdump*" || true); do to_trash "$x"; done

# --- 5. packages (only with --purge-packages)
if (( ${#PKGS[@]} )); then
  log "Removing packages: ${PKGS[*]} (sudo)"
  sudo apt-get remove -y "${PKGS[@]}"
fi

# --- 6. install record
[[ -d "$STATE_DIR" ]] && to_trash "$STATE_DIR"

# --- terminals that still start zsh explicitly
TERMS="$(
  grep -nsE 'default_prog.*zsh' "$HOME/.wezterm.lua" "$HOME/.config/wezterm/wezterm.lua" || true
  grep -nsE '^Command=.*zsh' "$HOME"/.local/share/konsole/*.profile 2>/dev/null || true
  grep -nsE '"terminal\.integrated\.defaultProfile\.linux"[[:space:]]*:[[:space:]]*"zsh"' \
    "$HOME"/.config/*/User/settings.json 2>/dev/null || true
)"

echo
log "Rollback done."
if [[ -n "$TERMS" ]]; then
  warn "These terminal settings still start zsh, change them by hand:"
  echo "$TERMS" | sed "s|$HOME|~|; s|^|    |"
fi
[[ -d "$TRASH" ]] && echo "Removed files are in $TRASH - delete it when you are sure: rm -rf \"$TRASH\""
if [[ "$CURRENT_SHELL" != "$TARGET_SHELL" ]]; then
  echo
  printf '\033[1;33m%s\033[0m\n' "IMPORTANT: log out of your desktop session and log back in."
  printf '\033[1;33m%s\033[0m\n' "Closing the terminal is not enough, the default shell is picked up at login."
fi
exit 0
