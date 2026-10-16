# =============================================================================
# Maka EIP —— 本地 / CI 验证镜像（NOT FOR DEPLOYMENT）
# =============================================================================
#
# 用途（唯一用途）：
#   在容器内复现仓库自带的离线校验入口 scripts/check.sh，得到与 CI 一致的结果。
#
# 明确不做的事：
#   * 不部署任何服务，不启动监听端口，不发布产物
#   * 不连接生产环境，不连接真实 SQL Server（live 验收是独立入口，见
#     docs/development.md 的「隔离 Golden 库与 live 验收」）
#   * 不内置任何凭据：无 PAT、无密码、无连接串、无 .env、无 SSH key
#   * 不挂载宿主 Docker socket
#   * 运行时不需要网络（依赖已在构建阶段预热，见下方「依赖预热」）
#
# 工具链版本（与 .github/workflows/ci.yml 对齐，Node 按规格书取 22 LTS）：
#   * 基础镜像  ubuntu:24.04        （x86_64 / arm64 均可构建）
#   * Rust      1.90.0              （rustup 固定，含 rustfmt + clippy）
#   * .NET SDK  10.0.401            （global.json 锁定，target net10.0）
#   * Python    3.12                （Ubuntu 24.04 自带）
#   * Node.js   22.23.3 LTS (Jod)   （官方 tarball + SHA256 校验）
#
# 构建（在仓库根目录，context 必须是仓库根）：
#   docker build --pull -t eip-platform-verify:2026-10-16 .
#
# 运行（离线，推荐）：
#   docker run --rm --network=none eip-platform-verify:2026-10-16
#
# 运行（覆盖默认入口，跑任意命令）：
#   docker run --rm --network=none eip-platform-verify:2026-10-16 bash
#   docker run --rm --network=none eip-platform-verify:2026-10-16 \
#     scripts/cargo.sh run --locked -p eip-cli -- inspect fixtures/demo/bundle.json
#
# 私有依赖（如将来需要）：用临时 BuildKit secret 注入，绝不写入镜像层
#   docker build --secret id=netrc,src="$HOME/.netrc" \
#                --secret id=cargo_credentials,src="$HOME/.cargo/credentials.toml" ...
# =============================================================================

# 基础镜像可覆盖（例如国内镜像源 docker.m.daocloud.io/library/ubuntu:24.04）：
#   docker build --build-arg BASE_IMAGE=<mirror>/library/ubuntu:24.04 ...
# 默认保持官方地址，便于在任意环境（含 GitHub CI）直接构建。
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG RUST_VERSION=1.90.0
ARG DOTNET_SDK_VERSION=10.0.401
ARG NODE_VERSION=22.23.3

# NuGet 审计开关。上游间接依赖 System.Security.Cryptography.Pkcs 9.0.11 存在新披露漏洞
# （GHSA-2fmv-rv2c-59x7 / GHSA-846f-f764-76mx），而 csproj 同时开了 NuGetAudit=true 与
# TreatWarningsAsErrors=true，且 --locked-mode 不允许改版本 —— 结果是本机与 CI 的
# dotnet restore 现在都会失败。默认跳过审计以保证镜像能跑完整套校验；
# 要构建“如实失败”的严格镜像：docker build --build-arg SKIP_NUGET_AUDIT=false ...
# 详见 docs/verification-docker.md 的「已知阻断」一节。
ARG SKIP_NUGET_AUDIT=true

# 固定为非 root 用户；命名与常见 CI runner 习惯一致。
ARG VERIFY_USER=verify
ARG VERIFY_UID=1000
ARG VERIFY_GID=1000
ARG VERIFY_HOME=/home/verify

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    DOTNET_ROOT=/usr/local/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_GENERATE_ASPNET_CERTIFICATE=false \
    PIP_DISABLE_PIP_VERSION_CHECK=1

ENV PATH=/usr/local/cargo/bin:/usr/local/dotnet:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin


# -----------------------------------------------------------------------------
# 1. 系统依赖
#    build-essential/pkg-config 供 Rust 链接；
#    libicu/libssl/libgssapi/zlib/libunwind 是 .NET 10 在 Ubuntu 24.04 的运行时依赖；
#    python3-venv 用于隔离契约校验依赖（Ubuntu 24.04 是 PEP 668 externally-managed）。
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        gnupg \
        xz-utils \
        unzip \
        build-essential \
        pkg-config \
        python3 \
        python3-venv \
        python3-pip \
        tzdata \
        locales \
        libicu74 \
        libssl3t64 \
        libgssapi-krb5-2 \
        libstdc++6 \
        zlib1g \
        libunwind8; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. Rust 1.90.0（rustup，固定 toolchain + rustfmt + clippy）
