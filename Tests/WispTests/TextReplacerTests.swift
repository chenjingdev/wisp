import Foundation
@testable import WispCore

@MainActor
func textReplacerTests(_ t: TestRunner) async {
    await t.test("TextReplacer: 규칙 없으면 원문 그대로") {
        try expectEqual(TextReplacer.apply("hello world", rules: []), "hello world")
    }

    await t.test("TextReplacer: 기본은 대소문자 무시 치환") {
        let rules = [ReplacementRule(from: "github", to: "GitHub")]
        try expectEqual(TextReplacer.apply("Github와 GITHUB", rules: rules), "GitHub와 GitHub")
    }

    await t.test("TextReplacer: caseSensitive=true면 정확히 일치만") {
        let rules = [ReplacementRule(from: "Cat", to: "Dog", caseSensitive: true)]
        try expectEqual(TextReplacer.apply("Cat cat CAT", rules: rules), "Dog cat CAT")
    }

    await t.test("TextReplacer: 빈 from은 건너뜀") {
        let rules = [ReplacementRule(from: "", to: "X")]
        try expectEqual(TextReplacer.apply("그대로", rules: rules), "그대로")
    }

    await t.test("TextReplacer: 여러 규칙을 순서대로 적용 (앞 결과에 뒤가 다시 적용)") {
        let rules = [
            ReplacementRule(from: "a", to: "b"),
            ReplacementRule(from: "b", to: "c"),
        ]
        // "a"→"b"→"c" : 첫 규칙이 만든 b에도 둘째 규칙이 적용된다
        try expectEqual(TextReplacer.apply("a", rules: rules), "c")
    }

    await t.test("TextReplacer: 한글·기호 치환") {
        let rules = [
            ReplacementRule(from: "위스퍼", to: "Wisp"),
            ReplacementRule(from: "->", to: "→"),
        ]
        try expectEqual(TextReplacer.apply("위스퍼 -> 완성", rules: rules), "Wisp → 완성")
    }
}
