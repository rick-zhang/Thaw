#!/bin/bash
# 构建当前源码的 Apple Silicon 版本，并将 Thaw 安装到 /Applications。
set -euo pipefail

usage() {
    cat <<'EOF'
用法：./scripts/install-local.sh [--no-open] [--help]

构建 Apple Silicon（arm64）Release 版本，退出正在运行的 Thaw，整包替换 /Applications/Thaw.app。
新应用校验通过后直接删除旧应用，不保留备份。
首次运行自动创建 Thaw 专用本地签名证书，以后固定复用。
首次迁移到该证书时清除旧的 Thaw 辅助功能和屏幕录制授权，后续安装保留授权。
默认在安装后启动应用；安装需要管理员权限时会调用 sudo。

选项：
  --no-open  安装后不启动应用
  --help     显示帮助
EOF
}

launch_app=true
for argument in "$@"; do
    case "$argument" in
        --no-open) launch_app=false ;;
        --help|-h) usage; exit 0 ;;
        *) printf '错误：未知参数 %s\n' "$argument" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "$EUID" -eq 0 ]]; then
    echo '错误：请以当前登录用户运行此脚本，不要对整个脚本使用 sudo，以便使用自己的签名钥匙串。' >&2
    exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$project_root/build/local"
built_app="$derived_data/Build/Products/Release/Thaw.app"
installed_app="/Applications/Thaw.app"

if [[ "$(uname -s)" != Darwin ]]; then
    echo '错误：此脚本只能在 macOS 上运行。' >&2
    exit 1
fi

if ! xcodebuild -version; then
    echo '错误：请安装完整的 Xcode，并使用 xcode-select 选择其开发者目录。' >&2
    exit 1
fi

signing_identity="$(/bin/bash "$project_root/scripts/local-signing-identity.sh")"
printf '使用 Thaw 专用签名证书：%s\n' "$signing_identity"

# 本地自签名证书没有 Apple Team ID，需允许加载嵌入的 Sparkle。
# 仅通过本次构建参数添加此例外，保留 Hardened Runtime 的其他保护。
local_entitlements="$derived_data/LocalInstall.entitlements"
mkdir -p "$derived_data"
cat > "$local_entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

echo '正在构建 Thaw（Apple Silicon / Release），首次构建需要联网下载依赖……'
xcodebuild build \
    -project "$project_root/Thaw.xcodeproj" \
    -scheme Thaw \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity" \
    OTHER_CODE_SIGN_FLAGS='--timestamp=none' \
    CODE_SIGN_ENTITLEMENTS="$local_entitlements" \
    DEVELOPMENT_TEAM=

if [[ ! -x "$built_app/Contents/MacOS/Thaw" ]]; then
    printf '错误：未找到构建产物 %s\n' "$built_app" >&2
    exit 1
fi

# 整包替换需要父目录写权限；sudo 无法代替 macOS 的应用管理授权。
needs_sudo=false
if [[ ! -w /Applications ]]; then
    needs_sudo=true
    if ! sudo -v; then
        echo '错误：安装需要管理员权限，请在本机终端运行此脚本并完成 sudo 认证。' >&2
        printf '已保留构建产物：%s\n' "$built_app" >&2
        exit 1
    fi
fi

