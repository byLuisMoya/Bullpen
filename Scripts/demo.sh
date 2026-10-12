#!/usr/bin/env bash
# Demo data for trying the app without spending tokens:
#   Scripts/demo.sh start   create 3 demo projects (3, 1 and 0 worktrees) and fake agent states
#   Scripts/demo.sh stop    remove everything the demo created
# Agents are simulated: each "agent" terminal runs `sleep`, and states are set by sending
# hook events with `bp hook`, exactly like Claude Code's hooks would.
set -euo pipefail
cd "$(dirname "$0")/.."
DEMO=${BULLPEN_DEMO_DIR:-/tmp/bullpen-demo}
DB="$HOME/Library/Application Support/Bullpen/bullpen.sqlite"
WT="$HOME/Bullpen/worktrees"
APP=build/Bullpen.app/Contents/MacOS
BP=$APP/bp

stop() {
    if [[ -f "$DEMO/ids" ]]; then
        while read -r id; do
            "$BP" sessions kill "wt-$id" --signal 9 2>/dev/null || true
            sleep 0.2
            "$BP" sessions rm "wt-$id" 2>/dev/null || true
            rm -f "$HOME/Library/Application Support/Bullpen/sessions/wt-$id".*
        done < "$DEMO/ids"
    fi
    if [[ -f "$DB" ]]; then
        sqlite3 "$DB" "PRAGMA foreign_keys=ON; delete from project where path like '$DEMO/%';"
    fi
    for repo in "$DEMO"/demo-*; do
        [[ -d "$repo/.git" ]] || continue
        git -C "$repo" worktree list --porcelain | awk '/^worktree /{print $2}' | tail -n +2 | while read -r w; do
            git -C "$repo" worktree remove --force "$w" 2>/dev/null || true
        done
    done
    rm -rf "$WT"/demo-web "$WT"/demo-api "$DEMO"
    echo "Demo removed."
}

event() { # session-uuid event [tool] [command or prompt]
    local json="{\"hook_event_name\":\"$2\""
    [[ -n "${3:-}" ]] && json+=",\"tool_name\":\"$3\""
    [[ -n "${4:-}" && "$2" == "UserPromptSubmit" ]] && json+=",\"prompt\":\"$4\""
    [[ -n "${4:-}" && "$2" != "UserPromptSubmit" ]] && json+=",\"tool_input\":{\"command\":\"$4\"}"
    echo "$json}" | BULLPEN_SESSION_ID="wt-$1" "$BP" hook claude
}

