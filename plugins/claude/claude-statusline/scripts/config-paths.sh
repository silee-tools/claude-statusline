# 설정 경로는 심볼릭 링크를 따라가지 않고 현재 디렉터리 기준으로 정규화한다.
config_path() {
  case "$1" in /*) path=$1 ;; *) path="$PWD/$1" ;; esac
  printf '%s\n' "$path" | awk -F/ '{
    n=0; for(i=1;i<=NF;i++) {
      if($i=="" || $i==".") continue
      if($i=="..") { if(n>0) n--; continue }
      parts[++n]=$i
    }
    out=""; for(i=1;i<=n;i++) out=out "/" parts[i]
    print (out=="" ? "/" : out)
  }'
}
# hook-handler.sh reads this after sourcing.
# shellcheck disable=SC2034
CLAUDE_SETTINGS_DIR=$(config_path "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
