#!/usr/bin/env sh
# Build one immutable compiled generation, or update the legacy interpreter
# helpers. --rollback consumes the previous slot without running build tools.
set -eu
root=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
say() { printf 'mailbend: %s\n' "$*"; }
fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }
install_bend=0 install_rust=0 rollback=0
for arg in "$@"; do
  case "$arg" in
    --install-bend) install_bend=1 ;;
    --install-rust) install_rust=1 ;;
    --rollback) rollback=1 ;;
    *) fail "usage: install.sh [--install-bend] [--install-rust] | --rollback" ;;
  esac
done
[ "$rollback" = 0 ] || [ "$#" = 1 ] || fail "--rollback cannot be combined with build options"
. "$root/scripts/install-layout.sh"
mb_root_open
[ "$(id -u)" = "$MB_OWNER" ] || fail "run the installer as the checkout owner"
flock -n 8 || fail "another install is running in $root; rerun this script when it ends"
legacy_bin=0
if [ -d "$root/bin" ] && [ ! -L "$root/bin" ]; then
  exec 9<"$root/bin"
  flock -n 9 || fail "another install is running in $root; rerun this script when it ends"
  legacy_bin=1
elif mb_exists "$root/bin" && [ ! -L "$root/bin" ]; then
  fail "bin is not a directory"
fi

