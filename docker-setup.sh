#!/usr/bin/env bash
# OpenClaw Docker 环境设置脚本
# 此脚本用于配置、构建和启动 OpenClaw 的 Docker 容器环境

# 设置严格的错误处理模式：
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道命令中任何一个失败都会导致整个管道失败
set -euo pipefail

# ============================================================================
# 基本路径和配置变量初始化
# ============================================================================

# 获取脚本所在目录的绝对路径，作为项目根目录
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 主 Docker Compose 配置文件路径
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

# 额外的 Docker Compose 配置文件路径（用于自定义挂载）
EXTRA_COMPOSE_FILE="$ROOT_DIR/docker-compose.extra.yml"

# Docker 镜像名称，可通过环境变量 OPENCLAW_IMAGE 覆盖，默认为 openclaw:local
IMAGE_NAME="${OPENCLAW_IMAGE:-openclaw:local}"

# 额外的挂载点配置，格式：source:target[:options]，多个挂载用逗号分隔
EXTRA_MOUNTS="${OPENCLAW_EXTRA_MOUNTS:-}"

# 自定义 home 卷名称，可以是命名卷或主机路径
HOME_VOLUME_NAME="${OPENCLAW_HOME_VOLUME:-}"

# ============================================================================
# 工具函数定义
# ============================================================================

# 错误处理函数：打印错误信息并退出脚本
# 参数：错误消息
fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# 检查命令是否存在的函数
# 参数：命令名称
# 如果命令不存在，打印错误信息并退出
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    exit 1
  fi
}

# 检查字符串是否包含不允许的控制字符（换行符、回车符、制表符）
# 参数：要检查的字符串值
# 返回：如果包含控制字符返回 true，否则返回 false
contains_disallowed_chars() {
  local value="$1"
  [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]]
}

# 验证挂载路径值的有效性
# 参数：
#   $1 - 字段标签（用于错误消息）
#   $2 - 要验证的值
# 检查项：
#   - 值不能为空
#   - 不能包含控制字符
#   - 不能包含空白字符
validate_mount_path_value() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    fail "$label cannot be empty."
  fi
  if contains_disallowed_chars "$value"; then
    fail "$label contains unsupported control characters."
  fi
  if [[ "$value" =~ [[:space:]] ]]; then
    fail "$label cannot contain whitespace."
  fi
}

# 验证命名卷的名称格式
# 参数：卷名称
# 要求：必须以字母或数字开头，后续字符可以是字母、数字、下划线、点或连字符
validate_named_volume() {
  local value="$1"
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    fail "OPENCLAW_HOME_VOLUME must match [A-Za-z0-9][A-Za-z0-9_.-]* when using a named volume."
  fi
}

# 验证挂载规格的格式
# 参数：挂载规格字符串
# 预期格式：source:target[:options]
# 检查项：
#   - 不能包含控制字符
#   - 必须符合 source:target[:options] 格式，不能有空格
#   - 这是为了防止 YAML 结构注入攻击
validate_mount_spec() {
  local mount="$1"
  if contains_disallowed_chars "$mount"; then
    fail "OPENCLAW_EXTRA_MOUNTS entries cannot contain control characters."
  fi
  # 保持挂载规格严格，避免 YAML 结构注入
  # 预期格式：source:target[:options]
  if [[ ! "$mount" =~ ^[^[:space:],:]+:[^[:space:],:]+(:[^[:space:],:]+)?$ ]]; then
    fail "Invalid mount format '$mount'. Expected source:target[:options] without spaces."
  fi
}

# ============================================================================
# 依赖检查
# ============================================================================

# 检查 Docker 是否已安装
require_cmd docker

# 检查 Docker Compose 是否可用（使用新版本的 'docker compose' 命令）
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose not available (try: docker compose version)" >&2
  exit 1
fi

# ============================================================================
# 配置目录设置
# ============================================================================

# OpenClaw 配置目录，默认为用户主目录下的 .openclaw
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"

# OpenClaw 工作空间目录，默认为配置目录下的 workspace
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"

# ============================================================================
# 配置验证
# ============================================================================

# 验证配置目录路径的有效性
validate_mount_path_value "OPENCLAW_CONFIG_DIR" "$OPENCLAW_CONFIG_DIR"

