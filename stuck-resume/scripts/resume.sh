#!/bin/sh
# Claude Code 는 이 훅이 종료코드 2 로 끝날 때만 stderr 텍스트를 다음 프롬프트로 주입한다.
set -eu

STATE_ROOT="${CLAUDE_RESUME_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/stuck-resume}"
STATE_DIR="$STATE_ROOT/v2"
LOCK_DIR="$STATE_DIR/lock"
LOCK_PUBLISH="$STATE_DIR/lock-publish"
CAUSE_DIR="$STATE_DIR/causes"
WAITER_DIR="$STATE_DIR/waiters"
GLOBAL="$STATE_DIR/global"
lock_owned=0
publish_owned=0
wake_requested=0
process_identity=

now_epoch() {
  case "${CLAUDE_RESUME_TEST_NOW:-}" in
    *[!0-9]*|'') date +%s ;;
    *) printf '%s\n' "$CLAUDE_RESUME_TEST_NOW" ;;
  esac
}

number_or_default() {
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

base_delay_or_default() {
  case "$1" in
    [1-9]|[1-9][0-9]|[1-3][0-9][0-9]|4[0-7][0-9]|480) printf '%s\n' "$1" ;;
    *) printf '30\n' ;;
  esac
}

read_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n '1p'
}

write_atomic() {
  write_file=$1
  write_content=$2
  write_tmp="$write_file.$$.tmp"
  printf '%s\n' "$write_content" > "$write_tmp"
  mv "$write_tmp" "$write_file"
}

create_process_identity() {
  mkdir -p "$STATE_DIR"
  process_identity=$(mktemp "$STATE_DIR/invocation-XXXXXX")
  process_token=${process_identity##*/}
  case "$process_token" in
    invocation-[0-9A-Za-z_-]*) ;;
    *) rm -f "$process_identity"; process_identity=; return 1 ;;
  esac
  CLAUDE_RESUME_PROCESS_IDENTITY=$process_identity
  export CLAUDE_RESUME_PROCESS_IDENTITY
}

cleanup_process_identity() {
  [ -z "$process_identity" ] || rm -f "$process_identity" || true
  process_identity=
}

lock_mtime() {
  lock_mtime_value=
  if lock_mtime_value=$(stat -f %m "$LOCK_DIR" 2>/dev/null); then
    case "$lock_mtime_value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$lock_mtime_value"; return 0 ;; esac
  fi
  if lock_mtime_value=$(stat -c %Y "$LOCK_DIR" 2>/dev/null); then
    case "$lock_mtime_value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$lock_mtime_value"; return 0 ;; esac
  fi
  return 0
}

publish_owner_alive() {
  owner_pid=$1
  owner_role=$2
  owner_token=$3
  case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$owner_role" in worker|stop) ;; *) return 1 ;; esac
  case "$owner_token" in ''|*[!0-9A-Za-z_-]*) return 1 ;; esac
  owner_command=$(ps -ww -p "$owner_pid" -o command= 2>/dev/null) || return 1
  case " $owner_command " in
    *" --$owner_role $owner_token "*) return 0 ;;
    *) return 1 ;;
  esac
}

acquire_publish_lock() {
  publish_candidate="$STATE_DIR/.lock-publish.$$"
  write_atomic "$publish_candidate" "pid=$$
acquired_at=$(now_epoch)
role=$process_role
token=$process_token"
  while ! ln "$publish_candidate" "$LOCK_PUBLISH" 2>/dev/null; do
    publish_pid=$(read_field "$LOCK_PUBLISH" pid)
    publish_at=$(number_or_default "$(read_field "$LOCK_PUBLISH" acquired_at)" 0)
    publish_role=$(read_field "$LOCK_PUBLISH" role)
    publish_token=$(read_field "$LOCK_PUBLISH" token)
    if ! publish_owner_alive "$publish_pid" "$publish_role" "$publish_token"; then
      current_publish_pid=$(read_field "$LOCK_PUBLISH" pid)
      current_publish_at=$(number_or_default "$(read_field "$LOCK_PUBLISH" acquired_at)" 0)
      current_publish_role=$(read_field "$LOCK_PUBLISH" role)
      current_publish_token=$(read_field "$LOCK_PUBLISH" token)
      if [ "$current_publish_pid" = "$publish_pid" ] && [ "$current_publish_at" = "$publish_at" ] && [ "$current_publish_role" = "$publish_role" ] && [ "$current_publish_token" = "$publish_token" ]; then
        rm -f "$LOCK_PUBLISH"
      fi
      continue
    fi
    sleep 1
  done
  rm -f "$publish_candidate"
  publish_owned=1
}