#    rust-toolchain.toml 声明的 components 在此一并装好，避免运行期联网补齐。
# -----------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y \
        --no-modify-path \
        --profile minimal \
        --default-toolchain "${RUST_VERSION}" \
        -c rustfmt \
        -c clippy; \
    rm -f /tmp/rustup-init.sh; \
    rustup set auto-self-update disable; \
    rustup toolchain list; \
    cargo --version; \
    rustc --version; \
    rustfmt --version; \
    cargo clippy --version

# -----------------------------------------------------------------------------
# 3. .NET SDK 10.0.401（官方 dotnet-install.sh，版本完全钉死，不依赖 apt 源）
# -----------------------------------------------------------------------------
RUN set -eux; \
    export HOME=/root; \
    export DOTNET_CLI_HOME=/tmp/dotnet-root; \
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; \
    chmod +x /tmp/dotnet-install.sh; \
    /tmp/dotnet-install.sh \
        --version "${DOTNET_SDK_VERSION}" \
        --install-dir "${DOTNET_ROOT}" \
        --no-path; \
    ln -sf "${DOTNET_ROOT}/dotnet" /usr/local/bin/dotnet; \
    rm -rf /tmp/dotnet-root /tmp/dotnet-install.sh

# -----------------------------------------------------------------------------
# 4. Node.js 22 LTS（官方 tarball + SHASUMS256.txt 校验，按构建架构选择）
# -----------------------------------------------------------------------------
RUN set -eux; \
    cd /tmp; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
        amd64) node_arch="x64" ;; \
        arm64) node_arch="arm64" ;; \
        *) echo "ERROR: unsupported dpkg architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSLO "${base}/${tarball}"; \
    curl -fsSL "${base}/SHASUMS256.txt" -o SHASUMS256.txt; \
    grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "${tarball}" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "${tarball}" SHASUMS256.txt; \
    node --version; \
    npm --version; \
    npx --version

# -----------------------------------------------------------------------------
# 5. 非 root 用户与工作目录
#    ubuntu:24.04 自带 uid/gid 1000 的 ubuntu 用户与同名组，先移除才能复用 1000。
# -----------------------------------------------------------------------------
RUN set -eux; \
    if id -u "${VERIFY_UID}" >/dev/null 2>&1; then userdel -r "$(id -un "${VERIFY_UID}")" || true; fi; \
    if getent group "${VERIFY_GID}" >/dev/null 2>&1; then groupdel "$(getent group "${VERIFY_GID}" | cut -d: -f1)" || true; fi; \
    groupadd -g "${VERIFY_GID}" "${VERIFY_USER}"; \
    useradd -m -u "${VERIFY_UID}" -g "${VERIFY_GID}" -s /bin/bash "${VERIFY_USER}"; \
    mkdir -p /workspace "${VERIFY_HOME}/.nuget/packages" "${VERIFY_HOME}/.dotnet" "${VERIFY_HOME}/.npm" /opt; \
    chown -R "${VERIFY_UID}:${VERIFY_GID}" "${VERIFY_HOME}" /workspace /opt; \
    chown -R "${VERIFY_UID}:${VERIFY_GID}" "${CARGO_HOME}" "${RUSTUP_HOME}"; \
    id "${VERIFY_USER}"; \
    getent group "${VERIFY_GID}"

USER ${VERIFY_USER}
WORKDIR /workspace

# 运行期与构建期（verify 身份）的 HOME / 缓存位置；root 阶段不使用这些值。
# 这里用字面量而非 ${VERIFY_HOME}，避免 --build-arg 覆盖后与 passwd 条目不一致。
ENV HOME=/home/verify \
    DOTNET_CLI_HOME=/home/verify/.dotnet \
    NUGET_PACKAGES=/home/verify/.nuget/packages \
    EIP_PYTHON=/opt/eip-venv/bin/python

# -----------------------------------------------------------------------------
# 6. Python 契约校验依赖（独立 venv，避免污染系统解释器）
#    仅 requirements-dev.txt 的 jsonschema；运行时报告只用标准库。
# -----------------------------------------------------------------------------
COPY --chown=verify:verify requirements-dev.txt ./
RUN set -eux; \
    python3 -m venv /opt/eip-venv; \
    /opt/eip-venv/bin/python -m pip install --no-cache-dir --upgrade pip setuptools wheel; \
    /opt/eip-venv/bin/python -m pip install --no-cache-dir -r requirements-dev.txt; \
    /opt/eip-venv/bin/python -c 'import jsonschema, sys; print("jsonschema", jsonschema.__version__, "on", sys.version.split()[0])'; \
    "${EIP_PYTHON}" --version

