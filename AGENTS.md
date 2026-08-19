# 에이전트 작업 지침

## Git 커밋 규칙

- 사용자의 명시적인 승인 없이 `git commit`을 만들지 않는다.
- 커밋하기 전에 staged 파일 목록과 제안 커밋 메시지를 먼저 보여준다.
- 사용자가 커밋 메시지를 확인하거나 수정할 기회를 준다.
- 명시적인 요청 없이 브랜치 push, commit amend, force push를 하지 않는다.

## 커밋 메시지 형식

- 커밋 메시지는 소문자 conventional commit 형식을 사용한다.

```text
type: short description
```

- 허용하는 커밋 타입:
  - `feat`: 새 기능
  - `fix`: 버그 수정
  - `docs`: 문서 변경
  - `style`: 포맷팅만 변경
  - `refactor`: 기능 추가나 버그 수정이 아닌 코드 구조 개선
  - `test`: 테스트 추가 또는 수정
  - `chore`: 빌드, 도구, 의존성, 기타 유지보수 작업

- 예시:

```text
fix: avoid macos 26 window sizing crash
feat: add model setup progress state
docs: document local app launch steps
chore: update build script
```

- 타입은 항상 소문자로 작성한다.
- 설명은 짧고 명확하게 작성한다.
- 콜론 뒤 설명의 첫 단어도 고유명사가 아니라면 소문자로 작성한다.