# 验证工作空间目录路径的有效性
validate_mount_path_value "OPENCLAW_WORKSPACE_DIR" "$OPENCLAW_WORKSPACE_DIR"

# 如果指定了自定义 home 卷，进行验证
if [[ -n "$HOME_VOLUME_NAME" ]]; then
  # 如果包含斜杠，说明是主机路径，验证路径格式
  if [[ "$HOME_VOLUME_NAME" == *"/"* ]]; then
    validate_mount_path_value "OPENCLAW_HOME_VOLUME" "$HOME_VOLUME_NAME"
  else
    # 否则是命名卷，验证卷名称格式
    validate_named_volume "$HOME_VOLUME_NAME"
  fi
fi

# 验证额外挂载配置不包含控制字符
if contains_disallowed_chars "$EXTRA_MOUNTS"; then
  fail "OPENCLAW_EXTRA_MOUNTS cannot contain control characters."
fi

# ============================================================================
# 创建必要的目录结构
# ============================================================================

# 创建配置目录（如果不存在）
mkdir -p "$OPENCLAW_CONFIG_DIR"

# 创建工作空间目录（如果不存在）
mkdir -p "$OPENCLAW_WORKSPACE_DIR"

# 提前创建设备身份标识的父目录
# 这是为了解决 Docker Desktop/Windows 绑定挂载的问题，
# 这些环境下从容器内部无法创建新的子目录
mkdir -p "$OPENCLAW_CONFIG_DIR/identity"

# ============================================================================
# 导出环境变量供 Docker Compose 使用
# ============================================================================

# 配置目录路径
export OPENCLAW_CONFIG_DIR

# 工作空间目录路径
export OPENCLAW_WORKSPACE_DIR

# Gateway 服务端口，默认 18789
export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

# Bridge 服务端口，默认 18790
export OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"

# Gateway 绑定模式，默认 'lan' (局域网模式)
export OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"

# Docker 镜像名称
export OPENCLAW_IMAGE="$IMAGE_NAME"

# 容器内额外安装的 APT 包列表
export OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-}"

# 额外的挂载配置
export OPENCLAW_EXTRA_MOUNTS="$EXTRA_MOUNTS"

# 自定义 home 卷
export OPENCLAW_HOME_VOLUME="$HOME_VOLUME_NAME"

# ============================================================================
# 生成 Gateway 访问令牌
# ============================================================================

# 如果未设置 OPENCLAW_GATEWAY_TOKEN，自动生成一个安全的随机令牌
if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  # 优先使用 openssl 生成 64 字符的十六进制令牌
  if command -v openssl >/dev/null 2>&1; then
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    # 如果没有 openssl，使用 Python 生成令牌
    OPENCLAW_GATEWAY_TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
  fi
fi
export OPENCLAW_GATEWAY_TOKEN

# ============================================================================
# Docker Compose 文件配置
# ============================================================================

# 初始化 Compose 文件数组，包含主配置文件
COMPOSE_FILES=("$COMPOSE_FILE")

# 初始化 Compose 命令参数数组
COMPOSE_ARGS=()

# ============================================================================
# 动态生成额外的 Compose 配置文件
# ============================================================================

