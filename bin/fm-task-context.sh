#!/usr/bin/env bash
# fm-task-context.sh - maintain durable per-task context records.
#
# This header owns the private task-context schema and mutation contract.
#
# Record path: data/<task-id>/task-context.json in the active firstmate home.
# The record is private home data, not tracked project memory.
# The producer never reads terminal transcripts, tool-call streams, pane output,
# routine supervision wakes, credentials, or unrelated conversation history.
# It reads only the task's own brief, metadata, status events passed by lifecycle
# producers, PR/report artifact pointers, and the task-owned report file.
#
# Schema firstmate.task-context.v1:
#   schema_id             fixed string, "firstmate.task-context.v1"
#   task_id               task id
#   title                 short display title derived from original_ask or task id
#   project               project directory name or null
#   kind                  ship, scout, secondmate, or null
#   delivery_mode         no-mistakes, direct-PR, local-only, secondmate, or null
#   state                 working, needs-decision, blocked, paused, done, failed,
#                         merged, cleaned-up, or unknown
#   category              active, action-required, waiting, complete, failed, or
#                         legacy
#   created_at            Unix epoch seconds when this record was first written
#   updated_at            Unix epoch seconds when semantic content last changed
#   original_ask          stable body of ## Captain's intent, preserved once set
#   brief_summary         concise summary derived from original_ask
#   outcome_summary       newest consequential outcome/status summary
#   decisions_constraints consequential needs-decision, blocked, resolved, and
#                         constraint-like status events; duplicate keys collapse
#   artifacts             typed PR, report, local-merge, and cleanup artifacts
#   next_action           short next action implied by state/category
#   legacy_context        false for authoritative records
#
# Activity export:
#   fm-task-context.sh activity emits
#   {"schema_id":"firstmate.activity.v1","generated_at":<epoch>,
#    "retention_days":<days>,"items":[...]}.
#   Items come from task-context.json files updated within the retention window.
#   Older task directories without a valid context record are retained as
#   legacy/thin items when their own brief, report, meta, or status file is in
#   the same window; those items carry legacy_context:true and
#   legacy_context_reason.
#   FM_ACTIVITY_RETENTION_DAYS defaults to 90 and must be a positive integer.
#
# Mutations:
#   dispatched <task> <kind> <project> <mode> creates or refreshes the record
#     from the filled brief and metadata, preserving an existing original_ask.
#   status <task> <line> folds one consequential status event into the record.
#     Empty, malformed, and routine supervision/tool-looking lines are ignored.
#   pr_ready <task> <url>, merged <task> pr <url>, merged <task> local, and
#     cleaned_up <task> update the same record without duplicating artifacts.
#   reconcile <task> re-reads task-owned report artifacts and metadata.
#   activity exports the bounded activity document.
#
# All writes are same-directory atomic mv operations under umask 077 and a
# per-task state/.task-context.<task>.lock lock.
# Existing malformed context records are not overwritten by mutation commands;
# activity marks that task as legacy/thin instead.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE, and
# FM_CONFIG_OVERRIDE resolve the home like other bin/ scripts.
#
# Exit status: 0 on success or ignored/no-op, 2 on usage or unsafe task id/path,
# 1 on an I/O or JSON error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK_PREFIX="$STATE/.task-context"
SCHEMA_ID=firstmate.task-context.v1
ACTIVITY_SCHEMA_ID=firstmate.activity.v1

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-task-context.sh dispatched <task> <kind> <project> <mode>
       fm-task-context.sh status <task> <status-line>
       fm-task-context.sh pr_ready <task> <url>
       fm-task-context.sh merged <task> pr <url>
       fm-task-context.sh merged <task> local
       fm-task-context.sh cleaned_up <task>
       fm-task-context.sh reconcile <task>
       fm-task-context.sh activity
EOF
  exit 2
}

task_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

epoch_now() {
  date +%s
}

