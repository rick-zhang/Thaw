#!/bin/bash
# 为 Thaw 初始化独立的本机签名身份；标准输出仅返回证书指纹。
set -euo pipefail
umask 077

identity_name='Thaw Local Development'
state_dir="$HOME/Library/Application Support/Thaw/LocalSigning"
fingerprint_file="$state_dir/certificate.sha1"
keychain="$(/usr/bin/security default-keychain -d user | /usr/bin/sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"

identities() {
    /usr/bin/security find-identity -v -p codesigning "$keychain" \
        | /usr/bin/awk -v name="\"$identity_name\"" 'index($0, name) { print $2 }'
}

if [[ -f "$fingerprint_file" ]]; then
    fingerprint="$(cat "$fingerprint_file")"
    if ! identities | /usr/bin/grep -Fxq "$fingerprint"; then
        echo '错误：固定的 Thaw 签名证书不可用，请检查钥匙串是否解锁、证书是否有效及私钥是否存在。不会自动换证书或退回临时签名。' >&2
        exit 1
    fi
    printf '%s\n' "$fingerprint"
    exit 0
fi

# 同名证书存在时只复用，不静默生成另一张证书。
if /usr/bin/security find-certificate -c "$identity_name" "$keychain" >/dev/null 2>&1; then
    fingerprint="$(identities)"
    if [[ ! "$fingerprint" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        echo '错误：Thaw 同名证书不可用或存在多个签名身份，请在钥匙串中检查私钥及代码签名信任设置。' >&2
        exit 1
    fi
else
    echo '首次安装：正在创建 Thaw 专用本地签名证书（有效期十年）……' >&2
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    mkdir -p "$project_root/build/local"
    temporary_dir="$(/usr/bin/mktemp -d "$project_root/build/local/signing.XXXXXX")"
    trap '/bin/rm -rf -- "$temporary_dir"' EXIT
    cat > "$temporary_dir/openssl.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = Thaw Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    /usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
        -config "$temporary_dir/openssl.cnf" \
        -keyout "$temporary_dir/key.pem" -out "$temporary_dir/certificate.pem" 2> "$temporary_dir/openssl.log" \
        || { echo '错误：生成 Thaw 本地证书失败。' >&2; exit 1; }
    # 私钥仅在权限为 0700 的临时目录中短暂停留，导入钥匙串后删除。
    package_password="$(/usr/bin/openssl rand -hex 24)"
    printf '%s\n' "$package_password" > "$temporary_dir/package-password"
    /usr/bin/openssl pkcs12 -export -name "$identity_name" \
        -inkey "$temporary_dir/key.pem" -in "$temporary_dir/certificate.pem" \
        -out "$temporary_dir/identity.p12" -passout "file:$temporary_dir/package-password"
    /usr/bin/security import "$temporary_dir/identity.p12" -k "$keychain" \
        -f pkcs12 -P "$package_password" -T /usr/bin/codesign >&2
    unset package_password
    # 仅为当前用户的代码签名用途设置信任，不添加系统级或 TLS 信任。
    /usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
        -k "$keychain" "$temporary_dir/certificate.pem"
    fingerprint="$(identities)"
    if [[ ! "$fingerprint" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        echo '错误：Thaw 证书已导入，但代码签名身份尚不可用。请在钥匙串中检查证书和私钥。' >&2
        exit 1
    fi
fi

mkdir -p "$state_dir"
printf '%s\n' "$fingerprint" > "$fingerprint_file"
printf '%s\n' "$fingerprint"