# 函数：根据挂载配置生成额外的 Docker Compose 配置文件
# 参数：
#   $1 - home 卷名称或路径
#   $@ - 额外的挂载规格列表
write_extra_compose() {
  local home_volume="$1"
  shift
  local mount
  local gateway_home_mount
  local gateway_config_mount
  local gateway_workspace_mount

  # 写入 YAML 文件头部，定义 openclaw-gateway 服务的 volumes 部分
  cat >"$EXTRA_COMPOSE_FILE" <<'YAML'
services:
  openclaw-gateway:
    volumes:
YAML

  # 如果指定了 home 卷，添加三个挂载点：home、config、workspace
  if [[ -n "$home_volume" ]]; then
    gateway_home_mount="${home_volume}:/home/node"
    gateway_config_mount="${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw"
    gateway_workspace_mount="${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace"
    
    # 验证每个挂载规格的格式
    validate_mount_spec "$gateway_home_mount"
    validate_mount_spec "$gateway_config_mount"
    validate_mount_spec "$gateway_workspace_mount"
    
    # 将挂载配置写入文件
    printf '      - %s\n' "$gateway_home_mount" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s\n' "$gateway_config_mount" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s\n' "$gateway_workspace_mount" >>"$EXTRA_COMPOSE_FILE"
  fi

  # 添加用户指定的额外挂载点到 gateway 服务
  for mount in "$@"; do
    validate_mount_spec "$mount"
    printf '      - %s\n' "$mount" >>"$EXTRA_COMPOSE_FILE"
  done

  # 写入 openclaw-cli 服务的 volumes 部分
  cat >>"$EXTRA_COMPOSE_FILE" <<'YAML'
  openclaw-cli:
    volumes:
YAML

  # 为 CLI 服务添加相同的 home 卷挂载
  if [[ -n "$home_volume" ]]; then
    printf '      - %s\n' "$gateway_home_mount" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s\n' "$gateway_config_mount" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s\n' "$gateway_workspace_mount" >>"$EXTRA_COMPOSE_FILE"
  fi

  # 为 CLI 服务添加额外的挂载点
  for mount in "$@"; do
    validate_mount_spec "$mount"
    printf '      - %s\n' "$mount" >>"$EXTRA_COMPOSE_FILE"
  done

  # 如果使用命名卷（不包含斜杠），需要在 volumes 顶级键中声明
  if [[ -n "$home_volume" && "$home_volume" != *"/"* ]]; then
    validate_named_volume "$home_volume"
    cat >>"$EXTRA_COMPOSE_FILE" <<YAML
volumes:
  ${home_volume}:
YAML
  fi
}

# ============================================================================
# 解析和验证额外挂载配置
# ============================================================================

# 存储验证通过的挂载规格
VALID_MOUNTS=()