release_publish_lock() {
  if [ "$publish_owned" = 1 ] && [ "$(read_field "$LOCK_PUBLISH" pid)" = "$$" ] && [ "$(read_field "$LOCK_PUBLISH" role)" = "$process_role" ] && [ "$(read_field "$LOCK_PUBLISH" token)" = "$process_token" ]; then
    rm -f "$LOCK_PUBLISH"
  fi
  rm -f "$STATE_DIR/.lock-publish.$$"
  publish_owned=0
}

publish_lock_owner() {
  case "${CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER:-}" in
    '') ;;
    *)
      mkdir -p "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER"
      : > "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER/ready.$$"
      while [ ! -f "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER/release.$$" ]; do sleep 1; done
      ;;
  esac
  write_atomic "$LOCK_DIR/owner" "pid=$$
acquired_at=$(now_epoch)"
  lock_owned=1
  release_publish_lock
}

acquire_lock() {
  while :; do
    lock_pid=$(read_field "$LOCK_DIR/owner" pid)
    lock_at=$(number_or_default "$(read_field "$LOCK_DIR/owner" acquired_at)" 0)
    lock_now=$(now_epoch)
    if [ -d "$LOCK_DIR" ] && [ -z "$lock_pid" ]; then
      lock_created=$(number_or_default "$(lock_mtime)" 0)
      if [ "$lock_created" -gt 0 ] && [ "$lock_now" -lt "$((lock_created + 30))" ]; then
        sleep 1
        continue
      fi
      case "${CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER:-}" in
        '') ;;
        *)
          mkdir -p "$CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER"
          : > "$CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER/ready.$$"
          while [ ! -f "$CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER/release.$$" ]; do sleep 1; done
          ;;
      esac
    elif [ -n "$lock_pid" ] && { ! kill -0 "$lock_pid" 2>/dev/null || [ "$lock_now" -ge "$((lock_at + 30))" ]; }; then
      case "${CLAUDE_RESUME_TEST_RECLAIM_BARRIER:-}" in
        '') ;;
        *)
          mkdir -p "$CLAUDE_RESUME_TEST_RECLAIM_BARRIER"
          : > "$CLAUDE_RESUME_TEST_RECLAIM_BARRIER/ready"
          while [ ! -f "$CLAUDE_RESUME_TEST_RECLAIM_BARRIER/release" ]; do sleep 1; done
          ;;
      esac
    elif [ -d "$LOCK_DIR" ]; then
      sleep 1
      continue
    fi

    acquire_publish_lock
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      publish_lock_owner
      break
    fi

    current_lock_pid=$(read_field "$LOCK_DIR/owner" pid)
    current_lock_at=$(number_or_default "$(read_field "$LOCK_DIR/owner" acquired_at)" 0)
    current_lock_now=$(now_epoch)
    lock_removed=0
    if [ -z "$current_lock_pid" ]; then
      current_lock_created=$(number_or_default "$(lock_mtime)" 0)
      if [ "$current_lock_created" -eq 0 ] || [ "$current_lock_now" -ge "$((current_lock_created + 30))" ]; then
        if rmdir "$LOCK_DIR" 2>/dev/null; then lock_removed=1; fi
      fi
    elif [ "$current_lock_pid" = "$lock_pid" ] && [ "$current_lock_at" = "$lock_at" ] && { ! kill -0 "$current_lock_pid" 2>/dev/null || [ "$current_lock_now" -ge "$((current_lock_at + 30))" ]; }; then
      rm -rf "$LOCK_DIR"
      lock_removed=1
    fi
    if [ "$lock_removed" = 1 ] && mkdir "$LOCK_DIR" 2>/dev/null; then
      publish_lock_owner
      break
    fi
    release_publish_lock
  done
  case "${CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER:-}" in
    '') ;;
    *)
      mkdir -p "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER"
      : > "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/ready.$$"
      while [ ! -f "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/release.$$" ]; do sleep 1; done
      ;;
  esac
}

