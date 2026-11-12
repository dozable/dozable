#!/bin/bash
# fence-read-probe.sh — DEV ONLY, READ-ONLY of the real home.
#
# Runs the fenced session's READ ALLOWLIST (the home is closed except the toolchain roots, the PATH entries and the
# executables their links resolve to, ~/.ssh/config and *.pub) against THIS Mac's real home, with everyday tools, and
# lists every refusal the kernel logs for it. The fence itself keeps the run read-only: the only writable places are a
# scratch folder under /private/tmp (work/, tmp/, cache/), removed at the end. Nothing of doz runs; no store is used.
#
# The profile written here is a hand copy of what `MacFenceProfile` renders (agent kind, no network, Keychain closed);
# keep the two in step when either changes.
#
# Usage: Scripts/fence-read-probe.sh [--keep]     (output: the scratch folder's report.txt, printed at the end)
set -u
umask 077

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

HOME_DIR=$(/usr/bin/python3 -c 'import pwd,os;print(pwd.getpwuid(os.getuid()).pw_dir)')
TAG=$(/usr/bin/openssl rand -hex 8)
SCRATCH=$(/usr/bin/mktemp -d /private/tmp/doz-fence-probe.XXXXXX)
SCRATCH=$(/bin/realpath "$SCRATCH")
WORK="$SCRATCH/work"; TMPD="$SCRATCH/tmp"; CACHE="$SCRATCH/cache"; ETC="$SCRATCH/etc"; OUT="$SCRATCH/out"
/bin/mkdir -p "$WORK" "$TMPD" "$CACHE" "$ETC/git-template" "$OUT"
PROFILE="$SCRATCH/fence.sb"
REPORT="$SCRATCH/report.txt"

# The login shell's PATH (what a session gets), read once outside the fence.
LOGIN_PATH=$("${SHELL:-/bin/zsh}" -lc 'printf %s "$PATH"' 2>/dev/null </dev/null)

q() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# The --read refusal list: the home, /, a parent of the home, ~/.config, ~/.ssh, ~/Library, ~/Library/Keychains — or a
# folder containing one of those.
refused_folder() {
  local d=$1
  case "$d" in
    /|"$HOME_DIR"|"$HOME_DIR/") return 0 ;;
  esac
  case "$HOME_DIR/" in "$d"/*) return 0 ;; esac            # a parent of the home
  local p
  for p in "$HOME_DIR/.config" "$HOME_DIR/.ssh" "$HOME_DIR/Library" "$HOME_DIR/Library/Keychains"; do
    [ "$d" = "$p" ] && return 0
    case "$p/" in "$d"/*) return 0 ;; esac                 # contains one
  done
  return 1
}
# A closed place a link is never followed into.
closed_place() {
  local t=$1 p
  for p in .ssh .config .aws .gnupg .claude .codex .cursor .gemini .snowflake .docker .kube Library/Keychains \
           "Library/Application Support" Library/Preferences Library/Cookies Library/Mail Library/Messages Library/Caches .cache; do
    case "$t" in "$HOME_DIR/$p"|"$HOME_DIR/$p/"*) return 0 ;; esac
  done
  case "$t" in "$HOME_DIR/.claude.json"|"$HOME_DIR/.netrc"|"$HOME_DIR/.npmrc"|"$HOME_DIR/.pypirc") return 0 ;; esac
  return 1
}
in_home() { case "$1" in "$HOME_DIR"/*) return 0 ;; esac; return 1; }

READS=()        # subpaths readable
READ_FILES=()   # literals readable
NOTES=()

for r in .nvm .volta .bun/bin .deno/bin .local/bin .local/share/uv .local/share/mise .local/pipx .asdf .tool-versions \
         .config/mise .pyenv .rbenv .cargo/bin .rustup go/bin .sdkman/candidates Library/pnpm Library/Developer/Toolchains; do
  [ -e "$HOME_DIR/$r" ] && READS+=("$HOME_DIR/$r")
done
[ -f "$HOME_DIR/.ssh/config" ] && READ_FILES+=("$HOME_DIR/.ssh/config")
for f in "$HOME_DIR"/.ssh/*.pub; do [ -f "$f" ] && READ_FILES+=("$f"); done

# A link target: its folder read-only (its install root when the folder is a bin/), unless that folder is refused —
# then only the file; never into a closed place.
covered() {
  local t=$1 p
  for p in ${READS[@]+"${READS[@]}"}; do case "$t" in "$p"|"$p"/*) return 0 ;; esac; done
  return 1
}
# A folder directly in the home (`~/.local`, `~/.hermes`) is too wide to open for one program.
top_level() { local rest=${1#"$HOME_DIR"/}; case "$rest" in */*) return 1 ;; esac; return 0; }
add_target() {
  local t=$1 from=$2 dir root
  in_home "$t" || return 0                                   # outside the home: the system roots decide
  covered "$t" && return 0
  if closed_place "$t"; then NOTES+=("not followed: $from -> $t (a closed place)"); return 0; fi
  dir=$(/usr/bin/dirname "$t")
  root=$dir
  [ "$(/usr/bin/basename "$dir")" = "bin" ] && root=$(/usr/bin/dirname "$dir")
  if refused_folder "$root" || closed_place "$root" || top_level "$root"; then root=$dir; fi
  if top_level "$root"; then READ_FILES+=("$t"); NOTES+=("file only: $from -> $t"); return 0; fi
  if refused_folder "$root" || closed_place "$root"; then READ_FILES+=("$t"); NOTES+=("file only: $from -> $t"); return 0; fi
  READS+=("$root")
}

