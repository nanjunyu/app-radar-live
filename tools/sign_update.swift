import Foundation
import CryptoKit

// 用 Ed25519 私钥对文件内容签名，输出 Base64 签名到 stdout
// 用法: swift tools/sign_update.swift <私钥文件> <待签名文件>

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: sign_update.swift <private_key.pem> <file>\n".data(using: .utf8)!)
    exit(1)
}

let keyPath = args[1]
let filePath = args[2]

guard let keyB64 = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      let keyData = Data(base64Encoded: keyB64),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write("error: 无法读取或解析私钥\n".data(using: .utf8)!)
    exit(1)
}

guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
    FileHandle.standardError.write("error: 无法读取待签名文件\n".data(using: .utf8)!)
    exit(1)
}

guard let signature = try? privateKey.signature(for: fileData) else {
    FileHandle.standardError.write("error: 签名失败\n".data(using: .utf8)!)
    exit(1)
}

// 只输出 Base64 签名（无换行），方便脚本捕获
FileHandle.standardOutput.write(signature.base64EncodedString().data(using: .utf8)!)
