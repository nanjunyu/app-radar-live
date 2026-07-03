import Foundation

// 简易翻译：用 Google Translate 免费网页接口把英文翻成中文。
// 适合短文本（README 摘要、changelog）按需翻译，不适合大批量。
enum Translator {
    static func toZh(_ text: String, completion: @escaping (String) -> Void) {
        guard !text.isEmpty else { completion(text); return }
        // 截取前 1500 字符以内（接口对单次有长度限制）
        let input = String(text.prefix(1500))
        let encoded = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=zh-CN&dt=t&q=\(encoded)"
        guard let url = URL(string: urlStr) else { completion(text); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = json.first as? [Any] else {
                completion(text); return
            }
            var result = ""
            for s in sentences {
                if let arr = s as? [Any], let translated = arr.first as? String {
                    result += translated
                }
            }
            completion(result.isEmpty ? text : result)
        }.resume()
    }
}
