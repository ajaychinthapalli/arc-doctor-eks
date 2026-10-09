#!/usr/bin/env bash
# ARC watcher: detects scale sets whose runners aren't starting and asks the
# kagent "arc-doctor" agent (over A2A) to diagnose. Runs as a CronJob.
#
# Signals (per scale set):
#   - EphemeralRunner not Running/Succeeded for longer than PENDING_THRESHOLD_SECONDS
#   - EphemeralRunner in Failed phase
#   - Listener pod missing, not Ready past the threshold, or in CrashLoopBackOff
#
# A per-signal fingerprint + COOLDOWN_SECONDS stops repeat diagnoses of the same problem.
set -euo pipefail

A2A_URL="${A2A_URL:-http://kagent-controller.kagent.svc.cluster.local:8083/api/a2a/kagent/arc-doctor/}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-arc-systems}"
PENDING_THRESHOLD_SECONDS="${PENDING_THRESHOLD_SECONDS:-300}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-1800}"
STATE_CONFIGMAP="${STATE_CONFIGMAP:-arc-doctor-state}"
STATE_NAMESPACE="${STATE_NAMESPACE:-${POD_NAMESPACE:-arc-systems}}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
DRY_RUN="${DRY_RUN:-false}"
KUBECTL="${KUBECTL:-kubectl}"

log() { echo "[$(date -u +%FT%TZ)] $*" >&2; }

now=$(date +%s)

# ---------- 1. Collect signals ----------
ers_json=$($KUBECTL get ephemeralrunners.actions.github.com -A -o json)
ars_json=$($KUBECTL get autoscalingrunnersets.actions.github.com -A -o json)
listener_pods_json=$($KUBECTL get pods -n "$CONTROLLER_NAMESPACE" \
	-l app.kubernetes.io/component=runner-scale-set-listener -o json)

