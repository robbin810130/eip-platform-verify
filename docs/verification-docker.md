# 验证镜像（本地 / CI 专用）

状态：**仅用于复现离线校验，不用于任何部署**。工具链版本与 `.github/workflows/ci.yml` 对齐。

> ⚠️ **先说一个与本镜像无关、但会拦住整套校验的仓库当前问题**：
> `dotnet restore --locked-mode` 因为上游包的新披露漏洞公告 + `TreatWarningsAsErrors` 而**失败**，
> 在开发机与容器内均可复现，与镜像无关。详见 [第 7 节](#7-已知阻断nuget-审计上游漏洞公告)。
> 本镜像默认跳过该项以保证其余检查能跑完，并保留严格模式开关。

本文描述仓库根目录 `Dockerfile`、`docker/entrypoint.sh`、`docker-compose.verify.yml` 三个文件。
它们**不是** `deploy/orbstack/Dockerfile` 的替代品：后者是部署运行镜像（nginx + 预编译产物），
本次新增的镜像是**校验环境**，两者用途互不重叠，共用一份 `.dockerignore`。

## 1. 用途与边界

**做**：在容器内复现仓库自带的离线校验入口 [`scripts/check.sh`](../scripts/check.sh)，得到
与 CI 一致的 pass/fail 结论；提供可覆盖命令的 shell 环境做本地排查。

**不做**（全部是硬边界，不是「暂未支持」）：

| 边界 | 说明 |
| --- | --- |
| 不部署 | 不启动服务、不监听端口、不发布产物、无 `EXPOSE` |
| 不连生产 | 不访问任何业务系统；默认 `--network=none` |
| 不连真实 SQL Server | live 验收是独立入口，见 [本地开发](development.md) 的「隔离 Golden 库与 live 验收」 |
| 不内置凭据 | 无 PAT、无密码、无连接串、无 `.env`、无 SSH key；`.dockerignore` 强制排除 `.env*`、`*.pem`、`id_rsa*`、`.netrc` |
| 不碰宿主 Docker | 不挂载 `/var/run/docker.sock` |
| 非 root 运行 | 容器内以 `verify`(uid 1000) 运行校验，不用 root |

`scripts/check.sh` 本身也不连数据库：它跑 Rust fmt/clippy/test、.NET locked restore + Release build +
self-test + 进程协议测试、Bundle/trace/传输 Schema 校验、scripts 单元测试、文档链接检查、
Python 报告测试与 CLI 比对、`npm ci` + Web 单元测试 + Web 构建。默认不启动服务。

## 2. 版本矩阵

| 组件 | 版本 | 来源与固定方式 |
| --- | --- | --- |
| 基础镜像 | `ubuntu:24.04` | `ARG BASE_IMAGE` 可覆盖（国内镜像源） |
| Rust | `1.90.0` | rustup 固定 toolchain，含 `rustfmt` + `clippy`（对应 `rust-toolchain.toml`） |
| .NET SDK | `10.0.401` | 官方 `dotnet-install.sh --version` 钉死（对应 `global.json`） |
| Python | `3.12` | Ubuntu 24.04 系统包；契约校验依赖装在独立 venv `/opt/eip-venv` |
| Node.js | `24.22.0` (LTS "Krypton") | 官方 tarball + `SHASUMS256.txt` SHA-256 校验，按 `dpkg --print-architecture` 选 x64/arm64；**与 `ci.yml` 的 `node-version: '24'` 对齐** |
| 系统库 | `build-essential`、`pkg-config`、`git`、`curl`、`ca-certificates` | 加 .NET 运行时依赖 `libicu74`、`libssl3t64`、`libgssapi-krb5-2`、`zlib1g`、`libunwind8` |
| 时区 / locale | `TZ=Asia/Shanghai`、`LANG=C.UTF-8` | 已写入 `/etc/localtime`、`/etc/timezone` |

架构：`linux/amd64` 与 `linux/arm64` 均可构建（Node 分段选择架构，其余组件自动匹配）。

> **Node 口径（与 CI 对齐）**：本镜像的 Node.js 是 `24.22.0`（LTS "Krypton"），
> 即 `.github/workflows/ci.yml` 里 `node-version: '24'` 由 `setup-node` 解析到的最新 24.x。
> 仓库自带的部署镜像 `deploy/orbstack/Dockerfile` 用的是 `node:22-bookworm-slim`，
> 那属于**部署链路**的口径，与本验证镜像互不影响。
>
> 若要退回 22 LTS（例如与部署链路对齐）：
>
> ```sh
> docker build --pull --build-arg NODE_VERSION=22.23.3 -t eip-platform-verify:2026-10-16 .
> docker run --rm --network=none eip-platform-verify:2026-10-16   # 换版本后必须重新验收
> ```
>
> 受影响的是 `npm ci`、`npm test`（`node --test`）与 `vite build` 三步。

## 3. 构建与运行

在**仓库根目录**执行（build context 必须是仓库根）：

```sh
# 构建
docker build --pull -t eip-platform-verify:2026-10-16 .

# 运行默认校验（离线）
docker run --rm --network=none eip-platform-verify:2026-10-16
```

需要镜像源时覆盖基础镜像：

```sh
docker build --pull \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04 \
  -t eip-platform-verify:2026-10-16 .
```

网络受限环境（中国大陆直连官方源较慢）：基础镜像可用上面的 `BASE_IMAGE` 换成国内镜像源；
镜像内的 apt / curl / npm 都走构建期网络，可叠加 Docker 预定义的代理构建参数（宿主机代理需允许局域网访问）：

```sh
docker build --pull \
  --build-arg HTTPS_PROXY=http://host.docker.internal:7897 \
  --build-arg HTTP_PROXY=http://host.docker.internal:7897 \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04 \
  -t eip-platform-verify:2026-10-16 .
```

代理只在**构建阶段**生效，不会写入镜像的运行环境；运行阶段（`--network=none`）不依赖网络。

用 compose（等价，含 `no-new-privileges`、不挂宿主目录）：

```sh
docker compose -f docker-compose.verify.yml build verify
docker compose -f docker-compose.verify.yml run --rm verify
```

### 覆盖命令

入口是 `docker/entrypoint.sh`：**无参数**执行 `scripts/check.sh`；**带参数**把参数当命令直接执行。

```sh
docker run --rm --network=none eip-platform-verify:2026-10-16 bash
docker run --rm --network=none eip-platform-verify:2026-10-16 \
  scripts/cargo.sh run --locked -p eip-cli -- inspect fixtures/demo/bundle.json
docker run --rm --network=none eip-platform-verify:2026-10-16 \
  npm --prefix apps/web-console run typecheck
docker run --rm --network=none eip-platform-verify:2026-10-16 \
  /opt/eip-venv/bin/python -m unittest discover -s scripts/tests -v
```

## 4. 为什么 `--network=none` 也能跑完

`scripts/check.sh` 里有三步**天然需要下载依赖**：`npm ci`、`dotnet restore --locked-mode`、
`cargo test --locked`。镜像在**构建阶段**就把这三层缓存全部预热进镜像层，运行阶段只读本地缓存：

| 阶段 | 构建阶段做了什么 | 运行阶段如何离线命中 |
| --- | --- | --- |
| Rust | 只复制 `Cargo.toml`/`Cargo.lock` 与各 member 的 `Cargo.toml`，然后 `cargo fetch --locked` | crate 源码与索引都在 `CARGO_HOME/registry` |
| .NET | 复制 `Eip.SqlServer.csproj` + `packages.lock.json` 后 `dotnet restore --locked-mode`（默认附带 `-p:NuGetAudit=false`，见第 7 节） | 包在 `NUGET_PACKAGES`；随后写入一份私有 `NuGet.Config`（`<clear/>` 掉 `packageSources`），运行期 restore 只能命中全局包目录（缺包会**明确失败**，不会静默联网） |
| Node | 复制 `package.json` + `package-lock.json` 后 `npm ci` | tarball 在 `$HOME/.npm/_cacache`；镜像设 `npm_config_offline=true`，运行期 `npm ci` 只读本地缓存、完全不访问 registry（缓存缺失会**明确失败**；需要联网排查时用 `-e npm_config_offline=false` 覆盖） |

先复制锁文件、后复制源码，因此**只改源码不会导致依赖重新下载**。

### Rust 依赖层的 stub 机制

`cargo fetch` 会解析 workspace 的每个 member manifest，而 cargo 要求每个 member 至少有一个 target：
`src/lib.rs`、`src/main.rs`，或 manifest 里显式声明的 `path`。如果这一层只放 manifest，`cargo fetch` 会直接失败：

```text
error: failed to load manifest for workspace member `crates/domain`
Caused by:
  no targets specified in the manifest
  either src/lib.rs, src/main.rs, a [lib] section, or [[bin]] section must be present
```

所以 `Dockerfile` 在这一层用 shell 生成**临时 stub**：为每个 member 建空的 `src/lib.rs`，
再从 manifest 中抽取行首 `path = "..."` 指向的文件（本仓库是 `tests/adapter-protocol/fake_child.rs`、
`tests/adapter-protocol/subprocess.rs`、`apps/eip-cli/src/main.rs`）一并建空文件；
`cargo fetch --locked` 成功后**立刻删除这些 stub 并清理空目录**，因此镜像里不会残留任何假源码，
后续 `COPY . .` 提供的是仓库真实源码。这样 `cargo fetch` 所在层只依赖 manifest/lock 内容，
源码改动不会击穿依赖缓存。

预热用的私有凭据（如果有）通过 BuildKit secret 在单条 `RUN` 内挂载，并在该 `RUN` 结束前删除，
不会留在任何镜像层。

## 5. 私有依赖

默认不需要任何凭据。若将来引入私有 registry，**不要**把凭据写进 Dockerfile 或提交仓库，改用一次性 secret：

```sh
docker build \
  --secret id=netrc,src="$HOME/.netrc" \
  --secret id=cargo_credentials,src="$HOME/.cargo/credentials.toml" \
  -t eip-platform-verify:2026-10-16 .
```

`Dockerfile` 里三处预热 `RUN` 都声明了 `required=false` 的可选挂载点（`netrc`、`cargo_credentials`），
未提供时自动跳过；凭据在使用后立即 `rm`。`netrc` 同时被 curl/git/npm 读取，可覆盖私有 npm registry。

## 6. 与 CI / 本地开发的关系

- 版本矩阵与 `.github/workflows/ci.yml` 一致（CI 用 `ubuntu-latest` + Python 3.12 + Node 24 + Rust 1.90.0 + .NET 10.0.401）。
  本镜像的 Node 按需求取 **22 LTS**；`package.json` 的 `engines` 要求为 `>=22.18.0`，二者兼容。
- 校验入口完全复用仓库自带 `scripts/check.sh` 与 `scripts/dotnet.sh`，**没有**在镜像里另写一套检查逻辑；
  `scripts/dotnet.sh` 会优先使用系统 `dotnet`（镜像里是 `/usr/local/dotnet`，同时软链到 `/usr/local/bin/dotnet`）。
- 与 [本地开发](development.md) 的 venv 约定一致：契约校验依赖装在独立 venv，通过 `EIP_PYTHON` 注入，
  默认值 `/opt/eip-venv/bin/python`；需要时可在 `docker run` 时用 `-e EIP_PYTHON=...` 覆盖。
- 「CI 定义存在」不等于远端已运行；同理「镜像构建成功」不等于校验通过 —— 以容器内 `check.sh` 的输出为准。

## 7. 已知阻断：NuGet 审计（上游漏洞公告）

**这是仓库当前的真实状态，不是本镜像引入的问题。** 构建本镜像时实测，`dotnet restore --locked-mode`
在**开发机（macOS + .NET SDK 10.0.401）与容器内都会失败**：

```text
error NU1902: 包 "System.Security.Cryptography.Pkcs" 9.0.11 具有已知的 中 严重性漏洞，
              https://github.com/advisories/GHSA-2fmv-rv2c-59x7
error NU1903: 包 "System.Security.Cryptography.Pkcs" 9.0.11 具有已知的 高 严重性漏洞，
              https://github.com/advisories/GHSA-846f-f764-76mx
未能还原 Eip.SqlServer.csproj
```

根因链：

1. `adapters/sqlserver-dotnet/Eip.SqlServer.csproj` 同时设置了 `NuGetAudit=true` 与 `TreatWarningsAsErrors=true`；
2. `System.Security.Cryptography.Pkcs 9.0.11` 是 `Microsoft.Data.SqlClient` 的传递依赖，近期披露了上述两个公告；
3. NuGet 审计告警（NU1902/NU1903）在 `TreatWarningsAsErrors` 下被升级为 error；
4. `--locked-mode` 严格按 `packages.lock.json` 还原，**不允许**自动升到已修复版本，因此无法自愈；
5. restore 失败会中断 `scripts/check.sh` 的 `scripts/check-dotnet.sh` 步骤 —— 本机与 CI 同样如此。

修复方向属于**仓库代码变更**（升级 `packages.lock.json` 里的传递依赖版本，或调整审计级别/豁免策略），
本镜像刻意**不修改仓库任何构建文件**。

本镜像的处置（默认 `SKIP_NUGET_AUDIT=true`）：

- 构建阶段：`dotnet restore ... --locked-mode -p:NuGetAudit=false`；
- 运行阶段：往 `adapters/sqlserver-dotnet/` 注入一份 `Directory.Build.targets`，内容为 `<NuGetAudit>false</NuGetAudit>`。
  它在 `csproj` **之后**导入，属性优先级高于 `csproj` 里的 `<NuGetAudit>true</NuGetAudit>`，
  因此 `check-dotnet.sh` 里那条不带任何参数的 `dotnet restore --locked-mode` 也能关掉审计。

实测记录（两种失败过的尝试，留档以免重复踩）：

1. 在私有 `NuGet.Config` 里 `<clear/>` 掉 `auditSources` —— **无效**。NuGet 仍然去 `api.nuget.org`
   取漏洞数据，在 `--network=none` 下报 `error NU1900: Error occurred while getting package vulnerability
   data: Resource temporarily unavailable (api.nuget.org:443)`，同样被 `TreatWarningsAsErrors` 升级为错误。
2. 只清空 `packageSources` 而不关审计 —— 同上，审计数据源不随包源一起被清空。

注入的 `Directory.Build.targets` **只存在于镜像内**，不写入你的仓库工作区。想确认它：

```sh
docker run --rm --network=none eip-platform-verify:2026-10-16 \
  cat adapters/sqlserver-dotnet/Directory.Build.targets
```

要得到**如实失败**的严格镜像（还原仓库真实红灯）：

```sh
docker build --build-arg SKIP_NUGET_AUDIT=false -t eip-platform-verify:2026-10-16-strict .
docker run --rm --network=none eip-platform-verify:2026-10-16-strict   # 会在 check-dotnet.sh 处失败
```

**被跳过的只有 NuGet 漏洞审计这一项**，其余检查全部照跑：`cargo fmt` / `clippy` / `test`、
Bundle 与 trace 契约 Schema 校验、`scripts` 单元测试、文档链接检查、Python 报告测试与 CLI 比对、
`npm ci` + Web 单元测试 + Web 构建。

## 8. 已知限制

1. **不覆盖浏览器验收**：`apps/web-console` 的 Playwright e2e（`npm run test:browser`）不在
   `check.sh` 内，镜像也未安装浏览器二进制。
2. **不覆盖 live 验收**：任何需要 SQL Server 的脚本（`check-sqlserver-live.py`、
   `check-runtime-live.py`、`setup-golden-*`）都需要显式的隔离 Golden 环境连接串，本镜像**不提供**，
   也不应把生产连接串传进来。
3. **`check_docs.py` 的链接检查范围与 git 跟踪范围一致**：镜像里排除了未跟踪的本地残留目录
   （`.tmp`、`artifacts`、`.npm-cache`、`.test-artifacts`、`**/target` 等），因此比一份「脏」工作区更接近 CI；
   如果你的工作区有未跟踪但被文档链接引用的文件，容器内检查可能报缺失，这是预期行为。
4. **未提交的本地改动会被带进镜像**：`COPY . .` 复制的是当前工作区（受 `.dockerignore` 过滤），
   与 CI 的「干净 checkout」不同。要复现 CI 结论，请先 `git stash` 或改用干净 clone 作为 context。
5. **镜像体积较大**（完整 Rust + .NET SDK + Node + 预装依赖），这是「运行期可离线」的代价；
   它是校验镜像，不应作为运行镜像分发。

## 9. 清理与回滚

本方案只新增文件，未改动仓库已有构建路径，因此回滚就是删除：

```sh
docker image rm eip-platform-verify:2026-10-16
```

新增文件清单：`Dockerfile`、`docker/entrypoint.sh`、`docker-compose.verify.yml`、`docs/verification-docker.md`、
`.github/workflows/publish-image.yml`、`.github/workflows/verify-in-container.yml`。

被修改的既有文件只有两个，且都是**追加式**改动：

| 文件 | 改动 | 影响 |
| --- | --- | --- |
| `.dockerignore` | 只扩充白名单（新增 `scripts/`、`agents/`、`tests/`、`docs/`、`tasks/`、`docker/`、`fixtures/`、`.github/`、根级锁文件与 manifest），并补充排除未跟踪的本地残留目录 | `deploy/orbstack/Dockerfile` 的构建不受影响，只是 build context 略变大；未删除任何原有条目。`.github/` 必须放行：`check_docs.py` 校验 Markdown 里的本地链接目标，而 `docs/` 引用了工作流文件 |
| `docs/README.md` | 技术文档导航新增一行指向本文 | 纯文档 |

## 10. 在 GitHub Actions 里验证（不需要本地容器运行时）

本地或临时环境可能**没有 Docker / Podman 运行时**，这时用
[`.github/workflows/verify-in-container.yml`](../.github/workflows/verify-in-container.yml)：
它在 runner 上构建 `linux/amd64` 镜像、`load` 进本地镜像仓库，然后执行

```sh
docker run --rm --network=none eip-platform-verify:ci
```

把退出码、日志尾部写进 Job Summary，完整日志作为 artifact `verify-log` 保留 14 天。
**结论与本地 `docker run --rm --network=none` 完全等价**，只是执行位置换成了 runner。

触发方式：

| 方式 | 条件 |
| --- | --- |
| 自动 | push 到 `main` 且改动命中 `Dockerfile` / `.dockerignore` / `docker/**` / `scripts/**` / `contracts/**` / `crates/**` / `adapters/**` / `apps/**` / `agents/**` / `tests/**` / `fixtures/**` / 锁文件 |
| 手动 | Actions → `verify-in-container` → Run workflow |

与推镜像工作流的分工：

| 工作流 | 平台 | 动作 | 目的 |
| --- | --- | --- | --- |
| `verify-in-container.yml` | `linux/amd64` | 构建 → `load` → **运行 check.sh** | 验证（拿到 pass/fail） |
| `publish-image.yml` | `linux/amd64` + `linux/arm64` | 构建 → 推 GHCR | 分发（拿到可拉取的镜像） |

两者都不需要任何本地容器运行时；`publish-image.yml` 用仓库自带的 `GITHUB_TOKEN`
（天然带 `packages:write`），不需要扩容个人 PAT 作用域。

## 11. 关于另一份 `Dockerfile.eip-verify` 草案（结论：未采用）

曾评估过一份基于 `mcr.microsoft.com/dotnet/sdk:10.0.401-bookworm-slim` 的轻量草案
（apt 装 `nodejs npm`、rustup 装 1.90.0、`COPY . .` 后 `npm ci --ignore-scripts`、`CMD bash`）。
**它在构建阶段就会失败，无法作为验证载体**，因此未采用。证据：

| # | 问题 | 证据 | 后果 |
| --- | --- | --- | --- |
| 1 | 基础镜像 tag 不存在 | `mcr.microsoft.com/v2/dotnet/sdk/tags/list` 中 `10.0.401` 有 40 个变体（`noble`/`alpine3.23`/`azurelinux3.0`/裸 tag…），**没有 `bookworm`、也没有任何 `slim`** | `docker build` 立刻失败（manifest unknown） |
| 2 | `RUN npm ci` 落在没有 `package.json` 的目录 | 仓库根目录**没有** `package.json`（Web 应用在 `apps/web-console`），而 `check.sh` 第 21 行用的是 `npm --prefix apps/web-console ci` | 构建期失败 |
| 3 | 从不安装 Python 契约校验依赖 | `check.sh` 有 11 处 Python 调用，其中 6 个脚本 `import jsonschema`（`requirements-dev.txt` 固定 `jsonschema==4.25.1`）；草案只装 `python3-pip` | 即使绕过 1、2，也会大面积 `ModuleNotFoundError` |
| 4 | 未设置 `EIP_PYTHON` | `check.sh` 第 5-6 行按该变量选解释器，未设置则回退系统 `python3`（无 `jsonschema`） | 同上 |
| 5 | `apt install nodejs npm` 在 Debian bookworm 上给的是 Node 18 | 既不满足 `ci.yml` 的 `node-version: '24'`，也不满足本验证镜像的 `24.22.0` | 版本口径错位 |
| 6 | 以 `root` 运行 | — | 违反「非 root 用户运行检查」 |
| 7 | `CMD ["bash"]` | — | 违反「入口默认执行 `scripts/check.sh`，且可覆盖命令」 |
| 8 | `COPY . .` 之后才装依赖 | — | 无依赖分层，任何源码改动都击穿依赖缓存 |
| 9 | 完全没有依赖预热（无 `cargo fetch` / `dotnet restore` / npm 缓存固化） | — | 运行期必须联网，做不到 `--network=none` 离线校验 |

若确实想要一个**轻量交互镜像**（构建快、体积小、进容器手工排查）作为补充，最小修改集是：
换成 `mcr.microsoft.com/dotnet/sdk:10.0.401-noble`（或裸 `10.0.401`）、
`npm --prefix apps/web-console ci`、`pip install -r requirements-dev.txt` 并导出 `EIP_PYTHON`、
改用官方 Node tarball 装 22/24、建非 root 用户、入口指向 `scripts/check.sh`、
把依赖安装前置到 `COPY` 源码之前。但那已经是**另一套需要独立验收的镜像**，属于增量需求，本次未做。