generation_stage= state_stage= current_tmp= legacy_staging=0
cleanup() {
  for stage in "$generation_stage" "$state_stage"; do
    [ -n "$stage" ] || continue
    if [ -d "$stage" ] && [ ! -L "$stage" ]; then
      private_stage "$stage" || return 2
      rm -rf --one-file-system -- "$stage"
    fi
  done
  if [ -n "$current_tmp" ] && [ -L "$current_tmp" ]; then
    mb_link "$current_tmp" "$temporary_target" || return 2
    rm -- "$current_tmp"
  fi
  if [ "$legacy_staging" = 1 ]; then rm -f bin/*.new.$$; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

private_stage() (
  path=$1 name=${1##*/}
  case "$name" in
    .stage-g.????????????|.stage-s.????????????|.stage-bootstrap.????????????) ;;
    *) mb_fail "unknown staging name: $path" ;;
  esac
  suffix=${name##*.}
  case "$suffix" in *[!A-Za-z0-9]*) mb_fail "staging suffix" ;; esac
  [ -d "$path" ] && [ ! -L "$path" ] || mb_fail "linked staging directory"
  mode=$(stat -c %a -- "$path")
  case "$mode" in 700|755) ;; *) mb_fail "staging mode" ;; esac
  mb_dir "$path" "$mode" || exit 2
  case "$name" in
    .stage-g.*) stage_kind=g ;;
    .stage-s.*) stage_kind=s ;;
    .stage-bootstrap.*) stage_kind=bootstrap ;;
  esac
  for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
    mb_exists "$entry" || continue
    leaf=${entry##*/}
    case "$stage_kind:$leaf" in
      g:mailbend-core|g:mailbend-tls|g:mailbend-attach|g:mailbend-typesafe|\
      g:mailbend-stdio|g:MANIFEST|s:FORMAT|s:active|s:previous|bootstrap:FORMAT) ;;
      *) mb_fail "unknown staging member: $entry" ;;
    esac
    case "$leaf" in
      active|previous)
        target=$(readlink -n -- "$entry"; printf '.')
        target=${target%.}
        case "$target" in ../../generations/g.*) ;; *) mb_fail "staging link target" ;; esac
        identifier=${target#../../generations/}
        mb_id "$identifier" g || mb_fail "staging generation ID"
        mb_link "$entry" "../../generations/$identifier" || exit 2
        mb_generation "$identifier" structure || exit 2 ;;
      *)
        [ -f "$entry" ] && [ ! -L "$entry" ] || mb_fail "staging member type"
        info=$(stat -c '%u %a %h %d %s' -- "$entry")
        set -- $info
        [ "$1:$3:$4" = "$MB_OWNER:1:$MB_DEVICE" ] &&
          [ $((0$2 & 07022)) = 0 ] || mb_fail "staging member metadata"
        case "$leaf" in
          FORMAT) [ "$5" -le 256 ] || mb_fail "staging FORMAT size" ;;
          MANIFEST) [ "$5" -le 1024 ] || mb_fail "staging MANIFEST size" ;;
        esac ;;
    esac
  done
)
# Validate all names before removing recognizable private residue. Completed
# objects are retained, including orphans and generations used by old sessions.
check_residue() (
  preparation=$1
  for path in "$MB_META"/* "$MB_META"/.[!.]* "$MB_META"/..?*; do
    mb_exists "$path" || continue
    name=${path##*/}
    case "$name" in
      generations|states) mb_dir "$path" 755 || exit 2 ;;
      current) [ "$preparation" = selected ] || mb_fail "unexpected current" ;;
      .current-new.????????????)
        suffix=${name#.current-new.}
        case "$suffix" in *[!A-Za-z0-9]*) mb_fail "temporary selector name" ;; esac
        target=$(readlink -n -- "$path"; printf '.')
        target=${target%.}
        case "$target" in
          states/bootstrap) mb_state bootstrap >/dev/null || exit 2 ;;
          states/s.*)
            [ "$preparation" = selected ] || mb_fail "normal state before bootstrap"
            mb_id "${target#states/}" s || mb_fail "temporary selector target"
            mb_state "${target#states/}" >/dev/null || exit 2 ;;
          *) mb_fail "temporary selector target" ;;
        esac
        mb_link "$path" "$target" || exit 2 ;;
      *) mb_fail "unknown metadata entry: $name" ;;
    esac
  done
  for section in states generations; do
    [ -d "$MB_META/$section" ] || continue
    for path in "$MB_META/$section"/* "$MB_META/$section"/.[!.]* "$MB_META/$section"/..?*; do
      mb_exists "$path" || continue
      name=${path##*/}
      case "$section:$name" in
        states:bootstrap) mb_state bootstrap >/dev/null || exit 2 ;;
        states:.stage-bootstrap.*) private_stage "$path" || exit 2 ;;
        states:.stage-s.*|generations:.stage-g.*)
          [ "$preparation" = selected ] || mb_fail "generation work before bootstrap"
          private_stage "$path" || exit 2 ;;
        states:s.*|generations:g.*)
          [ "$preparation" = selected ] || mb_fail "completed artifacts without current"
          case "$section" in states) prefix=s ;; generations) prefix=g ;; esac
          mb_id "$name" "$prefix" || mb_fail "finalized ID"
          mb_dir "$path" 755 || exit 2 ;;
        *) mb_fail "unknown layout entry: $path" ;;
      esac
    done
  done
)
clean_residue() {
  mb_root_same
  for parent in "$MB_META/states" "$MB_META/generations"; do
    for path in "$parent"/.stage-*; do
      mb_exists "$path" || continue
      private_stage "$path" || exit 2
      rm -rf --one-file-system -- "$path"
    done
  done
  for path in "$MB_META"/.current-new.*; do
    [ -L "$path" ] || continue
    rm -- "$path"
  done
}
new_current() {
  current_tmp=
  temporary_target=$1
  attempts=0
  while [ "$attempts" -lt 5 ]; do
    candidate=$(mktemp -u "$MB_META/.current-new.XXXXXXXXXXXX")
    if ln -sT -- "$1" "$candidate"; then current_tmp=$candidate; return; fi
    attempts=$((attempts + 1))
  done
  fail "cannot allocate temporary selector"
}
finalize_dir() {
  mb_root_same
  ! mb_exists "$2" || fail "finalized name collision"
  mv -T -n -- "$1" "$2"
  ! mb_exists "$1" || fail "finalized name collision"
}
ensure_dir() {
  mb_root_same
  if mb_exists "$1"; then
    mb_dir "$1" 755
  else
    mkdir -m 755 -- "$1"
  fi
  sync -- "$1"
  sync -- "$2"
}
bootstrap() {
  mb_root_same
  if [ "$legacy_bin" = 1 ]; then
    # The compatible bin lock remains held on fd 9 after rmdir.
    rmdir -- "$root/bin" || fail "legacy bin is not empty; use a new clean checkout"
  fi
  ensure_dir "$MB_META" "$root"
  ensure_dir "$MB_META/generations" "$MB_META"
  ensure_dir "$MB_META/states" "$MB_META"
  if ! mb_exists "$MB_META/states/bootstrap"; then
    state_stage=$(mktemp -d "$MB_META/states/.stage-bootstrap.XXXXXXXXXXXX")
    printf 'mailbend-install-state-v1\nkind=bootstrap\nactive=none\nprevious=none\n' > "$state_stage/FORMAT"
    chmod 644 -- "$state_stage/FORMAT"
    sync -- "$state_stage/FORMAT"
    chmod 755 -- "$state_stage"
    sync -- "$state_stage"
    finalize_dir "$state_stage" "$MB_META/states/bootstrap"
    state_stage=
  fi
  mb_state bootstrap >/dev/null
  # Retry the full dependency flush even when a prior attempt created names.
  sync -- "$MB_META/states/bootstrap/FORMAT"
  sync -- "$MB_META/states/bootstrap"
  sync -- "$MB_META/states"
  if ! mb_exists "$MB_META/current"; then
    new_current states/bootstrap
    mv -Tf -- "$current_tmp" "$MB_META/current"
    current_tmp=
  fi
  mb_link "$MB_META/current" states/bootstrap
  sync -- "$MB_META"
  for name in bin bin.prev; do
    case "$name" in bin) member=active ;; bin.prev) member=previous ;; esac
    if mb_exists "$root/$name"; then
      mb_link "$root/$name" ".mailbend-install/current/$member"
    else
      ln -sT -- ".mailbend-install/current/$member" "$root/$name"
    fi
  done
  sync -- "$root"
  mb_capture
}
selected=none
if mb_marker; then
  [ "$legacy_bin" = 0 ] || {
    # Only an empty bin can be part of never-usable bootstrap preparation.
    for entry in "$root/bin"/* "$root/bin"/.[!.]* "$root/bin"/..?*; do
      ! mb_exists "$entry" || fail "nonempty legacy bin with managed metadata"
    done
  }
  if mb_exists "$MB_META"; then mb_dir "$MB_META" 755; fi
  if mb_exists "$MB_META/current"; then
    mb_capture
    selected=$MB_KIND
    [ "$legacy_bin" = 0 ] || mb_fail "real bin beside selected managed state"
    check_residue selected
    if [ "$selected" != bootstrap ]; then mb_hash_selected; fi
  else
    for name in bin bin.prev; do
      if mb_exists "$root/$name" && [ "$legacy_bin:$name" != 1:bin ]; then
        case "$name" in bin) member=active ;; bin.prev) member=previous ;; esac
        mb_link "$root/$name" ".mailbend-install/current/$member"
      fi
    done
    check_residue preparation
    selected=preparation
  fi
fi

# Build a state only after its target has been completely checked and flushed.
commit_state() {
  mb_root_same
  kind=$1 active=$2 previous=$3
  state_stage=$(mktemp -d "$MB_META/states/.stage-s.XXXXXXXXXXXX")
  state_id=s.${state_stage##*.}
  printf 'mailbend-install-state-v1\nkind=%s\nactive=%s\nprevious=%s\n' "$kind" "$active" "$previous" > "$state_stage/FORMAT"
  chmod 644 -- "$state_stage/FORMAT"
  sync -- "$state_stage/FORMAT"
  ln -sT -- "../../generations/$active" "$state_stage/active"
  if [ "$previous" != none ]; then ln -sT -- "../../generations/$previous" "$state_stage/previous"; fi
  chmod 755 -- "$state_stage"
  sync -- "$state_stage"
  finalize_dir "$state_stage" "$MB_META/states/$state_id"
  state_stage=
  sync -- "$MB_META/states"
  mb_aliases
  mb_capture
  [ "$MB_CURRENT" = "$expected_current" ] || fail "selected installation changed during operation"
  mb_root_same
  new_current "states/$state_id"
  mv -Tf -- "$current_tmp" "$MB_META/current"
  current_tmp=
  if ! sync -- "$MB_META"; then
    fail "generation $active is selected; activation durability is uncertain (final directory flush failed)"
  fi
}
if [ "$rollback" = 1 ]; then
  case "$selected" in
    install|rollback) ;;
    *) fail "no previous managed installation; rollback is unavailable" ;;
  esac
  expected_current=$MB_CURRENT
  if [ "$selected" = rollback ]; then
    if ! sync -- "$MB_META"; then
      fail "generation $MB_ACTIVE is selected; activation durability is uncertain (retry flush failed)"
    fi
    say "rollback already applied; generation $MB_ACTIVE remains selected"
    exit 0
  fi
  [ "$MB_PREVIOUS" != none ] || fail "no previous installation"
  clean_residue
  restored=$MB_PREVIOUS
  commit_state rollback "$restored" none
  say "rolled back to generation $restored; rollback slot consumed"
  exit 0
fi

export BEND_NO_TELEMETRY=1
PATH="$HOME/.bend/bin:$HOME/.cargo/bin:$PATH"
has_clang=0
if command -v clang >/dev/null 2>&1; then
  has_clang=1
  libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || libc=
  version=$(printf '%s\n' "$libc" | sed -n 's/^glibc \([0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1 \2/p')
  set -- $version
  if [ "$#" -ne 2 ] || [ "$libc" != "glibc $1.$2" ] ||
      ! { [ "$1" -gt 2 ] || { [ "$1" -eq 2 ] && [ "$2" -ge 34 ]; }; } 2>/dev/null; then
    fail "the compiled core needs glibc 2.34 or newer"
  fi
fi


if [ "$has_clang" = 0 ]; then
  case "$selected" in
    none) ;;
    *) fail "clang not found; refusing to update a managed compiled installation. Install clang and rerun scripts/install.sh." ;;
  esac
  if [ -x bin/mailbend-core ]; then
    fail "clang not found; refusing to update an existing compiled installation. Install clang and rerun scripts/install.sh."
  fi
else
  if [ "$legacy_bin" = 1 ]; then
    for entry in "$root/bin"/* "$root/bin"/.[!.]* "$root/bin"/..?*; do
      ! mb_exists "$entry" || fail "nonempty legacy bin cannot be migrated automatically; install a new clean checkout, stop legacy sessions, then switch the client"
    done
  fi
fi
if ! command -v bend >/dev/null 2>&1; then
  if [ "$install_bend" = 1 ]; then
    sh scripts/install-bend.sh
  else
    fail "Bend is not installed. Rerun this script with --install-bend"
  fi
fi

# The minor version of the native helpers' MSRV, Rust 1.99 (rust-version in
# native/Cargo.toml).
rust_minor=99
# Whether a "<tool> 1.N.x ..." version line is at least the MSRV.
at_least_msrv() {
  minor=$(printf '%s\n' "$1" | sed -n 's/^[a-z]* 1\.\([0-9][0-9]*\)\..*/\1/p')
  [ -n "$minor" ] && [ "$minor" -ge "$rust_minor" ]
}
# Uses cargo $1 with rustc $2 if both meet the MSRV. Asked from native/ so
# rustup's proxies report the toolchain native/rust-toolchain.toml pins.
try_cargo() {
  cargo_version=$(CDPATH= cd native && "$1" --version 2>/dev/null) || return 1
  rustc_version=$(CDPATH= cd native && "$2" --version 2>/dev/null) || return 1
  at_least_msrv "$cargo_version" && at_least_msrv "$rustc_version" || return 1
  cargo=$1 RUSTC=$2
  export RUSTC
}
# $CARGO if set, else cargo (rustup).
find_cargo() {
  try_cargo "${CARGO:-cargo}" "${RUSTC:-rustc}"
}
if ! find_cargo; then
  if [ "$install_rust" = 1 ]; then
    sh scripts/install-rust.sh
    find_cargo || fail "Rust 1.$rust_minor was installed but cargo still cannot be used"
  else
    fail "cargo and rustc 1.$rust_minor+ are needed for the native helpers. Rerun this script with --install-rust"
  fi
