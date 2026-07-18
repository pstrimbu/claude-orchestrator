#!/usr/bin/env bash
# ~/.claude/hooks/aws-guardrail.sh
#
# PreToolUse guardrail for Bash commands. Configured in ~/.claude/settings.json
# (USER scope) so it runs on EVERY Bash tool call in EVERY project for this user.
#
# Why this exists: orch sessions launch `claude --dangerously-skip-permissions`,
# which can reach live cloud credentials. PreToolUse hooks still fire and can
# hard-block even in bypassPermissions mode, so this is the one safety net that
# survives skip-permissions.
#
# Tiers:
#   DENY -> hard block, cannot proceed (catastrophic / never-legitimate)
#   ASK  -> pause and require a human to confirm (destructive but sometimes valid)
#   else -> stay silent; normal flow / permission system applies
#
# Emits exit 0 + JSON (permissionDecision). Appends every deny/ask to guardrail.log.
# Note: AWS CliDangerZoneDeny IAM policy is the other layer — this is defense in depth.

set -uo pipefail

LOG="$HOME/.claude/hooks/guardrail.log"
input="$(cat)"

# Pull the command string. If we can't parse it, do NOT block normal flow.
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

emit() {  # $1=decision(deny|ask)  $2=reason
  jq -n --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$cmd" >> "$LOG" 2>/dev/null || true
}

m() { printf '%s' "$cmd" | grep -Eiq -- "$1"; }   # case-insensitive match helper

# Word-boundary-safe: a token preceded by start or a non-word char (avoids
# matching "rm" inside "perform"/"platform", "dd" inside "add", etc.)
WB='(^|[^[:alnum:]_])'
# Trailing counterpart. Without this, "stop" matches inside "stopped", "delete"
# inside "deleted", etc. — flagging read-only commands like `grep stopped`.
WE='([^[:alnum:]_]|$)'

# Your production identifiers — hosts, IPs, DB endpoints, instance IDs that a
# mutating command should never touch without a human confirming. Supply them
# yourself; nothing is baked in. Either:
#   ORCH_PROD_IDENTIFIERS      — regex alternation, e.g. '10\.0\.0\.1|db\.example\.com'
#   ORCH_PROD_IDENTIFIERS_FILE — file of one identifier per line ('#' comments ok)
#                                (default: ~/.config/orch/prod-identifiers.txt)
# If neither is provided, the prod-host rule below is skipped; every other rule
# still applies.
PROD="${ORCH_PROD_IDENTIFIERS:-}"
PROD_FILE="${ORCH_PROD_IDENTIFIERS_FILE:-$HOME/.config/orch/prod-identifiers.txt}"
if [ -z "$PROD" ] && [ -f "$PROD_FILE" ]; then
  PROD="$(grep -vE '^[[:space:]]*(#|$)' "$PROD_FILE" 2>/dev/null | paste -sd'|' -)"
fi
# Destructive FORMS used to gate prod-host confirmation.
#
# This matches destructive *syntax*, not bare verbs. The previous version matched
# any of rm|drop|delete|truncate|stop|restart|reboot|kill|shutdown as a standalone
# word, which buried real warnings in routine noise:
#   - `docker restart <svc>` on prod is normal ops, recoverable in seconds — it
#     alone was 36% of all confirmations. Same for stop/kill/reboot. Removed.
#   - drop/delete/kill appearing inside a quoted Python snippet, a SQL SELECT, or
#     a git commit message ("Media tab polish: drop ...") all fired.
#   - bare `rm` also matched the `--rm` flag in `docker run --rm`.
#
# What remains is irreversible data/resource loss. Measured against 2355 real
# Bash calls: confirmations 80 -> 47, with DROP DATABASE / DROP USER / DELETE
# FROM / delete-secret / route53 DELETE / docker rm -f / rsync --delete all
# still caught.
MUTATE="${WB}drop[[:space:]]+(table|database|schema|user|role|index)${WE}"
MUTATE="$MUTATE|${WB}truncate[[:space:]]+table${WE}"
MUTATE="$MUTATE|${WB}delete[[:space:]]+from${WE}"
# AWS-CLI-style destructive verbs: delete-secret, terminate-instances, ...
MUTATE="$MUTATE|${WB}(delete|terminate|destroy|purge)-[[:alnum:]-]+"
# route53 / JSON change batches
MUTATE="$MUTATE|\"Action\"[[:space:]]*:[[:space:]]*\"DELETE\""
# rsync mirror-delete can wipe files on the target
MUTATE="$MUTATE|--delete${WE}"
# filesystem removal — leading class excludes the `--rm` docker flag
MUTATE="$MUTATE|(^|[^-[:alnum:]_])rm${WE}"
MUTATE="$MUTATE|${WB}(mkfs|dd|shutdown)${WE}"
# redirects only count when aimed at system dirs (`> /tmp/out` is not a prod mutation)
MUTATE="$MUTATE|>[[:space:]]*/(etc|usr|bin|sbin|boot|opt)/"

