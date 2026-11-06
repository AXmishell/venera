# veneraGo

## 项目介绍
 [veneraGo](https://github.com/AXmishell/veneraGo)是从上游[verera](https://github.com/venera-app/venera) 1.6.3分支开发的 Flutter 漫画阅读器
## 功能增加：
1. 增加了连续章节自动加载（不用再点击下一章了）
2. 优化流畅度

## 版本号与构建号

`pubspec.yaml` 中的 `version: X.Y.Z+N` 是唯一版本来源：

- `X.Y.Z` 是展示版本，同时写入 `lib/foundation/app.dart` 的 `version`。
- `N` 是构建号，同时写入 `app.dart` 的 `buildNumber`。
- 构建号按语义版本派生：`major * 10000 + minor * 100 + patch`
  （例如 `1.7.9 -> 10709`、`1.7.10 -> 10710`、`1.8.0 -> 10800`），
  这样跨版本始终递增。
- Android 最终 `versionCode = N * 10 + lane`：ABI 分包为 1/2/3，
  profile 为 7，universal 为 8，debug 为 9。

发布前修改版本并校验：

```bash
python3 update_version.py 1.7.10
python3 check_version.py --tag v1.7.10
```

`check_version.py` 会校验 `pubspec.yaml`、`app.dart` 与 tag 是否一致，
并确保构建号高于所有历史 tag。CI 的 `Check_Version` job 会在构建前执行同样的检查。