release_lock() {
  if [ "$lock_owned" = 1 ] && [ "$(read_field "$LOCK_DIR/owner" pid)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
  lock_owned=0
}

write_global() {
  write_atomic "$GLOBAL" "episode=$episode
generation=$generation
recovered_generation=$recovered_generation
delay=$delay
last_attempt=$last_attempt
attempts=$attempts
base_delay=$base_delay
max_attempts=$max_attempts
active_session=$active_session
active_generation=$active_generation
handoff_at=$handoff_at
deadline=$deadline"
}

load_global() {
  episode=$(number_or_default "$(read_field "$GLOBAL" episode)" 0)
  generation=$(number_or_default "$(read_field "$GLOBAL" generation)" 0)
  recovered_generation=$(number_or_default "$(read_field "$GLOBAL" recovered_generation)" 0)
  delay=$(base_delay_or_default "$(read_field "$GLOBAL" delay)")
  last_attempt=$(number_or_default "$(read_field "$GLOBAL" last_attempt)" 0)
  attempts=$(number_or_default "$(read_field "$GLOBAL" attempts)" 0)
  base_delay=$(base_delay_or_default "$(read_field "$GLOBAL" base_delay)")
  max_attempts=$(number_or_default "$(read_field "$GLOBAL" max_attempts)" 0)
  active_session=$(read_field "$GLOBAL" active_session)
  [ -n "$active_session" ] || active_session=-
  active_generation=$(number_or_default "$(read_field "$GLOBAL" active_generation)" 0)
  handoff_at=$(number_or_default "$(read_field "$GLOBAL" handoff_at)" 0)
  deadline=$(number_or_default "$(read_field "$GLOBAL" deadline)" 0)
}

transcript_reset_epoch() {
  [ -f "$1" ] && [ -r "$1" ] || return 0
  tail -n 200 "$1" 2>/dev/null | awk '
    /"isApiErrorMessage"[[:space:]]*:[[:space:]]*true/ && /"quotaLimits"[[:space:]]*:/ {
      if (match($0, /"resetsAt"[[:space:]]*:[[:space:]]*[0-9]+/)) {
        value=substr($0, RSTART, RLENGTH)
        sub(/^.*:[[:space:]]*/, "", value)
        last=value
      }
    }
    END { if (last != "") print last }
  '
}

date_from_text() {
  date_format=$1
  date_text=$2
  date -j -f "$date_format" "$date_text" +%s 2>/dev/null || date -d "$date_text" +%s 2>/dev/null || true
}

day_from_epoch() {
  date -r "$1" +%Y-%m-%d 2>/dev/null || date -d "@$1" +%Y-%m-%d 2>/dev/null || true
}

weekday_from_epoch() {
  date -r "$1" +%w 2>/dev/null || date -d "@$1" +%w 2>/dev/null || true
}

message_reset_epoch() {
  message=$1
  message_now=$2
  reset_text=$(printf '%s' "$message" | LC_ALL=C awk 'match($0, /resets[[:space:]]+([A-Z][a-z][a-z][[:space:]]+)?[0-9][0-9]?:[0-9][0-9][aApP][mM]/) { print substr($0, RSTART + 7, RLENGTH - 7); exit }')
  [ -n "$reset_text" ] || return 0
  reset_text=$(printf '%s' "$reset_text" | tr '[:upper:]' '[:lower:]')
  case "$reset_text" in
    [a-z][a-z][a-z]\ *)
      reset_day=${reset_text%% *}
      reset_time=${reset_text#* }
      case "$reset_day" in mon) wanted=1 ;; tue) wanted=2 ;; wed) wanted=3 ;; thu) wanted=4 ;; fri) wanted=5 ;; sat) wanted=6 ;; sun) wanted=0 ;; *) return 0 ;; esac
      current=$(weekday_from_epoch "$message_now")
      case "$current" in *[!0-9]*|'') return 0 ;; esac
      days=$((wanted - current))
      [ "$days" -ge 0 ] || days=$((days + 7))
      reset_date=$(day_from_epoch "$((message_now + days * 86400))")
      reset=$(date_from_text '%Y-%m-%d %I:%M%p' "$reset_date $reset_time")
      [ -n "$reset" ] || return 0
      [ "$reset" -ge "$message_now" ] || reset=$((reset + 604800))
      ;;
    *)
      reset_date=$(day_from_epoch "$message_now")
      reset=$(date_from_text '%Y-%m-%d %I:%M%p' "$reset_date $reset_text")
      [ -n "$reset" ] || return 0
      [ "$reset" -ge "$message_now" ] || reset=$((reset + 86400))
      ;;
  esac
  printf '%s\n' "$reset"
}

