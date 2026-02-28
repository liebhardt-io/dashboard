#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
BADGE_DIR="${DIST_DIR}/badges"

mkdir -p "${BADGE_DIR}"

# ── App registry ──────────────────────────────────────────────────────────────
# Format: name|repo|domain|workflow_file
APPS=(
  "podpally-app|liebhardt-io/podpally-app|app.podpally.com|deploy.yml"
  "podpally-landingpage|liebhardt-io/podpally-landingpage|podpally.com|deploy.yml"
  "webtracker-app|liebhardt-io/webtracker-app|app.webtracker.ai|deploy.yml"
  "webtracker-landingpage|liebhardt-io/webtracker-landingpage|webtracker.ai|deploy.yml"
  "hiretool-app|liebhardt-io/hiretool-app|hiretool.io|deploy.yml"
  "audio-docs-app|liebhardt-io/audio-docs-app|audio-docs.com|deploy.yml"
  "ecomdesignlab-app|liebhardt-io/ecomdesignlab-app|app.ecomdesignlab.ai|deploy.yml"
  "ecomdesignlab-landingpage|liebhardt-io/ecomdesignlab-landingpage|www.ecomdesignlab.ai|deploy.yml"
  "soloagents-landingpage|liebhardt-io/soloagents-landingpage|soloagents.ai|deploy.yml"
)

TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M UTC")
APP_CARDS=""
SUMMARY_LINES=""

for entry in "${APPS[@]}"; do
  IFS='|' read -r name repo domain workflow <<< "${entry}"

  echo "Fetching status for ${name} (${repo})..."

  # Fetch latest workflow run
  RUN_JSON=$(gh api "repos/${repo}/actions/workflows/${workflow}/runs?per_page=1&branch=main" \
    --jq '.workflow_runs[0] // empty' 2>/dev/null || echo "")

  if [ -n "${RUN_JSON}" ]; then
    STATUS=$(echo "${RUN_JSON}" | jq -r '.conclusion // .status')
    SHA=$(echo "${RUN_JSON}" | jq -r '.head_sha[:7]')
    UPDATED=$(echo "${RUN_JSON}" | jq -r '.updated_at')
    RUN_URL=$(echo "${RUN_JSON}" | jq -r '.html_url')
    ACTOR=$(echo "${RUN_JSON}" | jq -r '.actor.login // "unknown"')

    # Map status to display values
    case "${STATUS}" in
      success)
        STATUS_CLASS="status-success"
        STATUS_TEXT="Deployed"
        BADGE_COLOR="#4c1"
        ;;
      failure)
        STATUS_CLASS="status-failure"
        STATUS_TEXT="Failed"
        BADGE_COLOR="#e05d44"
        ;;
      in_progress|queued|waiting)
        STATUS_CLASS="status-pending"
        STATUS_TEXT="In Progress"
        BADGE_COLOR="#dfb317"
        ;;
      *)
        STATUS_CLASS="status-unknown"
        STATUS_TEXT="${STATUS}"
        BADGE_COLOR="#9f9f9f"
        ;;
    esac

    # Format time for display
    DISPLAY_TIME="${UPDATED}"
  else
    STATUS_CLASS="status-unknown"
    STATUS_TEXT="No data"
    SHA="—"
    DISPLAY_TIME="—"
    RUN_URL="#"
    ACTOR="—"
    BADGE_COLOR="#9f9f9f"
  fi

  # ── Generate app card HTML ──
  APP_CARDS+="    <div class=\"card\">
      <div class=\"card-header\">
        <h2>${name}</h2>
        <span class=\"status-dot ${STATUS_CLASS}\" title=\"${STATUS_TEXT}\"></span>
      </div>
      <dl class=\"card-body\">
        <dt>Domain</dt>
        <dd><a href=\"https://${domain}\" target=\"_blank\">${domain}</a></dd>
        <dt>Status</dt>
        <dd><a href=\"${RUN_URL}\" target=\"_blank\">${STATUS_TEXT}</a></dd>
        <dt>Commit</dt>
        <dd><code>${SHA}</code></dd>
        <dt>Last deploy</dt>
        <dd>${DISPLAY_TIME}</dd>
      </dl>
    </div>
"

  # ── Generate badge SVG ──
  LABEL="${name}"
  VALUE="${STATUS_TEXT}"
  LABEL_LEN=${#LABEL}
  VALUE_LEN=${#VALUE}
  LABEL_WIDTH=$(( LABEL_LEN * 7 + 10 ))
  VALUE_WIDTH=$(( VALUE_LEN * 7 + 10 ))
  TOTAL_WIDTH=$(( LABEL_WIDTH + VALUE_WIDTH ))
  LABEL_X=$(( LABEL_WIDTH / 2 ))
  VALUE_X=$(( LABEL_WIDTH + VALUE_WIDTH / 2 ))

  sed -e "s|%%WIDTH%%|${TOTAL_WIDTH}|g" \
      -e "s|%%LABEL_WIDTH%%|${LABEL_WIDTH}|g" \
      -e "s|%%VALUE_WIDTH%%|${VALUE_WIDTH}|g" \
      -e "s|%%COLOR%%|${BADGE_COLOR}|g" \
      -e "s|%%LABEL_X%%|${LABEL_X}|g" \
      -e "s|%%VALUE_X%%|${VALUE_X}|g" \
      -e "s|%%LABEL%%|${LABEL}|g" \
      -e "s|%%VALUE%%|${VALUE}|g" \
      "${SCRIPT_DIR}/badge-template.svg" > "${BADGE_DIR}/${name}.svg"

  # Build summary for Discord
  if [ "${STATUS_TEXT}" = "Deployed" ]; then
    SUMMARY_LINES+=":white_check_mark: **${name}** — ${domain}\\n"
  elif [ "${STATUS_TEXT}" = "Failed" ]; then
    SUMMARY_LINES+=":x: **${name}** — ${domain}\\n"
  else
    SUMMARY_LINES+=":yellow_circle: **${name}** — ${domain} (${STATUS_TEXT})\\n"
  fi
done

# ── Generate index.html from template ──
sed -e "s|%%TIMESTAMP%%|${TIMESTAMP}|g" \
    -e "s|%%APP_CARDS%%|${APP_CARDS}|g" \
    "${SCRIPT_DIR}/template.html" > "${DIST_DIR}/index.html"

echo "Dashboard generated at ${DIST_DIR}/index.html"
echo "Badges generated at ${BADGE_DIR}/"

# ── Post daily summary to Discord (if DISCORD_WEBHOOK and DAILY_SUMMARY are set) ──
if [ "${DAILY_SUMMARY:-}" = "true" ] && [ -n "${DISCORD_WEBHOOK:-}" ]; then
  echo "Posting daily summary to Discord..."
  curl -s -o /dev/null -X POST "${DISCORD_WEBHOOK}" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "embeds": [{
    "title": ":bar_chart: Daily Deployment Summary",
    "description": "${SUMMARY_LINES}",
    "color": 5793266,
    "fields": [
      { "name": "Dashboard", "value": "[View Dashboard](https://liebhardt-io.github.io/infra/)", "inline": true },
      { "name": "Uptime", "value": "[Status Page](https://status.liebhardt.io)", "inline": true }
    ],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
  echo "Daily summary posted."
fi
