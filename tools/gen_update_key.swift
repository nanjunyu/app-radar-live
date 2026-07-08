import Foundation
import CryptoKit

// 生成 App 自动更新用的 Ed25519 密钥对（只需运行一次）
// 用法: swift tools/gen_update_key.swift
//
// 输出：
//   - update_private_key.pem  （Base64 私钥，务必保密，勿提交到仓库）
//   - 终端打印公钥 Base64（复制到 AppUpdater.swift 的 publicKeyBase64）

let privateKey = Curve25519.Signing.PrivateKey()
let publicKey = privateKey.publicKey

let privB64 = privateKey.rawRepresentation.base64EncodedString()
let pubB64 = publicKey.rawRepresentation.base64EncodedString()

// 私钥写入本地文件（已在 .gitignore 中忽略）
let privPath = "update_private_key.pem"
try? privB64.write(toFile: privPath, atomically: true, encoding: .utf8)

print("========================================")
print("✅ Ed25519 密钥对已生成")
print("========================================")
print("")
print("🔒 私钥已保存到: \(privPath)")
print("   （已被 .gitignore 忽略，请勿提交或泄露；建议额外备份到密码管理器）")
print("")
print("🔑 公钥 Base64（复制到 Sources/Core/AppUpdater.swift 的 publicKeyBase64）：")
print("")
print(pubB64)
print("")
print("========================================")