run_install() {
    if [[ "$needs_sudo" == true ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

installation_error() {
    echo '错误：应用安装失败。若出现 Operation not permitted，请在“系统设置 → 隐私与安全性 → App 管理（应用管理）”中允许当前终端应用修改其他应用，然后重试。' >&2
    printf '构建产物保留在：%s\n' "$built_app" >&2
}

# 在工程构建目录中准备完整应用包，避免新旧资源合并及文件/目录类型冲突。
if ! staging_dir="$(/usr/bin/mktemp -d "$derived_data/install.XXXXXX")"; then
    installation_error
    exit 1
fi
staged_app="$staging_dir/Thaw.app"
printf '正在准备完整应用包：%s\n' "$staged_app"
if ! /usr/bin/ditto "$built_app" "$staged_app" \
    || ! /usr/bin/codesign --verify --deep --strict "$staged_app"; then
    installation_error
    printf '未完成的暂存目录：%s\n' "$staging_dir" >&2
    exit 1
fi

# 构建成功后再退出旧版本，避免构建失败影响当前使用。
current_uid="$(id -u)"
if pgrep -u "$current_uid" -x Thaw >/dev/null; then
    echo '正在退出当前用户运行的 Thaw……'
    if ! osascript -e 'tell application id "com.stonerl.Thaw" to quit'; then
        echo '错误：无法退出 Thaw，请手动退出后重新运行脚本。' >&2
        exit 1
    fi
    for ((attempt = 0; attempt < 20; attempt++)); do
        if ! pgrep -u "$current_uid" -x Thaw >/dev/null; then
            break
        fi
        sleep 0.5
    done
    if pgrep -u "$current_uid" -x Thaw >/dev/null; then
        echo '错误：Thaw 尚未退出，请手动退出后重新运行脚本。' >&2
        exit 1
    fi
fi

printf '正在安装到 %s（整包替换）……\n' "$installed_app"
if [[ -e "$installed_app" || -L "$installed_app" ]]; then
    if ! run_install /bin/rm -rf -- "$installed_app"; then
        installation_error
        printf '新应用暂存于：%s\n' "$staged_app" >&2
        exit 1
    fi
fi
if ! run_install /bin/mv "$staged_app" "$installed_app"; then
    installation_error
    printf '新应用暂存于：%s\n' "$staged_app" >&2
    exit 1
fi
if ! /bin/rmdir "$staging_dir"; then
    printf '提示：暂存目录未能清理：%s\n' "$staging_dir" >&2
fi

# 构建产物与安装应用共用 Bundle ID，只将正式安装路径注册为可启动应用。
launch_services='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$launch_services" -u "$built_app" >/dev/null 2>&1 || true
"$launch_services" -u "$staged_app" >/dev/null 2>&1 || true
if ! "$launch_services" -f "$installed_app"; then
    echo '错误：应用已安装，但系统应用注册失败，请重新运行安装脚本。' >&2
    exit 1
fi

# 证书稳定后，旧的官方版/临时签名授权仍不会自动迁移。
# 每张专用证书仅迁移一次；失败时不记录完成，允许下次重试。
migration_file="$HOME/Library/Application Support/Thaw/LocalSigning/permissions-migrated.sha1"
previous_migration=''
if [[ -f "$migration_file" ]]; then
    previous_migration="$(cat "$migration_file")"
fi
if [[ "$previous_migration" != "$signing_identity" ]]; then
    echo '正在迁移签名身份：仅清除 Thaw 的旧辅助功能和屏幕录制授权……'
    for permission_service in Accessibility ScreenCapture; do
        if ! /usr/bin/tccutil reset "$permission_service" com.stonerl.Thaw; then
            printf '错误：应用已安装，但旧权限迁移失败：%s。请以当前登录用户重新运行脚本。\n' "$permission_service" >&2
            exit 1
        fi
    done
    printf '%s\n' "$signing_identity" > "$migration_file"
    echo '旧授权已清除。请在系统设置中重新允许 Thaw 的辅助功能及所需的屏幕录制权限；以后安装不会重复清除。'
fi

if [[ "$launch_app" == true ]]; then
    open "$installed_app"
    echo '正在检查应用启动状态……'
    for ((attempt = 0; attempt < 5; attempt++)); do
        sleep 1
        if ! pgrep -u "$current_uid" -f '^/Applications/Thaw[.]app/Contents/MacOS/Thaw($| )' >/dev/null; then
            echo '错误：应用启动后退出，请检查 ~/Library/Logs/DiagnosticReports/ 中最新的 Thaw 崩溃报告。' >&2
            exit 1
        fi
    done
fi

printf '安装完成：%s\n' "$installed_app"
echo '首次运行请按引导授予辅助功能权限；屏幕录制权限为可选。'
echo '签名迁移后的首次运行需要重新授权；后续安装保持同一签名身份。'