cause_deadline() {
  cause_error=$1
  cause_now=$2
  cause_transcript=$3
  cause_message=$4
  case "$cause_error" in
    rate_limit)
      reset=$(transcript_reset_epoch "$cause_transcript")
      [ -n "$reset" ] || reset=$(message_reset_epoch "$cause_message" "$cause_now")
      if [ -n "$reset" ]; then printf '%s\n' "$((reset + 3600))"; else printf '%s\n' "$((cause_now + 10800))"; fi
      ;;
    *) printf '%s\n' "$((cause_now + 10800))" ;;
  esac
}

has_unrecovered_waiter() {
  for waiter in "$WAITER_DIR"/*; do
    [ -f "$waiter" ] || continue
    if ! publish_owner_alive "$(read_field "$waiter" pid)" worker "$(read_field "$waiter" token)"; then
      rm -f "$waiter"
      continue
    fi
    waiter_generation=$(number_or_default "$(read_field "$waiter" generation)" 0)
    [ "$waiter_generation" -le "$recovered_generation" ] || return 0
  done
  return 1
}

print_resume_message() {
  case "$error" in
    rate_limit) printf 'Continue the work that was interrupted by the usage limit.\n' >&2 ;;
    authentication_failed) printf 'Continue the work that was interrupted by the expired login.\n' >&2 ;;
    *) printf 'Continue the work that was interrupted by the API error.\n' >&2 ;;
  esac
}

sleep_until() {
  sleep_target=$1
  [ "$wake_requested" = 0 ] || return 0
  if [ "$effective_now" -lt "$sleep_target" ]; then
    sleep_seconds=$((sleep_target - effective_now))
    if [ "${CLAUDE_RESUME_TEST_SKIP_SLEEP:-}" = 1 ]; then
      effective_now=$sleep_target
    else
      sleep "$sleep_seconds" &
      sleep_pid=$!
      wait "$sleep_pid" 2>/dev/null || true
      if [ "$wake_requested" = 1 ] && kill -0 "$sleep_pid" 2>/dev/null; then
        kill "$sleep_pid" 2>/dev/null || true
        wait "$sleep_pid" 2>/dev/null || true
      fi
      effective_now=$(now_epoch)
    fi
  fi
}

eligible_first_waiter() {
  selected_waiter=
  selected_key=
  selected_due=
  for waiter in "$WAITER_DIR"/*; do
    [ -f "$waiter" ] || continue
    if ! publish_owner_alive "$(read_field "$waiter" pid)" worker "$(read_field "$waiter" token)"; then
      rm -f "$waiter"
      continue
    fi
    waiter_generation=$(number_or_default "$(read_field "$waiter" generation)" 0)
    [ "$waiter_generation" -gt "$recovered_generation" ] || continue
    waiter_due=$(number_or_default "$(read_field "$waiter" due_at)" 0)
    [ "$waiter_due" -le "$effective_now" ] || continue
    waiter_key="$(read_field "$waiter" session).${waiter##*/}"
    if [ -z "$selected_waiter" ] || [ "$waiter_due" -lt "$selected_due" ] || { [ "$waiter_due" -eq "$selected_due" ] && [ "$(printf '%s\n%s\n' "$waiter_key" "$selected_key" | LC_ALL=C sort | sed -n '1p')" = "$waiter_key" ]; }; then
      selected_waiter=$waiter
      selected_key=$waiter_key
      selected_due=$waiter_due
    fi
  done
}