# -----------------------------------------------------------------------------
# 7. Rust 依赖预热
#    只复制 manifest 与 lock，不复制源码 —— layer 缓存命中时源码变更不会重拉依赖。
#    cargo fetch 解析整个 workspace 依赖图（含 dev-dependencies）。
# -----------------------------------------------------------------------------
COPY --chown=verify:verify Cargo.toml Cargo.lock ./
COPY --chown=verify:verify crates/domain/Cargo.toml crates/domain/
COPY --chown=verify:verify crates/adapter-sdk/Cargo.toml crates/adapter-sdk/
COPY --chown=verify:verify crates/adapter-runtime/Cargo.toml crates/adapter-runtime/
COPY --chown=verify:verify crates/graph/Cargo.toml crates/graph/
COPY --chown=verify:verify crates/trace/Cargo.toml crates/trace/
COPY --chown=verify:verify adapters/fixture/Cargo.toml adapters/fixture/
COPY --chown=verify:verify adapters/sqlserver/Cargo.toml adapters/sqlserver/
COPY --chown=verify:verify apps/eip-cli/Cargo.toml apps/eip-cli/

# cargo fetch 要求每个 workspace member 至少有一个 target 文件（src/lib.rs、src/main.rs
# 或 manifest 中显式声明的 path），但这一层刻意只保留 manifest/lock 以便缓存。
# 因此先用 shell 生成临时 stub，fetch 成功后精确删除并清理空目录，不残留任何假源码。
# stub 清单直接来自 manifest 本身：每个 member 的 src/lib.rs，加上 manifest 中行首
# path = "..." 指向的文件（本仓库里是 tests/adapter-protocol/*.rs 与 apps/eip-cli/src/main.rs）。
# 注意：本次 RUN 结束后立即删除临时凭据，使其不进入任何镜像层。
RUN --mount=type=secret,id=cargo_credentials,required=false \
    --mount=type=secret,id=netrc,required=false \
    set -eux; \
    if [ -s /run/secrets/netrc ]; then \
        install -m 600 /run/secrets/netrc "${VERIFY_HOME}/.netrc"; \
        export CARGO_NET_GIT_FETCH_WITH_CLI=true; \
    fi; \
    if [ -s /run/secrets/cargo_credentials ]; then \
        install -m 600 /run/secrets/cargo_credentials "${CARGO_HOME}/credentials.toml"; \
    fi; \
    : > /tmp/cargo-stubs.txt; \
    for manifest in $(find . -name Cargo.toml -not -path './target/*'); do \
        member="$(dirname "${manifest}")"; \
        if [ "${member}" = "." ]; then continue; fi; \
        mkdir -p "${member}/src"; \
        : > "${member}/src/lib.rs"; \
        printf '%s\n' "${member}/src/lib.rs" >> /tmp/cargo-stubs.txt; \
        sed -nE 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "${manifest}" \
        | while read -r rel; do \
            mkdir -p "${member}/$(dirname "${rel}")"; \
            : > "${member}/${rel}"; \
            printf '%s\n' "${member}/${rel}" >> /tmp/cargo-stubs.txt; \
        done; \
    done; \
    printf 'temporary target stubs: %s\n' "$(wc -l < /tmp/cargo-stubs.txt)"; \
    cargo fetch --locked; \
    while read -r stub; do rm -f "${stub}"; done < /tmp/cargo-stubs.txt; \
    rm -f /tmp/cargo-stubs.txt; \
    find . -type d -empty -delete; \
    rm -f "${VERIFY_HOME}/.netrc" "${CARGO_HOME}/credentials.toml"; \
    cargo --version; \
    du -sh "${CARGO_HOME}/registry"

# -----------------------------------------------------------------------------
# 8. .NET 依赖预热（--locked-mode 严格按 packages.lock.json）
#    预热完成后把 NuGet 源清空：运行阶段的 restore 只能命中全局包目录，
#    从而在 --network=none 下也能确定性地通过（缺包会明确失败而非静默联网）。
#    审计部分见顶部 SKIP_NUGET_AUDIT 的说明。
# -----------------------------------------------------------------------------
COPY --chown=verify:verify global.json ./
COPY --chown=verify:verify adapters/sqlserver-dotnet/Eip.SqlServer.csproj \
                          adapters/sqlserver-dotnet/packages.lock.json \
                          adapters/sqlserver-dotnet/

