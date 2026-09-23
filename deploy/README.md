# QuantMind 部署指南

## 选择部署方式

| 方式 | 适用场景 | 入口 |
| --- | --- | --- |
| 完整部署 | 从 CDN 下载完整业务数据、模型与 Qlib 数据包，一键迁移；开箱即用 | `full-deploy.sh` |
| 在线源码部署 | 新服务器可稳定访问代码和镜像仓库，部署后另行准备数据 | `deploy.sh` |
| 一键更新 | 已部署服务器更新代码和核心服务 | `update.sh` |
| AutoDL GPU 训练 | 主节点已就绪，把模型训练卸到 AutoDL 显卡实例（免 Docker） | `autodl/README.md` |

所有脚本支持 Ubuntu 22.04 / 24.04，默认项目目录为 `/opt/quantmind`。完整说明（含 AutoDL 节点）见 **[docs/部署指南.md](../docs/部署指南.md)**。

## 完整部署

完整部署包 CDN 目录默认是 `https://cdn.quantmind.cloud/quantmind-offline`，应包含：

```text
SHA256SUMS
images.tar.zst
data-system.tar.zst
postgres-all.sql.zst
quantmind_qwenpaw-*.tar.zst
README.txt
```

```bash
curl -fsSL https://gitee.com/qusong0627/QuantMind/raw/master/deploy/full-deploy.sh | sudo bash
```

可覆盖完整部署包地址、代码分支或 Docker 加速地址：

```bash
sudo QUANTMIND_OFFLINE_BASE_URL='https://example.com/quantmind-offline' \
  QUANTMIND_REF='master' \
  QUANTMIND_DOCKER_MIRROR='https://你的镜像加速域名' \
  bash deploy/full-deploy.sh
```

脚本默认保留已有 Qlib、业务目录、数据库和 QwenPaw 卷。确认需要覆盖时再传入：

```bash
QUANTMIND_REPLACE_QLIB=true \
QUANTMIND_REPLACE_BUSINESS_DATA=true \
QUANTMIND_REPLACE_DATABASE=true \
QUANTMIND_REPLACE_QWENPAW_DATA=true
```

## 离线包制作与依赖指纹

`full-deploy.sh` 用「依赖指纹」在速度与新鲜度之间自动决策：镜像构建时把
requirements 指纹写入 Label `qm.req.sha`，部署时与当前代码算出的指纹比对——
一致直接复用成品镜像（秒级）；不一致（如依赖新增了包）自动重建对齐。

**制作镜像时必须打指纹戳**（否则部署侧视为无指纹、每次触发重建）：

```bash
QM_REQ_SHA=$(bash deploy/req-fingerprint.sh) docker compose build quantmind
docker save quantmind-oss:latest <其余镜像...> | zstd -T0 -o images.tar.zst
```

指纹只覆盖 `requirements.txt`、`requirements/{production,ai}.txt`、
`docker/Dockerfile.oss` 与 `TORCH_DEVICE` 取值；**业务代码走 bind mount，
纯代码更新不需要重新制作镜像包**。requirements/Dockerfile 变更后才需重打
images.tar.zst；来不及重打包时，联网部署机会自动重建补齐（保持服务可用）。

`TORCH_DEVICE` 默认 `auto`：构建期动态探测（本地 wheel > 基础镜像已含 torch >
构建机有 GPU > CPU），实际形态写入镜像 `/etc/quantmind/torch-device`。需要强制
时用 `TORCH_DEVICE=cpu|gpu|skip` 覆盖；打包与部署两侧须取同一取值，指纹才对得上。

## 在线源码部署

```bash
sudo bash deploy/deploy.sh
```

常用参数：

```bash
sudo bash deploy/deploy.sh --ref NEXT
sudo bash deploy/deploy.sh --force
```

在线脚本会安装运行时、配置 Docker 镜像加速、同步代码、首次生成 `.env`、构建核心镜像并启动 Compose 服务。

## 一键更新

```bash
cd /opt/quantmind
sudo bash deploy/update.sh
```

```bash
sudo bash deploy/update.sh --ref NEXT
sudo bash deploy/update.sh --force
sudo bash deploy/update.sh --no-build
```

更新脚本只同步代码和核心容器，不会默认删除 PostgreSQL、Redis、`data/`、`models/` 或 `db/qlib_data/`，并会自动导入 `data/upgrade_*.sql` 数据库升级补丁（补丁需保持幂等，可重复执行）。

## Web 前端（原生 Nginx）

浏览器版前端不进 Docker。前端在本地构建，用 rsync 上传到 Nginx 主机，由宿主机上的原生 Nginx 托管。Nginx 同时把 `/api/`、`/ws/` 反代到后端。Nginx 主机和后端可以是同一台，也可以是两台不同的机器。

```text
浏览器 → Nginx 主机:<端口><WEB_PATH>   静态文件（本地构建后 rsync 上传）
       → Nginx 主机:<端口>/api/        → 后端:8000
       → Nginx 主机:<端口>/ws/         → 后端:8003（剥离 /ws 前缀）
```

### 首次安装（在 Nginx 主机上执行，只需一次）