start() {
    [[ -x "$BP" ]] || { echo "Run 'make app' first."; exit 1; }
    stop >/dev/null
    mkdir -p "$DEMO"
    mk() {
        git init -q -b main "$DEMO/$1"
        git -C "$DEMO/$1" -c user.email=demo@example.com -c user.name=Demo commit -q --allow-empty -m init
    }
    mk demo-web; mk demo-api; mk demo-docs
    git init -q --bare "$DEMO/remote.git"
    git -C "$DEMO/demo-web" remote add origin "$DEMO/remote.git"
    git -C "$DEMO/demo-web" push -q -u origin main

    # The app migrates the database: open it once if this build's tables aren't there yet.
    if ! sqlite3 "$DB" "select runID from worktree limit 0" >/dev/null 2>&1; then
        open -g build/Bullpen.app
        for _ in $(seq 1 40); do
            sqlite3 "$DB" "select runID from worktree limit 0" >/dev/null 2>&1 && break
            sleep 0.25
        done
    fi

    # Make sure the daemon is up (the app also starts it).
    "$BP" sessions >/dev/null 2>&1 || { ("$APP/bpd" >/dev/null 2>&1 &); sleep 0.5; }

    local p1 p2 p3 now="strftime('%Y-%m-%d %H:%M:%f','now')"
    p1=$(uuidgen); p2=$(uuidgen); p3=$(uuidgen)
    hex() { echo "$1" | tr -d '-'; }
    sqlite3 "$DB" "insert into project(id,name,path,defaultBaseRef,sortIndex,createdAt) values
        (X'$(hex "$p1")','demo-web','$DEMO/demo-web','main',100,$now),
        (X'$(hex "$p2")','demo-api','$DEMO/demo-api','main',101,$now),
        (X'$(hex "$p3")','demo-docs','$DEMO/demo-docs','main',102,$now);"

    wt() { # project-uuid repo branch agent(claude|codex|"") [run-uuid] -> prints worktree uuid
        local id path; id=$(uuidgen); path="$WT/$2/$(echo "$3" | tr '/' '-')"
        git -C "$DEMO/$2" worktree add -q -b "$3" "$path" main
        local agent="NULL"; [[ -n "$4" ]] && agent="'$4'"
        local run="NULL"; [[ -n "${5:-}" ]] && run="X'$(hex "$5")'"
        sqlite3 "$DB" "insert into worktree(id,projectID,branch,path,baseRef,createdAt,agentProfileID,runID) values
            (X'$(hex "$id")',X'$(hex "$1")','$3','$path','main',$now,$agent,$run);"
        if [[ -n "$4" ]]; then
            "$BP" sessions start "wt-$id" --cwd "$path" --command "exec -a claude sleep 86400" >/dev/null
        else
            "$BP" sessions start "wt-$id" --cwd "$path" >/dev/null
        fi
        echo "$id" >> "$DEMO/ids"
        echo "$id"
    }
    local a b c d e
    a=$(wt "$p1" demo-web feature/login claude)
    b=$(wt "$p1" demo-web fix/flaky-tests claude)
    c=$(wt "$p1" demo-web docs/changelog claude)
    d=$(wt "$p1" demo-web chore/deps "")
    e=$(wt "$p2" demo-api feature/rate-limit claude)

    # A comparison: the same task given to two agents.
    local run; run=$(uuidgen)
    sqlite3 "$DB" "insert into run(id,projectID,task,createdAt) values
        (X'$(hex "$run")',X'$(hex "$p2")','Añade un endpoint /health que devuelva {\"ok\": true}',$now);"
    local r1 r2
    r1=$(wt "$p2" demo-api feature/health-claude claude "$run")
    r2=$(wt "$p2" demo-api feature/health-codex codex "$run")
    printf 'app.get("/health", (req, res) => res.json({ ok: true }))\n' > "$WT/demo-api/feature-health-claude/health.js"
    printf 'app.get("/health", (req, res) => {\n  res.status(200).send("ok")\n})\n// TODO tests\n' > "$WT/demo-api/feature-health-codex/health.js"
    git -C "$WT/demo-web/docs-changelog" push -q -u origin docs/changelog
    git -C "$WT/demo-web/docs-changelog" -c user.email=demo@example.com -c user.name=Demo commit -q --allow-empty -m wip

    # Some changes to review in feature/login: one commit plus uncommitted and untracked files.
    local L="$WT/demo-web/feature-login"
    printf 'export function login(user, password) {\n  if (!user) return null\n  return api.post("/login", { user, password })\n}\n' > "$L/login.js"
    git -C "$L" add login.js
    git -C "$L" -c user.email=demo@example.com -c user.name=Demo commit -q -m "Add login"
    printf 'export function login(user, password, remember = false) {\n  if (!user || !password) return null\n  return api.post("/login", { user, password, remember })\n}\n' > "$L/login.js"
    printf 'test("login without password fails", () => {\n  expect(login("ana")).toBeNull()\n})\n' > "$L/login.test.js"

    # fix/flaky-tests edits login.js too, differently: a merge conflict with feature/login.
    local F="$WT/demo-web/fix-flaky-tests"
    printf 'export function login() { return null }\n' > "$F/login.js"
    git -C "$F" add login.js
    git -C "$F" -c user.email=demo@example.com -c user.name=Demo commit -q -m "Stub login"

    sleep 1
    event "$a" UserPromptSubmit "" "Arregla el login: exige contraseña y añade la opción recordarme"
    event "$a" PreToolUse Read "login.js"
    event "$a" PreToolUse Edit "login.js"
    event "$a" PreToolUse Bash          # working
    event "$a" PreToolUse Bash "pnpm test login"
    event "$b" UserPromptSubmit         # thinking
    event "$c" Stop                     # done
    event "$e" PermissionRequest Write  # needs you
    event "$r1" Stop                    # done
    event "$r2" PreToolUse Edit         # still working
    echo "Demo ready: open the app (make run). Remove it with: Scripts/demo.sh stop"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    *) echo "usage: $0 start|stop"; exit 2 ;;
esac
