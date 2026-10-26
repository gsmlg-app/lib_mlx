import Foundation
import CryptoKit

struct ModelAssetManifest: Codable, Equatable {
    struct Quantization: Codable, Equatable { let bits: Int; let group_size: Int; let mode: String }
    struct File: Codable, Equatable {
        let path: String
        let size: Int
        let sha256: String?
        let git_blob_sha1: String?
    }
    let repository: String
    let revision: String
    let quantization: Quantization
    let files: [File]
}

enum ModelAssets {
    static func validate(config: MlxModelConfig) throws -> URL {
        let directory = URL(fileURLWithPath: config.modelPath, isDirectory: true)
        let decoder = JSONDecoder()
        let expected = try decoder.decode(ModelAssetManifest.self, from: Data(contentsOf: Bundle.module.url(forResource: "model-lock", withExtension: "json")!))
        let manifestURL = directory.appendingPathComponent("lib_mlx-model.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let supplied = try? decoder.decode(ModelAssetManifest.self, from: manifestData), supplied == expected else {
            throw MlxCoreError("invalid_model_assets", "Missing or mismatched lib_mlx-model.json; recover the pinned snapshot with tool/fetch_model.py.")
        }
        for asset in expected.files {
            try Task.checkCancellation()
            let fileURL = directory.appendingPathComponent(asset.path)
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.fileSize == asset.size else {
                throw MlxCoreError("invalid_model_assets", "Missing or truncated model asset: \(asset.path).")
            }
            let source = try FileHandle(forReadingFrom: fileURL)
            defer { try? source.close() }
            var sha256 = SHA256()
            var sha1 = Insecure.SHA1()
            if asset.git_blob_sha1 != nil { sha1.update(data: Data("blob \(asset.size)\0".utf8)) }
            while let data = try source.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                if asset.sha256 != nil { sha256.update(data: data) } else { sha1.update(data: data) }
            }
            let digest = asset.sha256 != nil ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
                : sha1.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == (asset.sha256 ?? asset.git_blob_sha1) else {
                throw MlxCoreError("invalid_model_assets", "Checksum mismatch for model asset: \(asset.path).")
            }
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        let text = json?["text_config"] as? [String: Any]
        let quantization = json?["quantization"] as? [String: Any]
        guard json?["model_type"] as? String == "gemma4", text?["num_hidden_layers"] as? Int == 35,
              text?["num_kv_shared_layers"] as? Int == 20, text?["max_position_embeddings"] as? Int == 131_072,
              quantization?["bits"] as? Int == 4, quantization?["group_size"] as? Int == 64 else {
            throw MlxCoreError("invalid_model_assets", "Expected Gemma 4 E2B with 4-bit affine group-size-64 weights.")
        }
        return directory
    }
}
