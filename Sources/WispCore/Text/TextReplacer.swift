import Foundation

/// 전사 후·출력 전에 적용하는 결정적 단어 교체 규칙.
/// LLM 후처리와 달리 입력→출력이 항상 같아 고유명사·약어·일관 철자를 보장한다.
public struct ReplacementRule: Codable, Equatable, Identifiable {
    public var id: UUID
    /// 찾을 문자열(리터럴, 정규식 아님).
    public var from: String
    /// 바꿀 문자열.
    public var to: String
    /// 기본 false — 대소문자를 무시하고 매칭한다.
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), from: String, to: String, caseSensitive: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.caseSensitive = caseSensitive
    }
}

/// 규칙 목록을 순서대로 적용하는 순수 치환기. 시스템 의존이 없어 단위 테스트가 쉽다.
public enum TextReplacer {
    /// rules를 위에서부터 차례로 적용한다. 빈 `from`은 건너뛴다(전체 텍스트가
    /// 빈 문자열 사이마다 끼어드는 사고 방지). 앞 규칙의 결과에 뒤 규칙이 다시 적용된다.
    public static func apply(_ text: String, rules: [ReplacementRule]) -> String {
        var result = text
        for rule in rules where !rule.from.isEmpty {
            let options: String.CompareOptions = rule.caseSensitive ? [] : [.caseInsensitive]
            result = result.replacingOccurrences(of: rule.from, with: rule.to, options: options)
        }
        return result
    }
}