handle_stop_failure() {
  input_now=$(now_epoch)
  acquire_lock
  load_global

  if [ "$episode" -eq 0 ] || { [ "$active_session" = - ] && ! has_unrecovered_waiter && [ "$recovered_generation" -ge "$generation" ]; }; then
    episode=$((episode + 1))
    base_delay=$(base_delay_or_default "${CLAUDE_RESUME_WAIT_SECONDS:-}")
    max_attempts=$(number_or_default "${CLAUDE_RESUME_MAX_ATTEMPTS:-}" 0)
    delay=$base_delay
    last_attempt=0
    attempts=0
    active_session=-
    active_generation=0
    handoff_at=0
    deadline=0
    rm -rf "$CAUSE_DIR"
    mkdir -p "$CAUSE_DIR" "$WAITER_DIR"
  fi

  was_active=0
  if [ "$active_session" = "$session" ]; then
    was_active=1
    active_session=-
    active_generation=0
    handoff_at=0
    delay=$((delay * 2))
    [ "$delay" -le 480 ] || delay=480
  fi

  if [ "$deadline" -gt 0 ] && [ "$input_now" -ge "$deadline" ]; then
    write_global
    release_lock
    return 0
  fi

  cause_file="$CAUSE_DIR/$episode.$error"
  if [ ! -f "$cause_file" ]; then
    cause_end=$(cause_deadline "$error" "$input_now" "$transcript" "$last_message")
    write_atomic "$cause_file" "first_seen=$input_now
deadline=$cause_end"
  fi
  deadline=0
  for current_cause in "$CAUSE_DIR/$episode".*; do
    [ -f "$current_cause" ] || continue
    cause_end=$(number_or_default "$(read_field "$current_cause" deadline)" 0)
    [ "$cause_end" -le "$deadline" ] || deadline=$cause_end
  done

  if [ "$input_now" -ge "$deadline" ] || { [ "$max_attempts" -gt 0 ] && [ "$attempts" -ge "$max_attempts" ]; }; then
    write_global
    release_lock
    return 0
  fi

  registered_waiter="$WAITER_DIR/$session"
  old_initial=$(number_or_default "$(read_field "$registered_waiter" initial_used)" 0)
  if [ -e "$registered_waiter" ]; then registered_waiter="$WAITER_DIR/$session.$worker_token"; fi
  if [ "$was_active" = 1 ] || [ "$old_initial" -gt 0 ]; then
    due_at=$((input_now + delay))
    minimum_due=$((last_attempt + base_delay))
    [ "$due_at" -ge "$minimum_due" ] || due_at=$minimum_due
    initial_used=1
  else
    due_at=$((input_now + base_delay))
    minimum_due=$((last_attempt + base_delay))
    [ "$due_at" -ge "$minimum_due" ] || due_at=$minimum_due
    initial_used=0
  fi
  generation=$((generation + 1))
  waiter_generation=$generation
  write_atomic "$registered_waiter" "pid=$$
token=$worker_token
session=$session
cause=$error
episode=$episode
generation=$waiter_generation
registered_at=$input_now
due_at=$due_at
initial_used=$initial_used"
  write_global
  release_lock
  hold_registered_waiter
  return 1
}

hold_registered_waiter() {
  case "${CLAUDE_RESUME_TEST_REGISTER_BARRIER:-}" in
    '') return ;;
  esac
  mkdir -p "$CLAUDE_RESUME_TEST_REGISTER_BARRIER"
  : > "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$session"
  while [ ! -f "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/release" ]; do
    [ "$wake_requested" = 0 ] || return 0
    sleep 1 || true
  done
}

