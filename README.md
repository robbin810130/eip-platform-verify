# EIP-Platform 验证镜像 · 构建资产

`eip-platform-verify` 是一个**只用于本地 / CI 离线校验**的容器镜像的构建资产。
它把项目自带的校验脚本（`scripts/check.sh`：文档链接检查、契约检查、Node 测试与构建、Rust 格式/clippy/测试、.NET 测试）
固化在一套**版本钉死、可离线复现**的工具链里，回答一个问题：

> 当前这棵工作树，能不能在纯净环境里跑完整套本地校验？

本仓库**只包含构建资产，不含任何应用源码**。镜像默认不启动服务、不连接数据库、
不挂载宿主 Docker socket、不内置任何凭据。

## ⚠️ 关于镜像里装了什么

`Dockerfile` 的工作方式是 `COPY . .` —— **镜像是携带源码的**（工具链 + 依赖预热缓存 + 被校验的源码树）。
所以：

- 镜像一旦推到**公开** registry，其中的源码就对所有人可见（`docker save` 后逐层解包即可读取）；
- **本仓库自身不含源码，可以安全公开；镜像是否公开是一个独立的决定。**

## 快速使用

先把本仓库的文件复制进项目源码树根目录（保持相对路径），然后在源码树根目录执行：

```sh
docker build --pull -t eip-platform-verify:2026-10-16 .
docker run --rm --network=none eip-platform-verify:2026-10-16
```

`--network=none` 是关键：所有依赖已在构建阶段预热进镜像（Cargo registry / NuGet 全局包目录 / npm cacache），
运行阶段完全离线也能跑完整套校验，**退出码即结论**。

要执行别的命令（而不是默认的校验脚本）：

```sh
docker run --rm --network=none eip-platform-verify:2026-10-16 bash
docker run --rm --network=none eip-platform-verify:2026-10-16 cargo test --workspace
```

可选：用 compose 运行

```sh
docker compose -f docker-compose.verify.yml run --rm verify
```

## 文件

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 验证镜像定义（与部署用镜像无关） |
| `.dockerignore` | build context 白名单与排除规则 |
| `docker/entrypoint.sh` | 无参数时跑 `scripts/check.sh`；带参数则直接执行该命令 |
| `docker-compose.verify.yml` | 可选的 compose 入口（`verify` 服务默认 `network_mode: none`） |
| `docs/verification-docker.md` | 机制说明、离线预热原理、已知偏差、排错与回滚 |

## 工具链（可通过 build-arg 覆盖）

| 组件 | 版本 | 覆盖方式 |
|---|---|---|
| 基础镜像 | `ubuntu:24.04` | `--build-arg BASE_IMAGE=...` |
| Rust | 1.90.0（minimal + rustfmt + clippy） | `--build-arg RUST_VERSION=...` |
| .NET SDK | 10.0.401 | `--build-arg DOTNET_SDK_VERSION=...` |
| Node.js | 24.22.0 LTS "Krypton"（与源仓库 CI 的 `node-version: '24'` 对齐；官方 tarball + SHASUMS256 校验） | `--build-arg NODE_VERSION=...` |
| Python | 系统 3.12 + venv（`jsonschema`） | — |
| 时区 / 编码 | `TZ=Asia/Shanghai`、`LANG=C.UTF-8` | — |
| 运行身份 | `uid=1000(verify)`，非 root | `--build-arg VERIFY_UID=...` |

`linux/amd64` 与 `linux/arm64` 均可构建（本仓库的构建资产不含任何架构绑定）。验证过程在 `arm64` 上完成。

## 网络受限环境

构建阶段需要联网拉取工具链与依赖。若官方源不可达，可换基础镜像（仅替换镜像源，不改其他步骤）：

```sh
docker build --pull \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04 \
  -t eip-platform-verify:2026-10-16 .
```

私有依赖（私有 registry / 私有 git 仓库）用 BuildKit secret 临时注入，不回写 Dockerfile、不进镜像层：

```sh
docker build --secret id=netrc,src="$HOME/.netrc" -t eip-platform-verify:2026-10-16 .
```

## 在 GitHub Actions 里验证（不需要本地容器运行时）

如果手边没有 Docker / Podman 运行时，源码仓库里配了两个工作流，**看 Actions 结论即可**：

| 工作流 | 平台 | 动作 | 目的 |
| --- | --- | --- | --- |
| `verify-in-container.yml` | `linux/amd64` | 构建 → `load` → **运行 `scripts/check.sh`**（`docker run --rm --network=none`） | 验证：退出码与日志尾部进 Job Summary，完整日志作为 `verify-log` artifact 保留 |
| `publish-image.yml` | `linux/amd64` + `linux/arm64` | 构建 → 推 GHCR（私有包） | 分发 |

二者都用仓库自带的 `GITHUB_TOKEN`（天然带 `packages:write`），**不需要扩容任何个人 PAT 作用域**，
也不需要本地上传镜像。详见 `docs/verification-docker.md` 第 10 节。

## 归属

本仓库是私有项目 `EIP-Platform` 的配套构建资产。使用前请确认与该项目相关的授权。
