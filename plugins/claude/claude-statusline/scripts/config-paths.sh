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
CLAUDE_SETTINGS_DIR=$(config_path "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
SHARED_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
account_cache_dir() {
  if [ "$CLAUDE_SETTINGS_DIR" = "$(config_path "$HOME/.claude")" ]; then
    printf '%s\n' "$SHARED_CACHE_DIR"
    return
  fi
  hash=""
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$CLAUDE_SETTINGS_DIR" | sha256sum) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$CLAUDE_SETTINGS_DIR" | shasum -a 256) || return 1
  else
    return 1
  fi
  hash=${hash%% *}
  case "$hash" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#hash}" -eq 64 ] || return 1
  printf '%s/accounts/%s\n' "$SHARED_CACHE_DIR" "$hash"
}