handle_stop() {
  acquire_lock
  load_global
  if [ "$active_session" != "$session" ]; then
    release_lock
    return 0
  fi
  if [ "$(now_epoch)" -ge "$handoff_at" ]; then
    active_session=-
    active_generation=0
    handoff_at=0
    write_global
    release_lock
    return 0
  fi

  recovered_generation=$generation
  active_session=-
  active_generation=0
  handoff_at=0
  snapshot="$STATE_DIR/signal.$$"
  : > "$snapshot"
  for waiter in "$WAITER_DIR"/*; do
    [ -f "$waiter" ] || continue
    waiter_generation=$(number_or_default "$(read_field "$waiter" generation)" 0)
    [ "$waiter_generation" -le "$recovered_generation" ] || continue
    waiter_pid=$(read_field "$waiter" pid)
    waiter_token=$(read_field "$waiter" token)
    case "$waiter_pid" in ''|*[!0-9]*) continue ;; esac
    case "$waiter_token" in ''|*[!0-9A-Za-z_-]*) continue ;; esac
    printf '%s %s %s\n' "$waiter_pid" "$waiter_generation" "$waiter_token" >> "$snapshot"
  done
  write_global
  release_lock

  case "${CLAUDE_RESUME_TEST_SIGNAL_BARRIER:-}" in
    '') ;;
    *)
      mkdir -p "$CLAUDE_RESUME_TEST_SIGNAL_BARRIER"
      : > "$CLAUDE_RESUME_TEST_SIGNAL_BARRIER/ready"
      while [ ! -f "$CLAUDE_RESUME_TEST_SIGNAL_BARRIER/release" ]; do sleep 1; done
      ;;
  esac

  pid_csv=
  while read -r waiter_pid waiter_generation waiter_token; do
    [ -n "$waiter_pid" ] || continue
    if [ -z "$pid_csv" ]; then pid_csv=$waiter_pid; else pid_csv="$pid_csv,$waiter_pid"; fi
  done < "$snapshot"
  signal_pids=
  if [ -n "$pid_csv" ]; then
    process_lines=$(ps -ww -p "$pid_csv" -o pid= -o command= 2>/dev/null || true)
    while IFS= read -r process_line; do
      process_pid=$(printf '%s\n' "$process_line" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]].*/\1/p')
      [ -n "$process_pid" ] || continue
      process_command=$(printf '%s\n' "$process_line" | sed 's/^[[:space:]]*[0-9][0-9]*[[:space:]][[:space:]]*//')
      while read -r waiter_pid waiter_generation waiter_token; do
        [ "$process_pid" = "$waiter_pid" ] || continue
        case " $process_command " in
          *" --worker $waiter_token "*) signal_pids="$signal_pids $process_pid" ;;
        esac
      done < "$snapshot"
    done <<EOF
$process_lines
EOF
  fi
  [ -z "$signal_pids" ] || kill -USR1 $signal_pids 2>/dev/null || true
  rm -f "$snapshot"
}

wait_for_turn() {
  effective_now=$input_now
  sleep_until "$due_at"
  while :; do
    acquire_lock
    load_global
    current_waiter=$registered_waiter
    if [ "$(read_field "$current_waiter" pid)" != "$$" ] || [ "$(number_or_default "$(read_field "$current_waiter" generation)" 0)" != "$waiter_generation" ]; then
      release_lock
      return 0
    fi
    if [ "$waiter_generation" -le "$recovered_generation" ]; then
      rm -f "$current_waiter"
      release_lock
      return 2
    fi
    if [ "$effective_now" -ge "$deadline" ] || { [ "$max_attempts" -gt 0 ] && [ "$attempts" -ge "$max_attempts" ]; }; then
      rm -f "$current_waiter"
      write_global
      release_lock
      return 0
    fi
    if [ "$active_session" != - ]; then
      if [ "$effective_now" -lt "$handoff_at" ]; then
        next_wake=$handoff_at
        release_lock
        sleep_until "$next_wake"
        continue
      fi
      active_session=-
      active_generation=0
      handoff_at=0
      write_global
    fi
    eligible_first_waiter
    if [ "$selected_waiter" = "$current_waiter" ]; then
      rm -f "$current_waiter"
      active_session=$session
      active_generation=$waiter_generation
      handoff_at=$((effective_now + delay))
      last_attempt=$effective_now
      attempts=$((attempts + 1))
      write_global
      release_lock
      return 2
    fi
    release_lock
    sleep_until "$((effective_now + 1))"
  done
}