# ======================= DENY tier =======================

m '[-][-]no-preserve-root' && { emit deny "Blocked: 'rm --no-preserve-root' can wipe the whole filesystem."; exit 0; }

# fork bomb  :(){ :|:& };:
printf '%s' "$cmd" | grep -Eq -- ':[[:space:]]*\([[:space:]]*\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|' \
  && { emit deny "Blocked: fork bomb pattern."; exit 0; }

# recursive rm targeting a filesystem / home root.
# The path must BE a root — not merely start with one. The old trailing class
# allowed '/', so '/Users/<any>/deep/path' matched and every recursive delete
# under $HOME was hard-blocked. '/Users/<name>' (a home root) still is.
if m "${WB}rm[[:space:]]+([^;&|]*[[:space:]])?-[[:alnum:]]*r" \
   && m '(^|[[:space:]])(/|/\*|~|\$HOME|/Users|/Users/[^/[:space:]]+|/System|/Library|/etc|/bin|/usr|/Applications)/?([[:space:]]|$)'; then
  emit deny "Blocked: recursive delete targeting a filesystem/home root path."; exit 0
fi

# raw disk write / format. Each arm must name an actual device: the bare-`mkfs`
# arm hard-blocked any command that merely CONTAINED the string (a read-only
# Python script whose regex listed it was denied), and a hard deny with no way
# to proceed is the worst failure mode for a false positive.
m "(${WB}mkfs[[:alnum:].]*[[:space:]][^;&|]*/dev/|${WB}dd[[:space:]]+.*of=/dev/|>[[:space:]]*/dev/(disk|sd|nvme|rdisk))" \
  && { emit deny "Blocked: write/format of a raw disk device."; exit 0; }

# AWS security-control tampering
m 'aws[[:space:]]+(cloudtrail[[:space:]]+(delete-trail|stop-logging|update-trail)|guardduty[[:space:]]+(delete-detector|stop-monitoring|disassociate-from-master)|config[[:space:]]+(delete-|stop-configuration-recorder)|securityhub[[:space:]]+disable|kms[[:space:]]+schedule-key-deletion)' \
  && { emit deny "Blocked: tampering with AWS security controls (CloudTrail/GuardDuty/Config/SecurityHub/KMS)."; exit 0; }

# recursive chmod 777 on a root path
m 'chmod[[:space:]]+-[[:alnum:]]*R[[:alnum:]]*[[:space:]]+0*777[[:space:]]+/' \
  && { emit deny "Blocked: recursive chmod 777 on a root path."; exit 0; }

# ======================= ASK tier =======================

# Destructive AWS verbs (read verbs describe/list/get are untouched).
m 'aws[[:space:]]+[[:alnum:]-]+[[:space:]]+(delete|terminate|remove|deregister|revoke|purge|reset|disable|release|cancel|destroy|detach|disassociate|stop-)[[:alnum:]-]*' \
  && { emit ask "Confirm: destructive AWS command (delete/terminate/etc.)."; exit 0; }

# S3 bucket / object removal
m 'aws[[:space:]]+s3[[:space:]]+(rb|rm)([[:space:]]|$)' \
  && { emit ask "Confirm: S3 bucket/object removal."; exit 0; }

# NOTE: no blanket ask on recursive 'rm' — it fired on every node_modules/.orch
# cleanup and stalled unattended orch loops. Root-targeting deletes are still
# hard-denied above, and a recursive rm aimed at a PROD host still hits the
# shared-infra rule below.

# infrastructure teardown
m '(terraform[[:space:]]+destroy|cdk[[:space:]]+destroy|pulumi[[:space:]]+destroy|cloudformation[[:space:]]+delete-stack|serverless[[:space:]]+remove)' \
  && { emit ask "Confirm: infrastructure teardown."; exit 0; }

# destructive SQL
m '(drop[[:space:]]+(table|database|schema)|truncate[[:space:]]+table)' \
  && { emit ask "Confirm: destructive SQL (DROP/TRUNCATE)."; exit 0; }

# container / volume / k8s removal
m '(docker[[:space:]]+system[[:space:]]+prune|docker[[:space:]]+volume[[:space:]]+rm|docker[[:space:]].*[[:space:]]down[[:space:]].*-[[:alnum:]]*v|kubectl[[:space:]]+delete)' \
  && { emit ask "Confirm: container/volume/k8s resource removal."; exit 0; }

# destructive git
m "(git[[:space:]]+push[[:space:]]+.*(--force|${WB}-[[:alnum:]]*f)|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-[[:alnum:]]*f|git[[:space:]]+branch[[:space:]]+-D)" \
  && { emit ask "Confirm: destructive git op (force-push / hard reset / clean -f / branch -D)."; exit 0; }

# a mutating command aimed at shared PROD infra (only when identifiers configured)
if [ -n "$PROD" ] && m "($PROD)" && m "$MUTATE"; then
  emit ask "Confirm: mutating command targeting shared PROD infrastructure."; exit 0
fi

exit 0