IFS=: read -r -a PATH_DIRS <<<"$LOGIN_PATH"
for d in "${PATH_DIRS[@]}"; do
  [ -d "$d" ] || continue
  rd=$(/bin/realpath "$d" 2>/dev/null) || continue
  if in_home "$rd" || [ "$rd" = "$HOME_DIR" ]; then
    if refused_folder "$rd"; then NOTES+=("PATH entry refused: $d"); continue; fi
    if closed_place "$rd"; then NOTES+=("PATH entry in a closed place: $d"); continue; fi
    covered "$rd" || READS+=("$rd")
  fi
  # Every link in the folder: each hop and the final target.
  for e in "$rd"/*; do
    [ -L "$e" ] || continue
    cur=$e; hops=0
    while [ -L "$cur" ] && [ $hops -lt 8 ]; do
      nxt=$(/usr/bin/readlink "$cur")
      case "$nxt" in /*) ;; *) nxt="$(/usr/bin/dirname "$cur")/$nxt" ;; esac
      cur=$nxt; hops=$((hops + 1))
    done
    final=$(/bin/realpath "$e" 2>/dev/null) || continue
    [ -x "$final" ] || continue
    add_target "$final" "$e"
  done
done

# The git identity and excludes (host-written in the product from an allowlist of keys).
{
  printf '[user]\n'
  n=$(/usr/bin/git config --global user.name 2>/dev/null) && printf '\tname = %s\n' "$n"
  m=$(/usr/bin/git config --global user.email 2>/dev/null) && printf '\temail = %s\n' "$m"
  printf '[core]\n\texcludesFile = %s\n' "$ETC/excludes"
  printf '[init]\n\tdefaultBranch = main\n'
} >"$ETC/gitconfig"
: >"$ETC/excludes"

# SBPL ------------------------------------------------------------------------------------------------------------
{
  echo '(version 1)'
  echo "(deny default (with message \"doz-fence:$TAG\"))"
  echo '(allow process-fork)'
  echo '(allow process-exec)'
  echo '(allow signal (target same-sandbox))'
  echo '(allow process-info* (target same-sandbox))'
  echo '(allow file-read-metadata)'
  echo '(allow file-read* (literal "/"))'
  echo '(allow file-read* (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/Library")'
  echo '  (subpath "/Applications") (subpath "/opt") (subpath "/private/etc") (subpath "/private/var/db/timezone")'
  echo '  (subpath "/private/var/select") (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random")'
  echo '  (literal "/dev/zero") (literal "/dev/dtracehelper") (literal "/dev/autofs_nowait")'
  echo "  (literal $(q "$HOME_DIR/.CFUserTextEncoding")))"
  echo '(deny file-read* (subpath "/opt/homebrew/var"))'
  echo '(allow file-write-data (literal "/dev/null") (literal "/dev/dtracehelper"))'
  echo '(allow file-ioctl (literal "/dev/dtracehelper"))'
  echo '(allow file-read* file-write-data (subpath "/dev/fd"))'
  echo '(allow file-read* file-write* file-ioctl (literal "/dev/tty"))'
  for p in ${READS[@]+"${READS[@]}"}; do echo "(allow file-read* (subpath $(q "$p")))"; done
  for p in ${READ_FILES[@]+"${READ_FILES[@]}"}; do echo "(allow file-read* (literal $(q "$p")))"; done
  echo "(allow file-read* file-write* (subpath $(q "$WORK")) (subpath $(q "$TMPD")) (subpath $(q "$CACHE")))"
  echo "(allow file-read* (subpath $(q "$ETC")))"
  echo '(allow mach-lookup (global-name "com.apple.trustd") (global-name "com.apple.trustd.agent")'
  echo '  (global-name "com.apple.ocspd") (global-name "com.apple.networkd") (global-name "com.apple.SystemConfiguration.configd")'
  echo '  (global-name "com.apple.SystemConfiguration.DNSConfiguration") (global-name "com.apple.bsd.dirhelper")'
  echo '  (global-name "com.apple.system.opendirectoryd.membership") (global-name "com.apple.system.opendirectoryd.libinfo")'
  echo '  (global-name "com.apple.system.logger") (global-name "com.apple.system.notification_center") (global-name "com.apple.logd")'
  echo '  (global-name "com.apple.diagnosticd") (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent")'
  echo '  (global-name "com.apple.FSEvents"))'
  echo '(allow user-preference-read (preference-domain "kCFPreferencesAnyApplication") (preference-domain-prefix "com.apple."))'
  echo '(allow ipc-posix-shm* ipc-posix-sem)'
  echo '(allow sysctl-read (sysctl-name "hw.activecpu") (sysctl-name "hw.busfrequency_compat") (sysctl-name "hw.byteorder")'
  echo '  (sysctl-name "hw.cacheconfig") (sysctl-name "hw.cachelinesize_compat") (sysctl-name "hw.cpufamily")'
  echo '  (sysctl-name "hw.cpufrequency_compat") (sysctl-name "hw.cputype") (sysctl-name "hw.l1dcachesize_compat")'
  echo '  (sysctl-name "hw.l1icachesize_compat") (sysctl-name "hw.l2cachesize_compat") (sysctl-name "hw.l3cachesize_compat")'
  echo '  (sysctl-name "hw.logicalcpu_max") (sysctl-name "hw.machine") (sysctl-name "hw.memsize") (sysctl-name "hw.ncpu")'
  echo '  (sysctl-name "hw.nperflevels") (sysctl-name "hw.packages") (sysctl-name "hw.pagesize_compat") (sysctl-name "hw.pagesize")'
  echo '  (sysctl-name "hw.physicalcpu") (sysctl-name "hw.physicalcpu_max") (sysctl-name "hw.logicalcpu") (sysctl-name "hw.cpufrequency")'
  echo '  (sysctl-name "hw.tbfrequency_compat") (sysctl-name "hw.vectorunit") (sysctl-name "hw.model") (sysctl-name "hw.cachesize")'
  echo '  (sysctl-name-prefix "hw.optional.") (sysctl-name-prefix "hw.perflevel") (sysctl-name "machdep.cpu.brand_string")'
  echo '  (sysctl-name "kern.argmax") (sysctl-name "kern.hostname") (sysctl-name "kern.maxfilesperproc") (sysctl-name "kern.maxproc")'
  echo '  (sysctl-name "kern.osproductversion") (sysctl-name "kern.osrelease") (sysctl-name "kern.ostype")'
  echo '  (sysctl-name "kern.osvariant_status") (sysctl-name "kern.osversion") (sysctl-name "kern.secure_kernel")'
  echo '  (sysctl-name "kern.usrstack64") (sysctl-name "kern.version") (sysctl-name "kern.boottime") (sysctl-name "sysctl.proc_cputype")'
  echo '  (sysctl-name "vm.loadavg") (sysctl-name "kern.ngroups") (sysctl-name "kern.safeboot")'
  echo '  (sysctl-name "kern.iossupportversion") (sysctl-name "security.mac.lockdown_mode_state") (sysctl-name "kern.bootargs")'
  echo '  (sysctl-name "kern.willshutdown") (sysctl-name "hw.cpufrequency_max") (sysctl-name "kern.hv_vmm_present")'
  echo '  (sysctl-name-prefix "net.routetable."))'
  echo '(allow system-info)'
} >"$PROFILE"

ENVV=(HOME="$HOME_DIR" USER="$USER" LOGNAME="$USER" SHELL="${SHELL:-/bin/zsh}" LANG="${LANG:-en_US.UTF-8}"
      TERM=xterm-256color PATH="$LOGIN_PATH" TMPDIR="$TMPD/"
      XDG_CACHE_HOME="$CACHE/xdg" npm_config_cache="$CACHE/npm" YARN_CACHE_FOLDER="$CACHE/yarn"
      npm_config_store_dir="$CACHE/pnpm" BUN_INSTALL_CACHE_DIR="$CACHE/bun" PIP_CACHE_DIR="$CACHE/pip"
      UV_CACHE_DIR="$CACHE/uv" CARGO_HOME="$CACHE/cargo" GOMODCACHE="$CACHE/gomod" GOCACHE="$CACHE/go"
      PRE_COMMIT_HOME="$CACHE/pre-commit" PLAYWRIGHT_BROWSERS_PATH="$CACHE/playwright"
      CLANG_MODULE_CACHE_PATH="$CACHE/clang" GIT_CONFIG_GLOBAL="$ETC/gitconfig" GIT_TEMPLATE_DIR="$ETC/git-template"
      XDG_CONFIG_HOME="$CACHE/config" xcrun_db="$CACHE/xcrun_db" PYTHONPYCACHEPREFIX="$CACHE/python" GOTELEMETRY=off
      DISABLE_AUTOUPDATER=1 DOZ_FENCE=agent)

# The kernel's refusal lines, streamed while the tools run (`log show` later loses them: the ring wraps in seconds on
# a busy Mac). On macOS 27 a `subsystem == "com.apple.sandbox.reporting"` predicate matches NOTHING in `log stream`;
# `sender == "Sandbox"` does. The `with message` text arrives in eventMessage after a newline:
# "Sandbox: cat(123) deny(1) file-read-data /\ndoz-fence:TAG".
/usr/bin/log stream --style ndjson --predicate 'sender == "Sandbox"' >"$SCRATCH/stream.ndjson" 2>/dev/null &
STREAM=$!
/bin/sleep 2
i=0
run() {
  local label=$1; shift
  i=$((i + 1))
  local cmd=$1
  if [ "${cmd#/}" = "$cmd" ] && ! PATH="$LOGIN_PATH" command -v "$cmd" >/dev/null 2>&1; then
    printf '%-34s SKIP (not on this Mac)\n' "$label" >>"$REPORT"; return
  fi
  (cd "$WORK" && /usr/bin/env -i "${ENVV[@]}" /usr/bin/sandbox-exec -f "$PROFILE" "$@" >"$OUT/$i.out" 2>"$OUT/$i.err" </dev/null)
  local rc=$?
  printf '%-34s exit %-3s %s\n' "$label" "$rc" "$(/usr/bin/head -c 160 "$OUT/$i.err" | /usr/bin/tr '\n' ' ')" >>"$REPORT"
}

echo "fence read probe — tag $TAG, home $HOME_DIR, scratch $SCRATCH" >"$REPORT.head"
# The control: a closed read must be refused AND logged (else an empty refusal list proves nothing).
run "CONTROL ls ~ (must fail)" /bin/ls "$HOME_DIR"
run "git --version" git --version
run "git init (sub-folder)" git init -q repo
run "git commit" /bin/sh -c 'cd repo && echo hi > a && git add a && git commit -qm probe && git log --oneline && git status --short'
run "node --version" node --version
run "node fs/os" node -e 'require("fs").readdirSync(".");require("os").cpus();console.log(require("os").tmpdir())'
run "npm --version" npm --version
run "npm view --offline" npm view --offline npm version
run "uv --version" uv --version
run "uv python list --only-installed" uv python list --only-installed
run "claude --version" claude --version
run "swift --version" swift --version
run "xcodebuild -version" xcodebuild -version
run "xcrun --show-sdk-path" xcrun --show-sdk-path
run "python3 (xcode)" /usr/bin/python3 -c 'import ssl,json;print(1)'
run "go version" go version
run "go env GOROOT" go env GOROOT
run "cargo --version" cargo --version
run "pnpm --version" pnpm --version
run "mise --version" mise --version
run "pipx --version" pipx --version
run "zsh -l (no rc)" /bin/zsh -c 'echo ok'
run "make --version" make --version
run "rg --version" rg --version
run "gh --version" gh --version
run "brew --version" brew --version
run "clang -fmodules (cache)" /bin/sh -c 'printf "@import Foundation;\nint main(void){return 0;}\n" > m.m && clang -fmodules -c m.m -o m.o'
run "swiftc -typecheck" /bin/sh -c 'echo "import Foundation; print(1)" > t.swift && swiftc -typecheck t.swift'
run "python3 -m venv" /usr/bin/python3 -m venv --without-pip venv

/bin/sleep 3
kill "$STREAM" 2>/dev/null
wait "$STREAM" 2>/dev/null
{
  /bin/cat "$REPORT.head"
  echo
  echo "== tools =="
  /bin/cat "$REPORT"
  echo
  echo "== reads allowed in the home =="
  for p in ${READS[@]+"${READS[@]}"}; do echo "  ${p/#$HOME_DIR/~}/"; done
  for p in ${READ_FILES[@]+"${READ_FILES[@]}"}; do echo "  ${p/#$HOME_DIR/~}"; done
  echo
  echo "== notes =="
  for n in ${NOTES[@]+"${NOTES[@]}"}; do echo "  ${n//$HOME_DIR/~}"; done
  echo
  echo "== refusals (kernel, de-duplicated) =="
  /usr/bin/grep -F "\\ndoz-fence:$TAG\"" "$SCRATCH/stream.ndjson" \
    | /usr/bin/sed -nE 's/.*"eventMessage":"([0-9]+ duplicate reports? for )?Sandbox: ([^ ]+)\([0-9]+\) (deny\([0-9]+\) [^"]*)\\ndoz-fence.*/\2 \3/p' \
    | /usr/bin/sed -E 's#\\/#/#g' \
    | /usr/bin/sed -E "s#$HOME_DIR#~#g; s#$SCRATCH#<scratch>#g" | /usr/bin/sort | /usr/bin/uniq -c | /usr/bin/sort -rn
  echo "  (stream lines carrying this probe's tag: $(/usr/bin/grep -c -F "doz-fence:$TAG" "$SCRATCH/stream.ndjson"))"
} >"$SCRATCH/final.txt"
/bin/cat "$SCRATCH/final.txt"
if [ $KEEP -eq 0 ]; then /bin/rm -rf "$SCRATCH"; else echo "(kept $SCRATCH)"; fi