stop_matches_active_session() {
  stop_active_session=
  while IFS= read -r stop_global_line; do
    case "$stop_global_line" in
      active_session=*) stop_active_session=${stop_global_line#active_session=}; break ;;
    esac
  done < "$GLOBAL"
  [ "$stop_active_session" = "$session" ]
}

if [ "${1:-}" = --stop ]; then
  process_role=stop
  process_token=${2:-unknown}
  case "$process_token" in ''|*[!0-9A-Za-z_-]*) exit 0 ;; esac
  process_identity=${CLAUDE_RESUME_PROCESS_IDENTITY:-}
  [ "$process_identity" = "$STATE_DIR/$process_token" ] || process_identity=
  session=${CLAUDE_RESUME_STOP_SESSION:-unknown}
  case "$session" in ''|*[!0-9A-Za-z_-]*) session=unknown ;; esac
  trap 'trap_rc=$?; release_publish_lock; release_lock; cleanup_process_identity; exit "$trap_rc"' EXIT
  handle_stop
  exit 0
fi

if [ "${1:-}" = --worker ]; then
  process_role=worker
  worker_token=${2:-unknown}
  case "$worker_token" in ''|*[!0-9A-Za-z_-]*) exit 0 ;; esac
  process_token=$worker_token
  process_identity=${CLAUDE_RESUME_PROCESS_IDENTITY:-}
  [ "$process_identity" = "$STATE_DIR/$process_token" ] || process_identity=
  session=${CLAUDE_RESUME_WORKER_SESSION:-unknown}
  error=${CLAUDE_RESUME_WORKER_ERROR:-other}
  transcript=${CLAUDE_RESUME_WORKER_TRANSCRIPT:-}
  last_message=${CLAUDE_RESUME_WORKER_LAST_MESSAGE:-}
  mkdir -p "$CAUSE_DIR" "$WAITER_DIR"
  trap 'trap_rc=$?; release_publish_lock; release_lock; cleanup_process_identity; exit "$trap_rc"' EXIT
  trap 'wake_requested=1; case "${CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR:-}" in "") ;; *) mkdir -p "$CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR"; : > "$CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR/$session" ;; esac' USR1
  if handle_stop_failure; then
    exit 0
  fi
  wait_result=0
  wait_for_turn || wait_result=$?
  case "$wait_result" in
    2) print_resume_message; exit 2 ;;
    *) exit 0 ;;
  esac
fi

input=$(cat)
session=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || session=
case "$session" in ''|*[!0-9A-Za-z_-]*) session=unknown ;; esac
hook_event=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || hook_event=

case "$hook_event" in
  ''|StopFailure)
    error=$(printf '%s' "$input" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || error=
    case "$error" in rate_limit|authentication_failed|server_error|overloaded) ;; *) error=other ;; esac
    transcript=$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || transcript=
    last_message=$(printf '%s' "$input" | sed -n 's/.*"last_assistant_message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || last_message=
    CLAUDE_RESUME_WORKER_SESSION=$session
    CLAUDE_RESUME_WORKER_ERROR=$error
    CLAUDE_RESUME_WORKER_TRANSCRIPT=$transcript
    CLAUDE_RESUME_WORKER_LAST_MESSAGE=$last_message
    export CLAUDE_RESUME_WORKER_SESSION CLAUDE_RESUME_WORKER_ERROR CLAUDE_RESUME_WORKER_TRANSCRIPT CLAUDE_RESUME_WORKER_LAST_MESSAGE
    create_process_identity
    exec sh "$0" --worker "$process_token"
    ;;
  Stop)
    [ -f "$GLOBAL" ] || exit 0
    stop_matches_active_session || exit 0
    CLAUDE_RESUME_STOP_SESSION=$session
    export CLAUDE_RESUME_STOP_SESSION
    create_process_identity
    exec sh "$0" --stop "$process_token"
    ;;
  *) exit 0 ;;
esac