positive_int_or_default() { # <value> <default>
  case "${1:-}" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

task_dir() { # <task>
  printf '%s/%s' "$DATA" "$1"
}

context_path() { # <task>
  printf '%s/%s/task-context.json' "$DATA" "$1"
}

brief_path() { # <task>
  printf '%s/%s/brief.md' "$DATA" "$1"
}

report_path() { # <task>
  printf '%s/%s/report.md' "$DATA" "$1"
}

meta_path() { # <task>
  printf '%s/%s.meta' "$STATE" "$1"
}

status_path() { # <task>
  printf '%s/%s.status' "$STATE" "$1"
}

ensure_task_confined() { # <task>
  local id=$1 data_real dir parent_real
  task_ok "$id" || return 2
  mkdir -p "$DATA" "$STATE" || return 1
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 2
  data_real=$(cd "$DATA" && pwd -P) || return 1
  dir=$(task_dir "$id")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 2
    parent_real=$(cd "$dir" && pwd -P) || return 1
    case "$parent_real/" in "$data_real/$id/"*) ;; *) return 2 ;; esac
  else
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true
  fi
}

valid_context() { # <file> <task>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  jq -e --arg schema "$SCHEMA_ID" --arg task "$2" \
    '.schema_id == $schema and .task_id == $task and (.legacy_context == false)' "$1" >/dev/null 2>&1
}

trim_text() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

brief_original_ask() { # <task>
  local brief ask
  brief=$(brief_path "$1")
  [ -f "$brief" ] && [ ! -L "$brief" ] || return 0
  if fm_brief_task_heading_present "$brief" "## Captain's intent"; then
    ask=$(fm_brief_task_heading_body "$brief" "## Captain's intent" | trim_text)
  else
    ask=
  fi
  printf '%s\n' "$ask"
}

brief_summary_from_ask() { # <ask>
  printf '%s' "$1" | tr '\n' ' ' | awk '
    {
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if (length($0) > 220) print substr($0, 1, 217) "..."
      else print
    }'
}

title_from_ask() { # <task> <ask>
  local id=$1 ask=$2 summary
  summary=$(brief_summary_from_ask "$ask")
  if [ -z "$summary" ]; then
    printf '%s\n' "$id"
  else
    printf '%s\n' "$summary" | awk '{ if (length($0) > 90) print substr($0, 1, 87) "..."; else print }'
  fi
}

meta_value() { # <task> <key>
  local meta
  meta=$(meta_path "$1")
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  grep "^$2=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

existing_or_null() { # <record> <jq-filter>
  local file=$1 filter=$2
  if valid_context "$file" "$CURRENT_TASK"; then
    jq -c "$filter // null" "$file"
  else
    printf 'null\n'
  fi
}

report_excerpt_json() { # <task>
  local report text
  report=$(report_path "$1")
  [ -f "$report" ] && [ ! -L "$report" ] || { printf 'null\n'; return 0; }
  text=$(awk '
    BEGIN { max = 900 }
    NF { seen = 1 }
    seen {
      if (length(out) + length($0) + 1 > max) {
        remain = max - length(out) - 4
        if (remain > 0) out = out substr($0, 1, remain) "..."
        print out
        exit
      }
      out = out (out == "" ? "" : "\n") $0
    }
    END { if (out != "") print out }
  ' "$report")
  [ -n "$text" ] || { printf 'null\n'; return 0; }
  jq -cn --arg text "$text" '$text'
}

normalize_state() { # <state>
  case "$1" in
    needs-decision|blocked|paused|done|failed|working|merged|cleaned-up) printf '%s\n' "$1" ;;
    resolved) printf '%s\n' working ;;
    *) printf '%s\n' unknown ;;
  esac
}

category_for_state() { # <state>
  case "$1" in
    needs-decision|blocked) printf '%s\n' action-required ;;
    paused) printf '%s\n' waiting ;;
    done|merged|cleaned-up) printf '%s\n' complete ;;
    failed) printf '%s\n' failed ;;
    working) printf '%s\n' active ;;
    *) printf '%s\n' legacy ;;
  esac
}

