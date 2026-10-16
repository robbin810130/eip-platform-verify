#!/usr/bin/env bash
# 验证镜像入口（仅本地 / CI 使用）。
#
# 用法：
#   docker run --rm --network=none eip-platform-verify:<tag>
#       → 无参数，执行仓库自带的离线校验入口 scripts/check.sh
#   docker run --rm --network=none eip-platform-verify:<tag> <cmd> [args...]
#       → 有参数，直接执行给定命令（覆盖默认入口），例如：
#         ... bash
#         ... scripts/cargo.sh run --locked -p eip-cli -- inspect fixtures/demo/bundle.json
#         ... npm --prefix apps/web-console run typecheck
#
# 该脚本不做任何网络访问、不读取任何凭据、不连接数据库。
set -euo pipefail

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

check_sh="/workspace/scripts/check.sh"
if [ ! -f "$check_sh" ]; then
  echo "entrypoint: $check_sh not found; is the build context the repository root?" >&2
  exit 127
fi

if [ ! -x "$check_sh" ]; then
  echo "entrypoint: $check_sh is not executable; run: chmod +x scripts/*.sh" >&2
  exit 126
fi

printf 'entrypoint: running %s (offline verify suite)\n' "$check_sh" >&2
exec "$check_sh"
