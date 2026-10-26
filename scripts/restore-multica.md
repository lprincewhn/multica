# 加密备份恢复

`restore-multica.sh` 将原本独立的本机恢复脚本纳入版本管理，用于恢复包含
`database.dump`、`globals.sql`、`uploads.tar.gz`、`config.tar.gz`、
`manifest.txt` 和 `CONTENTS.sha256` 的备份。
配置归档必须包含 `.env` 和 `docker-compose.selfhost.yml`；
Compose 服务名须为 `postgres`、`backend` 和 `frontend`，
后端上传目录须挂载到 `/app/data/uploads`。

**此操作会覆盖目标部署的数据库、上传文件和配置。**
执行前先为目标环境另做一份独立备份。只使用可信来源的备份，并提前审查归档中的
Compose 配置，因为它决定 Docker 启动哪些容器、挂载哪些主机目录。
不要为了验证脚本而在运行中的部署上执行恢复。

## 运行条件与参数

需要 Bash、Docker 访问权限、Docker Compose v2、GnuPG、zstd、tar/gzip、
curl、coreutils、awk、grep、find 和 sed。归档工具镜像须包含 POSIX shell、
`find`、`tar` 和 gzip 支持。归档配置中的应用和数据库镜像须版本兼容，
建议固定不可变版本。

以下参数均为必填项，没有部署默认值：

| 参数 | 含义 |
| --- | --- |
| `--target-dir PATH` | 已存在的恢复目标目录，不是仓库的 `scripts/` 目录。 |
| `--backup PATH` | 本地加密备份；指定远程下载时作为下载目标。 |
| `--key PATH` | 用于解密的 GPG 私钥文件路径。 |
| `--project NAME` | 恢复目标的 Docker Compose 项目名。 |
| `--uploads-volume NAME` | 恢复目标的上传卷名，必须与后端实际挂载的卷一致。 |
| `--archive-image IMAGE` | 用于清空、恢复和统计上传卷的工具镜像。 |

路径相对于调用命令时的工作目录解析。目标目录、私钥和本地备份须事先存在。
从任意目录调用脚本都可以，但脚本路径须正确；脚本所在目录不决定恢复位置。
与原本的本机脚本不同，新版不默认远程下载，也不默认恢复到脚本目录。
原 `--skip-download` 的行为现在是默认行为，使用本地备份时不传 `--remote-backup`。

## 本机运行命令样例

在仓库根目录执行下列命令。先从最新 Multica 项目描述的“本机恢复命令样例”
一节取得本机参数，设置下列同名 shell 变量；具体主机地址、部署路径、卷名和
工具路径只保存在项目描述中，不写入仓库。不要提交私钥、凭据或备份归档。

本机若通过独立工具目录提供 `zstd`，将该目录填入 `ZSTD_BIN_DIR`。
下面通过临时 `PATH` 让脚本找到它，不更改系统配置；已在 `PATH` 中时可将
`ZSTD_BIN_DIR` 设为 `/usr/bin`。

```bash
: "${RESTORE_TARGET:?请按项目描述设置恢复目标目录}"
: "${ENCRYPTED_BACKUP:?请按项目描述设置本地加密备份路径}"
: "${PRIVATE_KEY_FILE:?请按项目描述设置私钥文件路径}"
: "${COMPOSE_PROJECT:?请按项目描述设置目标 Compose 项目名}"
: "${UPLOADS_VOLUME:?请按项目描述设置目标上传卷名}"
: "${ARCHIVE_IMAGE:?请按项目描述设置归档工具镜像}"
: "${ZSTD_BIN_DIR:?请设置 zstd 所在目录}"

PATH="$ZSTD_BIN_DIR:$PATH" \
bash scripts/restore-multica.sh \
  --target-dir "$RESTORE_TARGET" \
  --backup "$ENCRYPTED_BACKUP" \
  --key "$PRIVATE_KEY_FILE" \
  --project "$COMPOSE_PROJECT" \
  --uploads-volume "$UPLOADS_VOLUME" \
  --archive-image "$ARCHIVE_IMAGE"
```

此命令会实际恢复，不是预检查。样例保留交互确认，需要输入 `RESTORE`；
GPG 还可能提示输入私钥口令。仅在核对目标后才考虑加 `--yes` 跳过确认。
默认拉取镜像；加 `--skip-pull` 时所有镜像必须已在本机。

## 可选远程下载与校验

加 `--remote-backup "$SCP_SOURCE"` 可通过 `scp` 将备份下载到 `--backup`，
需要安装 `scp`，且下载目标的父目录须已存在。
若目标旁已有同名 `.sha256` 文件，脚本拒绝下载，避免误用旧校验值。
建议先单独下载备份及配套校验文件，核对后按本地备份方式运行。
没有外层 `.sha256` 文件时，脚本会明确提示只进行 GPG 认证解密和内部文件校验。

私钥导入权限受限的临时密钥环；退出时删除临时密钥环和明文归档，
不会删除输入的私钥文件或加密备份。

## 恢复范围与失败处理

PostgreSQL 通过显式指定的 Compose 项目访问，不依赖固定容器名。
清空上传文件前，脚本检查后端实际上传卷是否匹配 `--uploads-volume`。
配置按归档原样恢复，不自动改写域名、端口、卷名或反向代理设置；
执行前须确认这些值适用于目标环境，不能仅靠更换 `--project` 隔离所有数据卷。

与原脚本一致，数据库恢复使用 `--no-owner --no-acl`；
`globals.sql` 只校验、不执行。自定义角色和授权须另行审查、恢复。
服务停止后的失败会明确报错，但不会自动回滚已恢复的部分数据；
重试前应检查目标项目和数据状态。
健康检查只覆盖直接发布的前后端端口，不覆盖公开反向代理。
恢复成功后脚本退出，不再持续跟踪登录验证码日志。

## 隔离测试

```bash
bash -n scripts/restore-multica.sh scripts/restore-multica.test.sh
bash scripts/restore-multica.test.sh
```

测试使用生成的归档和模拟的 Docker、GPG、zstd、scp、curl 命令，
不读取部署凭据、不访问网络、不恢复真实数据，不能替代实际恢复演练。
