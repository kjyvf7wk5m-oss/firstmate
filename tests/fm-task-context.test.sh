#!/usr/bin/env bash
# Behavior tests for the durable per-task context record and activity export.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-context)
CTX="$ROOT/bin/fm-task-context.sh"

make_home() { # <name>
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

write_brief() { # <home> <task> <intent>
  local home=$1 task=$2 intent=$3
  mkdir -p "$home/data/$task"
  cat > "$home/data/$task/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Fixture spec.
EOF
}

write_meta() { # <home> <task> [mode]
  local home=$1 task=$2 mode=${3:-no-mistakes}
  fm_write_meta "$home/state/$task.meta" \
    "kind=ship" \
    "project=sample" \
    "mode=$mode"
}

ctx() { # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$CTX" "$@"
}

json() { # <home> <task> <jq-filter>
  jq -r "$3" "$1/data/$2/task-context.json"
}

test_dispatched_preserves_original_ask_and_updates_state() {
  local home task before after
  home=$(make_home preserve)
  task=ctx-preserve
  write_brief "$home" "$task" "Implement activity context."
  write_meta "$home" "$task"

  ctx "$home" dispatched "$task" ship sample no-mistakes \
    || fail "dispatched context write failed"
  assert_equals "Implement activity context." "$(json "$home" "$task" '.original_ask')" \
    "original ask was not captured"
  assert_equals "working" "$(json "$home" "$task" '.state')" \
    "dispatch did not mark the task active"

  before=$(jq -S -c '.original_ask' "$home/data/$task/task-context.json")
  write_brief "$home" "$task" "Changed brief text that must not replace the original ask."
  ctx "$home" status "$task" 'needs-decision [key=route]: choose route' \
    || fail "status context write failed"
  after=$(jq -S -c '.original_ask' "$home/data/$task/task-context.json")
  assert_equals "$before" "$after" "later reconciliation replaced the original ask"
  assert_equals "action-required" "$(json "$home" "$task" '.category')" \
    "needs-decision did not move the category"
  assert_equals "choose route" "$(json "$home" "$task" '.decisions_constraints[0].summary')" \
    "decision summary was not captured"
  pass "task context: dispatch captures and preserves original ask while status moves category"
}

test_status_noise_and_duplicate_filtering() {
  local home task before count
  home=$(make_home noise)
  task=ctx-noise
  write_brief "$home" "$task" "Track meaningful transitions."
  write_meta "$home" "$task"

  ctx "$home" dispatched "$task" ship sample no-mistakes \
    || fail "dispatch failed"
  before=$(jq -S -c 'del(.updated_at)' "$home/data/$task/task-context.json")
  ctx "$home" status "$task" 'working: watcher heartbeat supervision tool call' \
    || fail "routine status no-op failed"
  assert_equals "$before" "$(jq -S -c 'del(.updated_at)' "$home/data/$task/task-context.json")" \
    "routine watcher/tool noise changed the context record"

  ctx "$home" status "$task" 'blocked [key=quota]: need quota' \
    || fail "first blocked status failed"
  ctx "$home" status "$task" 'blocked [key=quota]: need quota' \
    || fail "duplicate blocked status failed"
  count=$(json "$home" "$task" '.decisions_constraints | length')
  assert_equals 1 "$count" "duplicate status event produced duplicate decision entries"
  pass "task context: routine status noise is ignored and repeated decisions are idempotent"
}

test_artifacts_reports_and_cleanup_survive_runtime_state_removal() {
  local home task out
  home=$(make_home artifacts)
  task=ctx-artifacts
  write_brief "$home" "$task" "Ship a report-backed fix."
  write_meta "$home" "$task" local-only
  cat > "$home/data/$task/report.md" <<'EOF'
# Report
The fix landed cleanly.
EOF

  ctx "$home" dispatched "$task" ship sample local-only \
    || fail "dispatch failed"
  ctx "$home" status "$task" 'done: PR https://github.com/acme/sample/pull/9 checks green' \
    || fail "done status failed"
  ctx "$home" merged "$task" local \
    || fail "local merge context failed"
  ctx "$home" cleaned_up "$task" \
    || fail "cleanup context failed"
  rm -f "$home/state/$task.status" "$home/state/$task.meta"

  out=$(ctx "$home" activity)
  printf '%s' "$out" | jq -e --arg task "$task" '
    .schema_id == "firstmate.activity.v1"
    and .retention_days == 90
    and (.items[] | select(.task_id == $task)
      | .legacy_context == false
        and .state == "cleaned-up"
        and (.artifacts | any(.type == "pr" and .url == "https://github.com/acme/sample/pull/9"))
        and (.artifacts | any(.type == "report" and (.excerpt | contains("fix landed"))))
        and (.artifacts | any(.type == "cleanup")))
  ' >/dev/null || fail "activity export lost completed context after runtime cleanup: $out"
  pass "task context: PR/report/local-merge/cleanup artifacts survive runtime cleanup"
}

test_legacy_and_malformed_records_export_as_thin_items() {
  local home out
  home=$(make_home legacy)
  write_brief "$home" legacy-thin "Older task without a context record."
  write_meta "$home" legacy-thin
  write_brief "$home" malformed-thin "Older task with a malformed context record."
  write_meta "$home" malformed-thin
  printf '{not json\n' > "$home/data/malformed-thin/task-context.json"

  out=$(ctx "$home" activity)
  printf '%s' "$out" | jq -e '
    (.items | any(.task_id == "legacy-thin"
      and .legacy_context == true
      and .legacy_context_reason == "no-context-record"))
    and (.items | any(.task_id == "malformed-thin"
      and .legacy_context == true
      and .legacy_context_reason == "malformed-context"))
  ' >/dev/null || fail "activity export did not mark legacy/thin records clearly: $out"
  pass "task context: absent and malformed context records remain visible as legacy/thin items"
}

test_atomic_writes_and_path_confinement() {
  local home task out rc=0
  home=$(make_home safety)
  task=ctx-safe
  write_brief "$home" "$task" "Keep writes atomic and confined."
  write_meta "$home" "$task"

  ctx "$home" dispatched "$task" ship sample no-mistakes \
    || fail "dispatch failed"
  out=$(find "$home/data/$task" -name '.task-context.json.*' -print)
  assert_equals "" "$out" "atomic write left a temporary context file behind"

  out=$(ctx "$home" dispatched '../escape' ship sample no-mistakes 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe task id was accepted"
  assert_absent "$home/data/../escape/task-context.json" "unsafe task id wrote outside its task directory"

  ln -s "$TMP_ROOT/outside" "$home/data/symlink-task"
  mkdir -p "$TMP_ROOT/outside"
  rc=0
  out=$(ctx "$home" dispatched symlink-task ship sample no-mistakes 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "symlink task directory was accepted"
  assert_absent "$TMP_ROOT/outside/task-context.json" "symlink task directory received a context write"
  pass "task context: writes are atomic and task paths are confined"
}

test_dispatched_integration_from_spawn_and_status_command() {
  local home task brief cmd out fakebin proj wt
  home=$(make_home integration)
  task=ctx-integration
  proj="$TMP_ROOT/integration/project"
  wt="$TMP_ROOT/integration/wt"
  fakebin=$(fm_fakebin "$TMP_ROOT/integration/fake")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  fm_git_worktree "$proj" "$wt" "fm/$task"
  mkdir -p "$home/projects" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$task" sample --mode no-mistakes >/dev/null \
    || fail "brief scaffold failed"
  perl -0pi -e 's/\{TASK\}/Spawn should create context./; s/\{FIRSTMATE_SPEC\}/Fixture spec./' \
    "$home/data/$task/brief.md"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn.sh" "$task" "$proj" --mode no-mistakes --yolo off 2>&1) \
    || fail "spawn failed: $out"
  assert_equals "Spawn should create context." "$(json "$home" "$task" '.original_ask')" \
    "spawn did not create the task context record"

  brief="$home/data/$task/brief.md"
  # shellcheck disable=SC2016 # Match literal backticks in the generated interface.
  cmd=$(sed -n '/`fm_status_line=/s/.*`\(fm_status_line=.*\)`.*/\1/p' "$brief" | head -1)
  [ -n "$cmd" ] || fail "brief did not carry a generated status command"
  cmd=${cmd//\{state\}/failed}
  cmd=${cmd//<epoch>/1790000000}
  cmd=${cmd//\{one short line\}/tests broke}
  env -i PATH="$PATH" HOME="$home/user-home" bash -c "$cmd" \
    || fail "generated status command failed"
  assert_equals "failed" "$(json "$home" "$task" '.state')" \
    "generated status command did not update task context"
  pass "task context: spawn and generated worker status command integrate with lifecycle"
}

test_dispatched_preserves_original_ask_and_updates_state
test_status_noise_and_duplicate_filtering
test_artifacts_reports_and_cleanup_survive_runtime_state_removal
test_legacy_and_malformed_records_export_as_thin_items
test_atomic_writes_and_path_confinement
test_dispatched_integration_from_spawn_and_status_command