next_action_for() { # <state> <text>
  local state=$1 text=$2
  case "$state" in
    needs-decision) printf 'Answer needed: %s\n' "$text" ;;
    blocked) printf 'Unblock needed: %s\n' "$text" ;;
    paused) printf 'Wait for: %s\n' "$text" ;;
    done) printf 'Review delivery and land or clean up.\n' ;;
    merged) printf 'Clean up the completed task.\n' ;;
    cleaned-up) printf 'No next action.\n' ;;
    failed) printf 'Inspect failure and decide recovery.\n' ;;
    working) printf 'Worker continues.\n' ;;
    *) printf 'Inspect legacy task context.\n' ;;
  esac
}

routine_status_line() { # <verb> <text>
  local verb=$1 text=$2 lower
  [ -n "$verb" ] || return 0
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"watcher"*|*"supervision"*|*"heartbeat"*|*"wake queue"*|*"wake-queue"*|*"tool call"*|*"tool-call"*|*"turn-end"*|*"turnend"*) return 0 ;;
  esac
  return 1
}

write_record() { # <task> <candidate-json>
  local id=$1 candidate=$2 path tmp old normalized changed
  path=$(context_path "$id")
  if [ -e "$path" ] || [ -L "$path" ]; then
    valid_context "$path" "$id" || return 0
  fi
  normalized=$(printf '%s' "$candidate" | jq -S -c '.') || return 1
  if [ -f "$path" ]; then
    old=$(jq -S -c '.' "$path" 2>/dev/null || true)
    [ "$old" = "$normalized" ] && return 0
    old=$(jq -S -c 'del(.updated_at)' "$path" 2>/dev/null || true)
    changed=$(printf '%s' "$candidate" | jq -S -c 'del(.updated_at)') || return 1
    [ "$old" = "$changed" ] && return 0
  fi
  tmp=$(umask 077; mktemp "$(dirname "$path")/.task-context.json.XXXXXX") || return 1
  if ! printf '%s\n' "$normalized" > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

base_record_json() { # <task> <kind> <project> <mode> <state> <outcome> <next>
  local id=$1 kind=$2 project=$3 mode=$4 state=$5 outcome=$6 next=$7
  local path created now ask existing_ask title summary category
  CURRENT_TASK=$id
  path=$(context_path "$id")
  now=$(epoch_now)
  created=$(existing_or_null "$path" '.created_at')
  [ "$created" != null ] || created=$now
  existing_ask=$(existing_or_null "$path" '.original_ask')
  if [ "$existing_ask" = null ] || [ "$existing_ask" = '""' ]; then
    ask=$(brief_original_ask "$id")
  else
    ask=$(printf '%s' "$existing_ask" | jq -r '.')
  fi
  summary=$(brief_summary_from_ask "$ask")
  title=$(title_from_ask "$id" "$ask")
  category=$(category_for_state "$state")
  jq -cn \
    --arg schema "$SCHEMA_ID" --arg task "$id" --arg title "$title" \
    --arg kind "$kind" --arg project "$project" --arg mode "$mode" \
    --arg state "$state" --arg category "$category" --arg ask "$ask" \
    --arg brief_summary "$summary" --arg outcome "$outcome" --arg next "$next" \
    --argjson created "$created" --argjson updated "$now" \
    'def n: if . == "" then null else . end;
     {schema_id:$schema, task_id:$task, title:$title, project:($project|n),
      kind:($kind|n), delivery_mode:($mode|n), state:$state, category:$category,
      created_at:$created, updated_at:$updated, original_ask:$ask,
      brief_summary:$brief_summary, outcome_summary:$outcome,
      decisions_constraints:[], artifacts:[], next_action:$next,
      legacy_context:false}'
}

merge_existing_arrays() { # <task> <record-json>
  local id=$1 record=$2 path report_excerpt
  CURRENT_TASK=$id
  path=$(context_path "$id")
  report_excerpt=$(report_excerpt_json "$id")
  if valid_context "$path" "$id"; then
    record=$(jq -c --slurpfile old "$path" '
      .decisions_constraints = ((.decisions_constraints // []) + ($old[0].decisions_constraints // [])
        | unique_by(if (.key // null) == null then [.type, .key, .summary] else [.type, .key] end))
      | .artifacts = ((.artifacts // []) + ($old[0].artifacts // [])
        | unique_by([.type, (.url // ""), (.path // ""), (.label // "")]))
    ' <<<"$record") || return 1
  fi
  if [ "$report_excerpt" != null ]; then
    record=$(jq -c --arg path "data/$id/report.md" --argjson excerpt "$report_excerpt" '
      .artifacts = ([{type:"report", label:"Report", path:$path, excerpt:$excerpt}] + (.artifacts // [])
        | unique_by([.type, (.url // ""), (.path // ""), (.label // "")]))
    ' <<<"$record") || return 1
  fi
  printf '%s\n' "$record"
}

update_dispatched() { # <task> <kind> <project> <mode>
  local id=$1 kind=$2 project=$3 mode=$4 record
  ensure_task_confined "$id" || return $?
  record=$(base_record_json "$id" "$kind" "$project" "$mode" working "" "Worker continues.") || return 1
  record=$(merge_existing_arrays "$id" "$record") || return 1
  write_record "$id" "$record"
}

extract_pr_url() { # <line>
  printf '%s\n' "$1" | sed -n 's#.*\(https://[^[:space:]]*/pull/[0-9][0-9]*\).*#\1#p' | head -1
}

update_status() { # <task> <line>
  local id=$1 line=$2 verb key text state next record pr decision_type
  ensure_task_confined "$id" || return $?
  status_line_verb "$line" verb
  case "$verb" in [a-z]*) case "$verb" in *[!a-z-]*) verb='' ;; esac ;; *) verb='' ;; esac
  text=$(status_line_note "$line" | trim_text)
  routine_status_line "$verb" "$text" && return 0
  state=$(normalize_state "$verb")
  [ "$state" != unknown ] || return 0
  next=$(next_action_for "$state" "$text")
  record=$(base_record_json "$id" "$(meta_value "$id" kind)" "$(meta_value "$id" project)" "$(meta_value "$id" mode)" "$state" "$text" "$next") || return 1
  key=$(_fm_decision_key "$line" 2>/dev/null) || key=
  [ "$key" != default ] || key=
  case "$verb" in
    needs-decision|blocked|resolved)
      decision_type=$verb
      record=$(jq -c --arg type "$decision_type" --arg key "$key" --arg summary "$text" --argjson at "$(epoch_now)" '
        .decisions_constraints = (.decisions_constraints + [{type:$type, key:(if $key == "" then null else $key end), summary:$summary, updated_at:$at}])
      ' <<<"$record") || return 1
      ;;
  esac
  pr=$(extract_pr_url "$line")
  if [ -n "$pr" ]; then
    record=$(jq -c --arg pr "$pr" '
      .artifacts = (.artifacts + [{type:"pr", label:"Pull request", url:$pr}]
        | unique_by([.type, (.url // ""), (.path // ""), (.label // "")]))
    ' <<<"$record") || return 1
  fi
  record=$(merge_existing_arrays "$id" "$record") || return 1
  write_record "$id" "$record"
}

update_pr_ready() { # <task> <url>
  local id=$1 url=$2 record
  ensure_task_confined "$id" || return $?
  record=$(base_record_json "$id" "$(meta_value "$id" kind)" "$(meta_value "$id" project)" "$(meta_value "$id" mode)" 'done' "PR ready: $url" "Review delivery and land or clean up.") || return 1
  record=$(jq -c --arg url "$url" '.artifacts = (.artifacts + [{type:"pr", label:"Pull request", url:$url}])' <<<"$record") || return 1
  record=$(merge_existing_arrays "$id" "$record") || return 1
  write_record "$id" "$record"
}

update_merged() { # <task> <via> [url]
  local id=$1 via=$2 url=${3:-} record outcome
  ensure_task_confined "$id" || return $?
  if [ "$via" = pr ]; then
    outcome="Merged PR: $url"
  else
    outcome="Merged local branch."
  fi
  record=$(base_record_json "$id" "$(meta_value "$id" kind)" "$(meta_value "$id" project)" "$(meta_value "$id" mode)" merged "$outcome" "Clean up the completed task.") || return 1
  if [ "$via" = pr ]; then
    record=$(jq -c --arg url "$url" '.artifacts = (.artifacts + [{type:"pr", label:"Merged pull request", url:$url}])' <<<"$record") || return 1
  else
    record=$(jq -c '.artifacts = (.artifacts + [{type:"local-merge", label:"Merged into local default branch"}])' <<<"$record") || return 1
  fi
  record=$(merge_existing_arrays "$id" "$record") || return 1
  write_record "$id" "$record"
}

update_cleaned_up() { # <task>
  local id=$1 record
  ensure_task_confined "$id" || return $?
  record=$(base_record_json "$id" "$(meta_value "$id" kind)" "$(meta_value "$id" project)" "$(meta_value "$id" mode)" cleaned-up "Worker and local copy cleaned up." "No next action.") || return 1
  record=$(jq -c '.artifacts = (.artifacts + [{type:"cleanup", label:"Task cleanup complete"}])' <<<"$record") || return 1
  record=$(merge_existing_arrays "$id" "$record") || return 1
  write_record "$id" "$record"
}

update_reconcile() { # <task>
  local id=$1 record
  ensure_task_confined "$id" || return $?
  record=$(base_record_json "$id" "$(meta_value "$id" kind)" "$(meta_value "$id" project)" "$(meta_value "$id" mode)" "$(normalize_state "$(meta_value "$id" state)")" "" "Inspect task context.") || return 1
  record=$(merge_existing_arrays "$id" "$record") || return 1
  write_record "$id" "$record"
}

legacy_item_json() { # <task> <reason>
  local id=$1 reason=$2 ask title project kind mode state category updated excerpt raw
  ask=$(brief_original_ask "$id")
  title=$(title_from_ask "$id" "$ask")
  project=$(meta_value "$id" project)
  kind=$(meta_value "$id" kind)
  mode=$(meta_value "$id" mode)
  state=unknown
  if [ -f "$(status_path "$id")" ] && [ ! -L "$(status_path "$id")" ]; then
    raw=$(status_current_line "$(status_path "$id")" "$(meta_value "$id" kind)" 2>/dev/null || true)
    status_line_verb "$raw" state
    state=$(normalize_state "$state")
  fi
  category=legacy
  updated=$(latest_task_mtime "$id")
  excerpt=$(report_excerpt_json "$id")
  jq -cn --arg schema "$SCHEMA_ID" --arg task "$id" --arg title "$title" \
    --arg kind "$kind" --arg project "$project" --arg mode "$mode" \
    --arg state "$state" --arg category "$category" --arg ask "$ask" \
    --arg reason "$reason" --argjson updated "$updated" --argjson excerpt "$excerpt" \
    'def n: if . == "" then null else . end;
     {schema_id:$schema, task_id:$task, title:$title, project:($project|n),
      kind:($kind|n), delivery_mode:($mode|n), state:$state,
      category:$category, created_at:$updated, updated_at:$updated,
      original_ask:$ask, brief_summary:$ask, outcome_summary:"",
      decisions_constraints:[], artifacts:[], next_action:"Inspect legacy task context.",
      legacy_context:true, legacy_context_reason:$reason}
      | if $excerpt == null then . else .artifacts += [{type:"report", label:"Report", path:("data/" + $task + "/report.md"), excerpt:$excerpt}] end'
}

latest_task_mtime() { # <task>
  local id=$1 newest=0 f mt
  for f in "$(brief_path "$id")" "$(report_path "$id")" "$(meta_path "$id")" "$(status_path "$id")" "$(context_path "$id")"; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || printf 0)
    [ "$mt" -gt "$newest" ] && newest=$mt
  done
  [ "$newest" -gt 0 ] || newest=$(epoch_now)
  printf '%s\n' "$newest"
}

activity_export() {
  local days now cutoff tmp id ctx reason mt data_real state_real
  days=$(positive_int_or_default "${FM_ACTIVITY_RETENTION_DAYS:-}" 90)
  now=$(epoch_now)
  cutoff=$((now - days * 86400))
  mkdir -p "$DATA" "$STATE" || return 1
  data_real=$(cd "$DATA" && pwd -P) || return 1
  state_real=$(cd "$STATE" && pwd -P) || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-task-context-activity.XXXXXX") || return 1
  : > "$tmp"
  for ctx in "$DATA"/*/task-context.json; do
    [ -f "$ctx" ] && [ ! -L "$ctx" ] || continue
    id=${ctx%/task-context.json}
    id=${id##*/}
    task_ok "$id" || continue
    [ "$(cd "$(dirname "$ctx")" && pwd -P 2>/dev/null)" = "$data_real/$id" ] || continue
    if valid_context "$ctx" "$id"; then
      mt=$(jq -r '.updated_at // 0' "$ctx" 2>/dev/null || printf 0)
      case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
      [ "$mt" -ge "$cutoff" ] || continue
      jq -c '.' "$ctx" >> "$tmp" || true
    fi
  done
  for ctx in "$DATA"/*; do
    [ -d "$ctx" ] && [ ! -L "$ctx" ] || continue
    id=${ctx##*/}
    task_ok "$id" || continue
    [ "$(cd "$ctx" && pwd -P 2>/dev/null)" = "$data_real/$id" ] || continue
    if valid_context "$ctx/task-context.json" "$id"; then
      continue
    fi
    reason=no-context-record
    [ ! -e "$ctx/task-context.json" ] || reason=malformed-context
    mt=$(latest_task_mtime "$id")
    [ "$mt" -ge "$cutoff" ] || continue
    legacy_item_json "$id" "$reason" >> "$tmp" || true
  done
  for ctx in "$STATE"/*.meta "$STATE"/*.status; do
    [ -f "$ctx" ] && [ ! -L "$ctx" ] || continue
    [ "$(cd "$(dirname "$ctx")" && pwd -P 2>/dev/null)" = "$state_real" ] || continue
    id=${ctx##*/}
    id=${id%.meta}
    id=${id%.status}
    task_ok "$id" || continue
    if valid_context "$(context_path "$id")" "$id"; then
      continue
    fi
    if grep -Fq "\"task_id\":\"$id\"" "$tmp" 2>/dev/null; then
      continue
    fi
    mt=$(latest_task_mtime "$id")
    [ "$mt" -ge "$cutoff" ] || continue
    legacy_item_json "$id" no-context-record >> "$tmp" || true
  done
  jq -s --arg schema "$ACTIVITY_SCHEMA_ID" --argjson generated "$now" --argjson days "$days" '
    {schema_id:$schema, generated_at:$generated, retention_days:$days,
     items:(sort_by(.updated_at, .task_id) | reverse)}
  ' "$tmp"
  rm -f -- "$tmp"
}

cmd=${1:-}
case "$cmd" in
  dispatched) [ "$#" -eq 5 ] || usage ;;
  status) [ "$#" -eq 3 ] || usage ;;
  pr_ready) [ "$#" -eq 3 ] || usage ;;
  merged)
    case "$#:${3:-}" in 4:pr|3:local) ;; *) usage ;; esac
    ;;
  cleaned_up|reconcile) [ "$#" -eq 2 ] || usage ;;
  activity) [ "$#" -eq 1 ] || usage ;;
  *) usage ;;
esac

case "$cmd" in
  activity)
    activity_export
    ;;
  *)
    task_ok "$2" || exit 2
    mkdir -p "$STATE" || exit 1
    LOCK="$LOCK_PREFIX.$2.lock"
    fm_lock_acquire_wait "$LOCK" || exit 1
    trap 'fm_lock_release "$LOCK"' EXIT
    case "$cmd" in
      dispatched) update_dispatched "$2" "$3" "$4" "$5" ;;
      status) update_status "$2" "$3" ;;
      pr_ready) update_pr_ready "$2" "$3" ;;
      merged)
        if [ "$3" = pr ]; then update_merged "$2" pr "$4"; else update_merged "$2" local; fi
        ;;
      cleaned_up) update_cleaned_up "$2" ;;
      reconcile) update_reconcile "$2" ;;
    esac
    ;;
esac