# 如果设置了额外挂载，解析逗号分隔的挂载列表
if [[ -n "$EXTRA_MOUNTS" ]]; then
  # 使用 IFS（内部字段分隔符）按逗号分割字符串
  IFS=',' read -r -a mounts <<<"$EXTRA_MOUNTS"
  
  # 遍历每个挂载规格
  for mount in "${mounts[@]}"; do
    # 去除首尾空白字符
    mount="${mount#"${mount%%[![:space:]]*}"}"  # 去除前导空白
    mount="${mount%"${mount##*[![:space:]]}"}"  # 去除尾随空白
    
    # 如果挂载规格非空，添加到有效挂载列表
    if [[ -n "$mount" ]]; then
      VALID_MOUNTS+=("$mount")
    fi
  done
fi

# ============================================================================
# 生成和配置 Compose 文件
# ============================================================================

# 如果有 home 卷配置或额外挂载，生成额外的 compose 文件
if [[ -n "$HOME_VOLUME_NAME" || ${#VALID_MOUNTS[@]} -gt 0 ]]; then
  # Bash 3.2 兼容性：在 nounset 模式下，空数组的 "${array[@]}" 会被视为未绑定
  if [[ ${#VALID_MOUNTS[@]} -gt 0 ]]; then
    # 如果有额外挂载，传递所有参数
    write_extra_compose "$HOME_VOLUME_NAME" "${VALID_MOUNTS[@]}"
  else
    # 只有 home 卷，没有额外挂载
    write_extra_compose "$HOME_VOLUME_NAME"
  fi
  # 将生成的额外配置文件添加到文件列表
  COMPOSE_FILES+=("$EXTRA_COMPOSE_FILE")
fi

# 构建 Docker Compose 命令参数（-f 指定配置文件）
for compose_file in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=("-f" "$compose_file")
done

# 构建提示字符串，用于显示完整的 docker compose 命令
COMPOSE_HINT="docker compose"
for compose_file in "${COMPOSE_FILES[@]}"; do
  COMPOSE_HINT+=" -f ${compose_file}"
done

# ============================================================================
# 环境变量文件管理
# ============================================================================

# .env 文件路径，用于持久化环境变量
ENV_FILE="$ROOT_DIR/.env"

# 函数：更新或插入环境变量到文件
# 参数：
#   $1 - 目标文件路径
#   $@ - 要更新的环境变量名称列表
# 功能：
#   - 如果变量已存在，更新其值
#   - 如果变量不存在，追加到文件末尾
#   - 保持其他行不变
upsert_env() {
  local file="$1"
  shift
  local -a keys=("$@")
  local tmp
  tmp="$(mktemp)"  # 创建临时文件
  
  # 使用分隔字符串代替关联数组，以兼容 Bash 3.2（macOS 默认版本）
  # Bash 3.2 不支持 declare -A 声明关联数组
  local seen=" "

  # 如果文件存在，读取并处理每一行
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      local key="${line%%=*}"  # 提取等号前的变量名
      local replaced=false
      
      # 检查这个变量是否在要更新的列表中
      for k in "${keys[@]}"; do
        if [[ "$key" == "$k" ]]; then
          # 找到匹配的变量，写入新值
          printf '%s=%s\n' "$k" "${!k-}" >>"$tmp"
          seen="$seen$k "  # 标记为已处理
          replaced=true
          break
        fi
      done
      
      # 如果不在更新列表中，保持原样
      if [[ "$replaced" == false ]]; then
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$file"
  fi

  # 追加文件中不存在的新变量
  for k in "${keys[@]}"; do
    if [[ "$seen" != *" $k "* ]]; then
      printf '%s=%s\n' "$k" "${!k-}" >>"$tmp"
    fi
  done

  # 用临时文件替换原文件
  mv "$tmp" "$file"
}

# 将所有配置变量写入或更新到 .env 文件
upsert_env "$ENV_FILE" \
  OPENCLAW_CONFIG_DIR \
  OPENCLAW_WORKSPACE_DIR \
  OPENCLAW_GATEWAY_PORT \
  OPENCLAW_BRIDGE_PORT \
  OPENCLAW_GATEWAY_BIND \
  OPENCLAW_GATEWAY_TOKEN \
  OPENCLAW_IMAGE \
  OPENCLAW_EXTRA_MOUNTS \
  OPENCLAW_HOME_VOLUME \
  OPENCLAW_DOCKER_APT_PACKAGES

# ============================================================================
# 构建 Docker 镜像
# ============================================================================

echo "==> Building Docker image: $IMAGE_NAME"
# 使用 Dockerfile 构建镜像
# --build-arg: 传递构建参数（APT 包列表）
# -t: 指定镜像标签
# -f: 指定 Dockerfile 路径
docker build \
  --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}" \
  -t "$IMAGE_NAME" \
  -f "$ROOT_DIR/Dockerfile" \
  "$ROOT_DIR"

# ============================================================================
# 用户引导和初始化配置
# ============================================================================

echo ""
echo "==> Onboarding (interactive)"
echo "When prompted:"
echo "  - Gateway bind: lan"
echo "  - Gateway auth: token"
echo "  - Gateway token: $OPENCLAW_GATEWAY_TOKEN"
echo "  - Tailscale exposure: Off"
echo "  - Install Gateway daemon: No"
echo ""

# 运行 CLI 容器执行 onboard 命令进行交互式初始化
# --rm: 容器退出后自动删除
# --no-install-daemon: 不安装系统守护进程（在容器中运行）
docker compose "${COMPOSE_ARGS[@]}" run --rm openclaw-cli onboard --no-install-daemon

# ============================================================================
# 提供商（消息通道）设置提示
# ============================================================================

echo ""
echo "==> Provider setup (optional)"
echo "WhatsApp (QR):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli channels login"
echo "Telegram (bot token):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli channels add --channel telegram --token <token>"
echo "Discord (bot token):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli channels add --channel discord --token <token>"
echo "Docs: https://docs.openclaw.ai/channels"

# ============================================================================
# 启动 Gateway 服务
# ============================================================================

echo ""
echo "==> Starting gateway"
# 启动 gateway 服务（后台运行）
# up -d: 以守护进程模式启动服务
docker compose "${COMPOSE_ARGS[@]}" up -d openclaw-gateway

# ============================================================================
# 显示配置信息和常用命令
# ============================================================================

echo ""
echo "Gateway running with host port mapping."
echo "Access from tailnet devices via the host's tailnet IP."
echo "Config: $OPENCLAW_CONFIG_DIR"
echo "Workspace: $OPENCLAW_WORKSPACE_DIR"
echo "Token: $OPENCLAW_GATEWAY_TOKEN"
echo ""
echo "Commands:"
echo "  ${COMPOSE_HINT} logs -f openclaw-gateway"
echo "  ${COMPOSE_HINT} exec openclaw-gateway node dist/index.js health --token \"$OPENCLAW_GATEWAY_TOKEN\""