RUN --mount=type=secret,id=netrc,required=false \
    set -eux; \
    if [ -s /run/secrets/netrc ]; then install -m 600 /run/secrets/netrc "${VERIFY_HOME}/.netrc"; fi; \
    audit_opt=""; \
    if [ "${SKIP_NUGET_AUDIT}" = "true" ]; then audit_opt="-p:NuGetAudit=false"; fi; \
    echo "NuGet restore options: [${audit_opt}]"; \
    dotnet --version; \
    dotnet --list-sdks; \
    dotnet restore adapters/sqlserver-dotnet/Eip.SqlServer.csproj --locked-mode ${audit_opt}; \
    rm -f "${VERIFY_HOME}/.netrc"; \
    mkdir -p "${VERIFY_HOME}/.nuget/NuGet"; \
    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<configuration>' \
        '  <packageSources>' \
        '    <clear />' \
        '  </packageSources>' \
        '</configuration>' \
        > "${VERIFY_HOME}/.nuget/NuGet/NuGet.Config"; \
    if [ "${SKIP_NUGET_AUDIT}" = "true" ]; then \
        printf '%s\n' \
            '<Project>' \
            '  <!-- 由验证镜像注入：上游漏洞公告使 locked-mode 的 restore 无法通过 NuGet 审计。' \
            '       实测在 NuGet.Config 里清空 auditSources 并不阻止 NuGet 访问 api.nuget.org' \
            '       取漏洞数据，因此改为用 Directory.Build.targets：它在 csproj 之后导入，' \
            '       属性优先级高于 csproj 里的 NuGetAudit，能真正关闭审计。' \
            '       背景与恢复方法见 docs/verification-docker.md。 -->' \
            '  <PropertyGroup>' \
            '    <NuGetAudit>false</NuGetAudit>' \
            '  </PropertyGroup>' \
            '</Project>' \
            > adapters/sqlserver-dotnet/Directory.Build.targets; \
        cat adapters/sqlserver-dotnet/Directory.Build.targets; \
    fi; \
    cat "${VERIFY_HOME}/.nuget/NuGet/NuGet.Config"; \
    du -sh "${NUGET_PACKAGES}"

# -----------------------------------------------------------------------------
# 9. Node 依赖预热
#    npm ci 严格按 package-lock.json；同时把所有 tarball 写入 $HOME/.npm/_cacache。
#    预热后强制离线（见下方 ENV）：运行阶段 npm ci 只读本地缓存，不再访问 registry。
# -----------------------------------------------------------------------------
COPY --chown=verify:verify apps/web-console/package.json \
                          apps/web-console/package-lock.json \
                          apps/web-console/

RUN --mount=type=secret,id=netrc,required=false \
    set -eux; \
    if [ -s /run/secrets/netrc ]; then install -m 600 /run/secrets/netrc "${VERIFY_HOME}/.netrc"; fi; \
    npm --prefix apps/web-console ci --no-audit --no-fund; \
    npm --version; \
    node --version; \
    rm -f "${VERIFY_HOME}/.netrc"; \
    du -sh "${VERIFY_HOME}/.npm/_cacache" || true

# 预热后强制 npm 走本地缓存：运行阶段 npm ci 不再访问 registry，
# 缓存缺失会明确失败而不是静默联网（需要联网排查时用 -e npm_config_offline=false 覆盖）。
ENV npm_config_offline=true \
    npm_config_audit=false \
    npm_config_fund=false

# -----------------------------------------------------------------------------
# 10. 源码（.dockerignore 白名单过滤后的仓库树）
#     放在最后，让源码变更只影响这一层。
# -----------------------------------------------------------------------------
COPY --chown=verify:verify . .

# 兜底修正仓库脚本的可执行位（git 已保留 +x，这里防御 Windows/导出场景）
RUN set -eux; \
    chmod +x scripts/*.sh docker/*.sh 2>/dev/null || true; \
    chmod +x scripts/*.py 2>/dev/null || true; \
    ls -l scripts/check.sh docker/entrypoint.sh; \
    printf 'workspace files: %s\n' "$(find . -type f -not -path './.git/*' | wc -l)"

# 仅本地/CI 校验用的标记；运行阶段不依赖网络与任何外部服务。
ENV EIP_VERIFY_IMAGE=1

LABEL org.opencontainers.image.title="Maka EIP verify (local/CI only)" \
      org.opencontainers.image.description="Offline verification image for the Maka EIP repository. Not for deployment." \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:24.04" \
      org.maka-eip.verify.rust="1.90.0" \
      org.maka-eip.verify.dotnet-sdk="10.0.401" \
      org.maka-eip.verify.node="22.23.3" \
      org.maka-eip.verify.python="3.12" \
      org.maka-eip.verify.entrypoint="scripts/check.sh"

# 无参数 → scripts/check.sh；带参数 → 直接执行该参数（支持覆盖命令）。
ENTRYPOINT ["/workspace/docker/entrypoint.sh"]
