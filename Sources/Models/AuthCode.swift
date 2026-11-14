import Foundation

/// 授权码格式工具：与后台 / scripts/gen-code.sh / Android 的 AuthCode 同一套规则。
///
/// 新格式（2026-11 起）：25 个字符、5 组 × 5 位、连字符分隔 ——
/// `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`
/// 字符集 24 个（Windows 产品密钥同款，刻意排除易混字符）：
/// `2 3 4 6 7 8 9  B C D F G H J K M P Q R T V W X Y`
/// 不使用 0 1 5 A E I L N O S U Z。
///
/// 历史 8~16 位短码仍可校验：归一化后长度不是 25 就原样交给服务端
/// （服务端 enroll 同样归一化，两端行为一致）。
enum AuthCode {
    static let alphabet = "2346789BCDFGHJKMPQRTVWXY"
    static let bodyLen = 25                 // 5 组 × 5 位

    /// 归一：去掉空格/连字符等所有非字母数字、转大写；25 位按 5 位一组补连字符
    static func normalize(_ raw: String?) -> String {
        guard let raw else { return "" }
        let text = raw.map { $0 }.filter { $0.isLetter || $0.isNumber }
            .map { $0.uppercased() }.joined()
        guard text.count == bodyLen else { return text }
        let chars = Array(text)
        var groups: [String] = []
        var i = 0
        while i < chars.count {
            groups.append(String(chars[i..<min(i + 5, chars.count)]))
            i += 5
        }
        return groups.joined(separator: "-")
    }

    /// 输入校验：nil = 合法；否则是给用户看的错误文案
    static func validate(_ raw: String?) -> String? {
        let norm = normalize(raw)
        if norm.isEmpty { return "请输入授权码" }
        if norm.count == 29 {
            for ch in norm where ch != "-" {
                if !alphabet.contains(ch) {
                    return "含无效字符 \(ch)（不使用 0 1 5 A E I L N O S U Z）"
                }
            }
            return nil
        }
        if norm.count >= 4 && norm.count <= 16 { return nil }   // 旧格式
        return "授权码长度不对：新码 25 位，或旧码 8~16 位"
    }
}
