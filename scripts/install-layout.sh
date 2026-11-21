# Version 1 compiled-generation layout. Sourced by the three shell entry points.
# A captured state is stable across cooperating upgrades; current is read once.
MB_MEMBERS="mailbend-core mailbend-tls mailbend-attach mailbend-typesafe mailbend-stdio"

mb_fail() { printf 'mailbend: invalid installation: %s\n' "$*" >&2; exit 2; }
mb_exists() { [ -e "$1" ] || [ -L "$1" ]; }
mb_id() (
  case "$1" in "$2".????????????) ;; *) return 1 ;; esac
  case "${1#*.}" in *[!A-Za-z0-9]*) return 1 ;; esac
)
mb_root_same() {
  [ "$(stat -Lc '%d:%i' -- "$root")" = "$MB_ROOT_ID" ] &&
    [ ! -L "$root" ] || mb_fail "checkout root moved or was replaced"
}
mb_root_open() {
  MB_LC_SET=${LC_ALL+x}
  MB_LC_VALUE=${LC_ALL-}
  LC_ALL=C
  export LC_ALL
  exec 8<"$root"
  MB_ROOT_ID=$(stat -Lc '%d:%i' /dev/fd/8)
  MB_OWNER=$(stat -Lc '%u' /dev/fd/8)
  MB_DEVICE=${MB_ROOT_ID%:*}
  mb_root_same
  mb_trust_root || exit 2
  MB_META=$root/.mailbend-install
}
mb_restore_locale() {
  if [ "$MB_LC_SET" = x ]; then LC_ALL=$MB_LC_VALUE; export LC_ALL; else unset LC_ALL; fi
}
mb_trust_root() (
  path=$root
  while :; do
    [ -d "$path" ] && [ ! -L "$path" ] || mb_fail "linked checkout ancestor"
    info=$(stat -c '%u %a' -- "$path") || exit 2
    set -- $info
    [ "$1" = "$MB_OWNER" ] || [ "$1" = 0 ] || mb_fail "foreign checkout ancestor"
    mode=$((0$2))
    if [ "$path" = "$root" ]; then
      [ "$1" = "$MB_OWNER" ] && [ $((mode & 07022)) = 0 ] ||
        mb_fail "unsafe checkout permissions: $path (mode 0$2); root owner must be UID $MB_OWNER." \
          "Group or world write and setuid, setgid or sticky bits are forbidden." \
          "Only if local policy permits, the owner may remove unwanted bits (group-write/setgid only: chmod g-w,g-s); otherwise use a new private checkout. See README.md#checkout-permissions"
    elif [ $((mode & 0022)) != 0 ]; then
      [ "$1" = 0 ] && [ $((mode & 01000)) != 0 ] ||
        mb_fail "writable checkout ancestor"
      child_info=$(stat -c '%u %a' -- "$child") || exit 2
      set -- $child_info
      { [ "$1" = "$MB_OWNER" ] || [ "$1" = 0 ]; } &&
        [ $((0$2 & 0022)) = 0 ] || mb_fail "unprotected child of sticky ancestor"
    fi
    [ "$path" != / ] || break
    child=$path
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
)
mb_dir() (
  [ -d "$1" ] && [ ! -L "$1" ] || mb_fail "not a real directory: $1"
  [ "$(stat -c '%u:%a:%d' -- "$1")" = "$MB_OWNER:$2:$MB_DEVICE" ] ||
    mb_fail "directory owner, mode or filesystem: $1"
)
mb_link() (
  [ -L "$1" ] && [ "$(stat -c %u -- "$1")" = "$MB_OWNER" ] &&
    [ "$(readlink -n -- "$1"; printf '.')" = "$2." ] || mb_fail "unexpected link: $1"
)
mb_file() (
  [ -f "$1" ] && [ ! -L "$1" ] || mb_fail "not a direct regular file: $1"
  info=$(stat -c '%u %a %h %d %s' -- "$1") || exit 2
  set -- "$1" "$2" "$3" $info
  [ "$4:$5:$6:$7" = "$MB_OWNER:$2:1:$MB_DEVICE" ] &&
    [ "$8" -gt 0 ] || mb_fail "file owner, mode, links or size: $1"
  [ "$3" = 0 ] || [ "$8" -le "$3" ] || mb_fail "oversized record: $1"
)
# Appending a sentinel preserves trailing LFs in command substitution. A byte
# count also rejects NULs that a shell cannot retain in a variable.
mb_read() (
  mb_file "$1" 644 "$2" || exit 2
  size=$(stat -c %s -- "$1") || exit 2
  record=$(head -c "$(( $2 + 1 ))" -- "$1"; printf '.') || exit 2
  [ "${#record}" = "$((size + 1))" ] || mb_fail "invalid record bytes: $1"
  printf '%s' "$record"
)
mb_inventory() (
  directory=$1
  shift
  count=0
  for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    mb_exists "$entry" || continue
    name=${entry##*/}
    found=0
    for expected in "$@"; do [ "$name" != "$expected" ] || found=1; done
    [ "$found" = 1 ] || mb_fail "unexpected member: $entry"
    count=$((count + 1))
  done
  [ "$count" = "$#" ] || mb_fail "incomplete inventory: $directory"
)
mb_state() (
  id=$1
  [ "$id" = bootstrap ] || mb_id "$id" s || mb_fail "state ID"
  dir=$MB_META/states/$id
  mb_dir "$dir" 755 || exit 2
  record=$(mb_read "$dir/FORMAT" 256) || exit 2
  {
    IFS= read -r header
    IFS= read -r kind
    IFS= read -r active
    IFS= read -r previous
  } < "$dir/FORMAT"
  kind=${kind#kind=}
  active=${active#active=}
  previous=${previous#previous=}
  canonical=$(printf 'mailbend-install-state-v1\nkind=%s\nactive=%s\nprevious=%s\n.' "$kind" "$active" "$previous")
  [ "$record" = "$canonical" ] || mb_fail "state record grammar"
  case "$kind:$id:$active:$previous" in
    bootstrap:bootstrap:none:none)
      mb_inventory "$dir" FORMAT || exit 2 ;;
    *)
      mb_id "$id" s && mb_id "$active" g || mb_fail "state IDs"
      case "$kind:$previous" in
        install:none|rollback:none)
          mb_inventory "$dir" FORMAT active || exit 2 ;;
        install:*)
          mb_id "$previous" g && [ "$previous" != "$active" ] || mb_fail "previous ID"
          mb_inventory "$dir" FORMAT active previous || exit 2
          mb_link "$dir/previous" "../../generations/$previous" || exit 2 ;;
        *) mb_fail "state kind or previous" ;;
      esac
      mb_link "$dir/active" "../../generations/$active" || exit 2 ;;
  esac
  printf '%s %s %s\n' "$kind" "$active" "$previous"
)
mb_generation() (
  id=$1 hashes=$2
  mb_id "$id" g || mb_fail "generation ID"
  dir=$MB_META/generations/$id
  mb_dir "$dir" 755 || exit 2
  mb_inventory "$dir" $MB_MEMBERS MANIFEST || exit 2
  record=$(mb_read "$dir/MANIFEST" 1024) || exit 2
  {
    IFS= read -r header
    IFS= read -r declared
    [ "$header" = mailbend-generation-v1 ] && [ "$declared" = "generation=$id" ] ||
      mb_fail "manifest header"
    canonical=$(printf 'mailbend-generation-v1\ngeneration=%s' "$id")
    for member in $MB_MEMBERS; do
      IFS=' ' read -r name digest mode
      [ "$name" = "$member" ] && [ "$mode" = 0755 ] && [ "${#digest}" = 64 ] ||
        mb_fail "manifest member"
      case "$digest" in *[!0-9a-f]*) mb_fail "manifest digest" ;; esac
      canonical="$canonical
$member $digest 0755"
      mb_file "$dir/$member" 755 0 || exit 2
      [ -x "$dir/$member" ] || mb_fail "member cannot execute"
      if [ "$hashes" = hashes ]; then
        sum=$(sha256sum < "$dir/$member") || exit 2
        [ "${sum%% *}" = "$digest" ] || mb_fail "manifest mismatch: $member"
      fi
    done
  } < "$dir/MANIFEST"
  [ "$record" = "$canonical
." ] || mb_fail "manifest record grammar"
)
mb_aliases() {
  mb_link "$root/bin" .mailbend-install/current/active || exit 2
  mb_link "$root/bin.prev" .mailbend-install/current/previous || exit 2
}
mb_marker() {
  mb_exists "$MB_META" || [ -L "$root/bin" ] || mb_exists "$root/bin.prev"
}
mb_capture() {
  mb_dir "$MB_META" 755 || exit 2
  mb_dir "$MB_META/states" 755 || exit 2
  mb_dir "$MB_META/generations" 755 || exit 2
  [ -L "$MB_META/current" ] || mb_fail "missing current selector"
  MB_CURRENT=$(readlink -n -- "$MB_META/current"; printf '.') || mb_fail "unreadable current"
  MB_CURRENT=${MB_CURRENT%.}
  case "$MB_CURRENT" in
    states/bootstrap) ;;
    states/s.*) mb_id "${MB_CURRENT#states/}" s || mb_fail "current target" ;;
    *) mb_fail "current target" ;;
  esac
  [ "$(stat -c %u -- "$MB_META/current")" = "$MB_OWNER" ] || mb_fail "current owner"
  mb_record=$(mb_state "${MB_CURRENT#states/}") || exit 2
  set -- $mb_record
  MB_KIND=$1 MB_ACTIVE=$2 MB_PREVIOUS=$3
  MB_GENERATION=$MB_META/generations/$MB_ACTIVE
  if [ "$MB_KIND" != bootstrap ]; then
    mb_aliases
    mb_generation "$MB_ACTIVE" structure || exit 2
  fi
  mb_root_same
}
# Full hashes are separate from capture so readers never inspect retired bytes.
mb_hash_selected() {
  mb_generation "$MB_ACTIVE" hashes || exit 2
  if [ "$MB_PREVIOUS" != none ]; then mb_generation "$MB_PREVIOUS" hashes || exit 2; fi
}