fi

# ring (the TLS helper's cryptography) is partly C, built by cargo.
command -v cc >/dev/null 2>&1 || fail "a C compiler is needed (apt-get install build-essential)"


helpers="mailbend-tls mailbend-attach mailbend-typesafe mailbend-stdio"
staged_regular() (
  [ ! -L "$1" ] && [ -f "$1" ] &&
    { [ "${2:-complete}" = partial ] || [ -s "$1" ]; } ||
    fail "build output is not a nonempty direct file: $1"
  [ "$(stat -c '%u:%h:%d' -- "$1")" = "$MB_OWNER:1:$MB_DEVICE" ] ||
    fail "build output owner, links or filesystem: $1"
)
if [ "$has_clang" = 1 ]; then
  if [ "$selected" = none ] || [ "$selected" = preparation ] || [ "$selected" = bootstrap ]; then
    clean_residue
    bootstrap
  else
    clean_residue
  fi
  expected_current=$MB_CURRENT
  previous=$MB_ACTIVE
  mb_root_same
  generation_stage=$(mktemp -d "$MB_META/generations/.stage-g.XXXXXXXXXXXX")
  generation_id=g.${generation_stage##*.}
  output=$generation_stage
else
  if [ "$legacy_bin" = 0 ]; then
    mb_root_same
    mkdir -m 755 -- bin
    exec 9<bin
    flock -n 9 || fail "another install is running"
  fi
  # Interpreter mode retains the historical flat publication and restart rule.
  rm -f bin/*.new.*
  legacy_staging=1
  output=$root/bin
fi
say "building native helpers ($rustc_version)"
(CDPATH= cd native && "$cargo" build --release --locked --quiet -p mailbend-tls -p mailbend-attach -p mailbend-typesafe -p mailbend-stdio)
for name in $helpers; do
  if [ "$has_clang" = 1 ]; then target=$output/$name; else target=$output/$name.new.$$; fi
  cp "native/target/release/$name" "$target"
  if [ "$has_clang" = 1 ]; then staged_regular "$target" || exit 1; fi
  chmod 755 -- "$target"
done
if [ "$has_clang" = 1 ]; then suffix=; else suffix=.new.$$; fi
"$output/mailbend-tls$suffix" --check || fail "the built TLS helper cannot run"
"$output/mailbend-typesafe$suffix" --check || fail "the built TypeSafe helper cannot run"
"$output/mailbend-stdio$suffix" --check || fail "the built stdio helper cannot run"
say "checking the safety laws (bend PROOF.bend)"
bend PROOF.bend
if [ "$has_clang" = 1 ]; then
  say "compiling the Bend core (takes about a minute)"
  core_tmp=$output/mailbend-core
  if ! bend main.bend -o "$core_tmp" 2>/dev/null; then
    if mb_exists "$core_tmp"; then staged_regular "$core_tmp" partial || exit 1; fi
    bend main.bend -o "$core_tmp" || exit 1
  fi
  staged_regular "$core_tmp" || exit 1
  chmod 755 -- "$core_tmp"
  ! mb_exists "$output/MANIFEST" || fail "unexpected manifest before publication"
  {
    printf 'mailbend-generation-v1\ngeneration=%s\n' "$generation_id"
    for name in $MB_MEMBERS; do
      mb_file "$output/$name" 755 0
      sum=$(sha256sum < "$output/$name")
      printf '%s %s 0755\n' "$name" "${sum%% *}"
    done
  } > "$output/MANIFEST"
  chmod 644 -- "$output/MANIFEST"
  chmod 755 -- "$output"
  for name in $MB_MEMBERS MANIFEST; do sync -- "$output/$name"; done
  sync -- "$output"
  finalize_dir "$output" "$MB_META/generations/$generation_id"
  generation_stage=
  sync -- "$MB_META/generations"
  mb_generation "$generation_id" hashes
  commit_state install "$generation_id" "$previous"
  say "installed generation $generation_id; existing managed sessions keep their original helpers"
else
  for name in $helpers; do
    sync -- "$output/$name.new.$$"
    mv -f -- "$output/$name.new.$$" "$output/$name"
  done
  sync -- bin
  say "clang not found: scripts/mailbend will run main.bend through bend (slower start)"
  say "restart any MCP server already running, so its core matches the new helpers"
fi
say "done. Test it with: scripts/mailbend call mail_probe"
say "MCP command: $root/scripts/mailbend mcp"
