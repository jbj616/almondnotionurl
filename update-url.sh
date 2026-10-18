#!/bin/bash
# update-url.sh — 현재 cloudflared quick-tunnel URL을 README.md에 반영하고
# 변경 시에만 commit+push. crontab에서 2분 간격으로 실행.
#   */2 * * * * flock -n /tmp/almondnotionurl.lock /home/almond/Desktop/code/almondnotionurl/update-url.sh >> /tmp/almondnotionurl.log 2>&1
set -u
export PATH="/usr/bin:/bin"
# cron(비세션) 환경에서 gh credential helper(keyring)가 세션 버스를 찾도록 보정
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
METRICS_URL="${METRICS_URL:-http://127.0.0.1:20241/metrics}"
ORIGIN_SIGNIN="http://127.0.0.1:8080/signin/"
README="$REPO_DIR/README.md"

log() { echo "[$(TZ=Asia/Seoul date '+%F %T %Z')] $*"; }

# 1. 현재 tunnel hostname (cloudflared metrics)
HOST_URL="$(curl -s --max-time 5 "$METRICS_URL" 2>/dev/null \
  | grep -o 'userHostname="https://[^"]*"' \
  | head -1 | cut -d'"' -f2)"
if [ -z "$HOST_URL" ]; then
  log "SKIP: metrics에서 hostname 없음 ($METRICS_URL)"
  exit 1
fi

# 2. origin 살아있는지 확인 (죽었으면 갱신 안 함)
ORIGIN_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$ORIGIN_SIGNIN" 2>/dev/null)"
[ -z "$ORIGIN_CODE" ] && ORIGIN_CODE="000"
if [ "$ORIGIN_CODE" != "200" ]; then
  log "SKIP: origin :8080 응답 이상 (HTTP $ORIGIN_CODE)"
  exit 1
fi

# 3. 공개 URL 실측 (참고용으로 기록, 실패해도 갱신은 진행)
PUBLIC_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$HOST_URL/signin/" 2>/dev/null)"
[ -z "$PUBLIC_CODE" ] && PUBLIC_CODE="000"
if [ "$PUBLIC_CODE" = "200" ]; then
  PUBLIC_STATUS="정상"
else
  PUBLIC_STATUS="비정상 (HTTP $PUBLIC_CODE — 확인 필요)"
fi

NOW="$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M %Z')"
cd "$REPO_DIR" || exit 1

# 원격 최신화. 사람이 README를 직접 편집해 diverge된 경우 rebase로 처리
# (-X theirs: 로컬(bot) README가 이김). cron에서 실행되므로 반드시 cd 후 git 실행.
if ! git pull --ff-only -q 2>/dev/null; then
  git pull --rebase -X theirs origin main 2>/dev/null || true
fi

# 4. URL·상태가 기존 README와 같으면 갱신하지 않음
# (push 실패로 밀린 커밋은 아래에서 URL과 무관하게 push 재시도됨)
NEED_UPDATE=1
if [ -f "$README" ]; then
  OLD_URL="$(grep -m1 '^\- \*\*현재 접속 URL\*\*:' "$README" 2>/dev/null | sed 's/^.*: //')"
  OLD_STATUS="$(grep -m1 '^\- 상태:' "$README" 2>/dev/null | sed 's/^\- 상태: //')"
  if [ "$OLD_URL" = "$HOST_URL" ] && [ "$OLD_STATUS" = "$PUBLIC_STATUS" ]; then
    NEED_UPDATE=0
  fi
fi

if [ "$NEED_UPDATE" -eq 1 ]; then
  cat > README.md <<EOF
# almondnotion 접속 URL

> 자동 업데이트: 이 파일은 almondnotion 서버의 \`update-url.sh\`
> (2분 간격 cron)가 현재 cloudflare quick-tunnel URL로 갱신합니다.
> 사람이 직접 편집하지 마세요 — 다음 실행 때 덮어씁니다.

- **현재 접속 URL**: $HOST_URL
- **로그인**: $HOST_URL/signin/
- 상태: $PUBLIC_STATUS
- 마지막 확인: $NOW

## 참고

- quick tunnel은 cloudflared 재시작마다 URL이 바뀝니다 (uptime 보장 없음).
  북마크가 안 되면 이 파일을 다시 확인하세요.
- 서버 로컬에서는 항상 \`http://localhost:8080/signin/\` 으로 접속됩니다.
- \`/\` 루트는 GUI가 아니라 \`OK\` 헬스 응답이 정상입니다.
EOF
  git add README.md
  if ! git diff --cached --quiet; then
    git commit -qm "url: $HOST_URL ($NOW)" || exit 1
  fi
fi

# push 실패로 밀린 커밋 재시도 (URL이 바뀌지 않아도 계속)
if [ -n "$(git rev-list origin/main..HEAD 2>/dev/null)" ]; then
  if git push -q origin main 2>&1; then
    log "PUSH: $HOST_URL (public $PUBLIC_CODE)"
  else
    log "FAIL: push 실패 ($HOST_URL)"
    exit 1
  fi
fi
exit 0