1. 按实际情况替换占位符，生成配置片段：

   | 占位符 | 含义 | 示例 |
   | --- | --- | --- |
   | `@BACKEND_HOST@` | 后端 IP（必须填 IP，不能填域名） | `10.0.0.8` |
   | `@HTML_ROOT@` | Nginx 静态根目录 | `/usr/share/nginx/html` |
   | `@WEB_PATH@` | 访问子路径，前后都带 `/`；独占站点填 `/` | `/QuantMind/` |

   ```bash
   sed -e 's#@BACKEND_HOST@#<后端 IP>#' -e 's#@HTML_ROOT@#/usr/share/nginx/html#' \
       -e 's#@WEB_PATH@#/QuantMind/#' deploy/nginx/quantmind.locations.conf \
       | sudo tee /etc/nginx/quantmind.locations.conf >/dev/null
   ```

2. 挂到某个 server 块里：先备份 `nginx.conf`，然后在目标 `server { }` 内加一行：

   ```nginx
   include /etc/nginx/quantmind.locations.conf;
   ```

   如果没有现成的 server 块，就单独起一个：`server { listen 80; server_name _; include /etc/nginx/quantmind.locations.conf; }`。

3. `sudo nginx -t && sudo systemctl reload nginx`

注意：前端的 API 和 WebSocket 固定请求**根路径**下的 `/api/`、`/ws/`，所以挂载的那个 server 块里不能有别的服务占用 `/api/` 前缀。更长的前缀（如 `/api/xxx/`）不受影响，因为 Nginx 按最长前缀匹配。

### 日常更新前端（在本地执行）

第一次使用前，先复制一份配置，按实际地址填写（`deploy/web.local.env` 已加入 gitignore，不会提交）：

```bash
cp deploy/web.env.example deploy/web.local.env
```

以后每次更新执行：

```bash
npm install                             # 仅首次或依赖变更时
bash scripts/deploy_frontend.sh         # 构建 → 上传 → 校验
bash scripts/deploy_frontend.sh --skip-build   # 已构建过，只上传
```

脚本先上传新的 chunk，再切换 `index.html` 并清理旧文件，避免用户白屏。最后在 Nginx 主机上用 curl 校验 main chunk 返回 200。静态文件更新**不需要** reload Nginx；只改前端时也**不需要**执行 `deploy/update.sh`。

### 后端换机器

在 Nginx 主机上修改 `/etc/nginx/quantmind.locations.conf` 中的一行：

```nginx
set $qm_backend "<新后端 IP>";
```

然后执行 `sudo nginx -t && sudo systemctl reload nginx`。前端不需要重新发布。

### 排障

| 现象 | 原因与处理 |
| --- | --- |
| 访问页面返回 403 | 目录里没有 `index.html`（上传不完整，或多了一层嵌套目录），或者 Nginx 用户没有读权限（项目放在 `/root` 下时常见） |
| 页面能打开但登录失败，请求发到了 `127.0.0.1:8000` | 前端误判成了桌面端，检查 `isElectronEnv()` 与 `utils/electronCompat.ts` 里的 `isWebShim` 标记 |
| `/api/` 返回 502 | Nginx 主机连不上后端，在 Nginx 主机上执行 `curl http://<后端 IP>:8000/health` 排查；CentOS 还需 `setsebool -P httpd_can_network_connect 1` |
| 某些资源 404 | 代码里写死了 `/xxx` 这样的根路径，改成相对路径或按 `import.meta.env.BASE_URL` 拼接 |

安全要求：Nginx 的静态根目录只能放构建产物，**禁止**放项目源码目录，否则 `.env` 可以被直接下载。

## 验证与排障

```bash
cd /opt/quantmind
docker compose ps
docker compose logs --tail=200 quantmind
curl http://127.0.0.1:8000/health
```

| 服务 | 默认端口 |
| --- | --- |
| Web（宿主机原生 Nginx，见 `deploy/nginx/quantmind.locations.conf`） | 按所挂 server 块 |
| API / Engine / Trade / Stream | 8000 / 8001 / 8002 / 8003 |
| Data Gateway | 8004 |
| Huntly / RSSHub / QwenPaw | 8090 / 1200 / 8088 |

## AutoDL 远程 GPU 训练

不要把整套平台装进 AutoDL。主节点继续跑 Docker，AutoDL 只做 **`native_python` 训练 Worker**（实例一般不能嵌套 Docker）。

1. AutoDL 上执行 `deploy/autodl/setup-autodl-native.sh`，或一条命令下载执行 `deploy/autodl/quick-setup.sh`（详见 [`autodl/README.md`](autodl/README.md)）。
2. 主节点写 `config/training_nodes.yaml`（gitignore），`exec_mode: native_python`，数据目录 `/root/autodl-fs/quantdb`。
3. `.env` 设置 `TRAINING_MASTER_HOST=<协调机公网IP>`，重启 `quantmind`。
4. 桌面客户端模型训练页选择该节点。

端到端步骤、端口变更与排障见 **[docs/部署指南.md 第十一节](../docs/部署指南.md)**。