# Stuck or failed EphemeralRunners, grouped by scale set.
runner_findings=$(jq -c --argjson now "$now" --argjson t "$PENDING_THRESHOLD_SECONDS" '
  [ .items[]
    | . as $er
    | ($er.status.phase // "Pending") as $phase
    | ($now - ($er.metadata.creationTimestamp | fromdateiso8601)) as $age
    | select($phase == "Failed" or ($phase != "Running" and $phase != "Succeeded" and $age > $t))
    | { namespace: $er.metadata.namespace,
        scaleSet: ($er.metadata.labels["actions.github.com/scale-set-name"] // "unknown"),
        runner: $er.metadata.name,
        phase: $phase,
        reason: ($er.status.reason // ""),
        message: (($er.status.message // "") | .[0:300]),
        ageSeconds: $age } ]
  | group_by(.namespace + "/" + .scaleSet)
  | map({ key: (.[0].namespace + "/" + .[0].scaleSet),
          kind: "runners",
          namespace: .[0].namespace,
          scaleSet: .[0].scaleSet,
          count: length,
          phases: (map(.phase) | unique),
          reasons: (map(.reason) | map(select(. != "")) | unique),
          oldestAgeSeconds: (map(.ageSeconds) | max),
          samples: (.[0:3]) })
' <<<"$ers_json")

# Unhealthy listeners. Listener pods carry the scale set name/namespace labels.
listener_findings=$(jq -c --argjson now "$now" --argjson t "$PENDING_THRESHOLD_SECONDS" '
  [ .items[]
    | . as $p
    | ($now - ($p.metadata.creationTimestamp | fromdateiso8601)) as $age
    | ([$p.status.containerStatuses[]?.ready] | all) as $ready
    | ([$p.status.containerStatuses[]?.state.waiting.reason // empty]) as $waiting
    | ([$p.status.containerStatuses[]?.restartCount] | add // 0) as $restarts
    | select(($waiting | index("CrashLoopBackOff")) or ((($ready | not) or $p.status.phase != "Running") and $age > $t))
    | { key: (($p.metadata.labels["actions.github.com/scale-set-namespace"] // "?") + "/" +
              ($p.metadata.labels["actions.github.com/scale-set-name"] // $p.metadata.name)),
        kind: "listener",
        namespace: ($p.metadata.labels["actions.github.com/scale-set-namespace"] // "?"),
        scaleSet: ($p.metadata.labels["actions.github.com/scale-set-name"] // "unknown"),
        listenerPod: $p.metadata.name,
        phase: $p.status.phase,
        waiting: $waiting,
        restarts: $restarts } ]
' <<<"$listener_pods_json")

# Scale sets that have no listener pod at all (listener should always exist).
missing_listener_findings=$(jq -c -n \
	--argjson ars "$ars_json" --argjson pods "$listener_pods_json" '
  ($pods.items | map((.metadata.labels["actions.github.com/scale-set-namespace"] // "") + "/" +
                     (.metadata.labels["actions.github.com/scale-set-name"] // ""))) as $have
  | [ $ars.items[]
      | (.metadata.namespace + "/" + .metadata.name) as $k
      | select(($have | index($k)) | not)
      | { key: $k, kind: "listener-missing", namespace: .metadata.namespace, scaleSet: .metadata.name } ]
')

findings=$(jq -c -s 'add' <<<"$runner_findings $listener_findings $missing_listener_findings")
count=$(jq 'length' <<<"$findings")

if [[ "$count" -eq 0 ]]; then
	log "All ARC scale sets healthy."
	exit 0
fi
log "Detected $count finding(s): $(jq -c '[.[] | .key + ":" + .kind]' <<<"$findings")"

# ---------- 2. Cooldown / dedupe ----------
if [[ "$DRY_RUN" == "true" ]]; then
	state_json='{}'
else
	if ! $KUBECTL get configmap "$STATE_CONFIGMAP" -n "$STATE_NAMESPACE" >/dev/null 2>&1; then
		$KUBECTL create configmap "$STATE_CONFIGMAP" -n "$STATE_NAMESPACE" >/dev/null
	fi
	state_json=$($KUBECTL get configmap "$STATE_CONFIGMAP" -n "$STATE_NAMESPACE" -o json | jq -c '.data // {}')
fi

# Fingerprint = scale set + kind + sorted reasons/phases (so a new kind of failure re-triggers).
fresh=$(jq -c --argjson state "$state_json" --argjson now "$now" --argjson cd "$COOLDOWN_SECONDS" '
  map(. + { fp: ((.key + "|" + .kind + "|" + (((.reasons // []) + (.phases // []) + (.waiting // [])) | sort | join(",")))
                 | @base64 | gsub("[^A-Za-z0-9]"; "") | .[0:250]) })
  | map(select((($state[.fp] // "0") | tonumber) + $cd < $now))
' <<<"$findings")

fresh_count=$(jq 'length' <<<"$fresh")
if [[ "$fresh_count" -eq 0 ]]; then
	log "All findings are within cooldown; skipping diagnosis."
	exit 0
fi

# ---------- 3. Ask the agent ----------
prompt=$(jq -r --arg cns "$CONTROLLER_NAMESPACE" --argjson t "$PENDING_THRESHOLD_SECONDS" '
  "Automated alert from the ARC watcher.\n\n" +
  "GitHub Actions runners are not starting for the scale set(s) below. " +
  "ARC controller and listeners run in namespace \"" + $cns + "\". " +
  "Stuck threshold: " + ($t|tostring) + "s.\n\n" +
  "Findings (JSON):\n```json\n" + (map(del(.fp)) | tojson) + "\n```\n\n" +
  "Diagnose the root cause for each affected scale set and give the fix, using your standard response format."
' <<<"$fresh")

if [[ "$DRY_RUN" == "true" ]]; then
	log "DRY_RUN: would send prompt:"
	echo "$prompt"
	exit 0
fi

msg_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
payload=$(jq -n --arg text "$prompt" --arg id "$msg_id" '{
  jsonrpc: "2.0", id: $id, method: "message/send",
  params: { message: { role: "user", messageId: $id, kind: "message",
                       parts: [ { kind: "text", text: $text } ] } } }')

log "Sending diagnosis request to $A2A_URL"
response=$(curl -sS --fail-with-body --max-time 600 \
	-H 'Content-Type: application/json' -d "$payload" "$A2A_URL") || {
	log "A2A call failed: $response"
	exit 1
}

# The final answer may come back as artifacts, a status message, or a direct message.
answer=$(jq -r '
  def texts: [ .[]?.parts[]? | select(.kind == "text") | .text ];
  if .error then "A2A error: " + (.error | tojson)
  else
    ( (.result.artifacts | texts) as $a
    | ([.result.status.message] | texts) as $s
    | ([.result | select(.kind == "message")] | texts) as $m
    | if ($a|length) > 0 then $a
      elif ($s|length) > 0 then $s
      elif ($m|length) > 0 then $m
      else [ (.result.history // []) | map(select(.role == "agent")) | last | [.] | texts[] ]
      end
    | join("\n") )
  end' <<<"$response")

[[ -z "$answer" ]] && answer="(agent returned no text; raw response logged)" && log "$response"

echo "===== ARC Doctor diagnosis ====="
echo "$answer"
echo "================================"

# ---------- 4. Notify ----------
if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
	title=":rotating_light: ARC runners not starting: $(jq -r '[.[].key] | unique | join(", ")' <<<"$fresh")"
	# Markdown -> Slack mrkdwn: **bold** -> *bold*, "## Heading" -> *Heading*, drop --- rules
	slack_text=$(printf '%s\n' "$answer" | sed -E \
		-e 's/\*\*([^*]+)\*\*/*\1*/g' \
		-e 's/^#{1,6}[[:space:]]+(.*)$/*\1*/' \
		-e '/^-{3,}[[:space:]]*$/d')
	slack=$(jq -n --arg title "$title" --arg body "${slack_text:0:2900}" '{
    text: $title,
    blocks: [ { type: "section", text: { type: "mrkdwn", text: ("*" + $title + "*") } },
              { type: "section", text: { type: "mrkdwn", text: $body } } ] }')
	curl -sS --max-time 20 -H 'Content-Type: application/json' -d "$slack" "$SLACK_WEBHOOK_URL" >/dev/null ||
		log "Slack notification failed"
fi

# ---------- 5. Record cooldown ----------
patch=$(jq -c --arg now "$now" '{data: (map({(.fp): $now}) | add)}' <<<"$fresh")
$KUBECTL patch configmap "$STATE_CONFIGMAP" -n "$STATE_NAMESPACE" --type merge -p "$patch" >/dev/null
log "Diagnosis complete for $fresh_count finding(s)."
