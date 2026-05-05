---
name: aws-cost
description: |
  AWS IaC(terraform/cloudformation/shell)로 띄울 환경의 사전 비용 견적과 현재 계정 활성
  리소스의 사후 감사. 프로비저닝 전후 비용 자각용 범용 도구. SessionStart 시 cwd가 IaC
  디렉토리거나 활성 리소스가 있으면 자동 1~2줄 알림.
  트리거 키워드: 비용 견적, estimate cost, audit aws, 활성 리소스, 리소스 점검,
  "이거 띄우면 얼마", "지금 떠있는 거 얼마", "infracost", "AWS 비용 확인".
---

# /aws-cost — AWS 비용 사전 견적 + 사후 감사

## Modes

| 모드 | 호출 | 동작 |
|------|------|------|
| `estimate` | `/aws-cost estimate [path]` | 디렉토리를 분류해 terraform이면 infracost로 정확 견적, 그 외면 LLM-fallback 절차로 견적. |
| `audit` | `/aws-cost audit` | 현재 인증된 AWS 계정에서 활성 리소스 인벤토리 + LaunchTime 기반 누적 추정 비용 + 삭제 권고 출력. |
| `watch` | `/aws-cost watch` (또는 SessionStart hook이 자동) | 캐시 + cwd 분류만 보고 0~2줄 요약. ≤3초. |

## How Claude should run each mode

### `estimate`

1. `lib/estimate.sh <path>`을 실행.
2. 출력이 `[LLM-FALLBACK]` 헤더로 시작하면 다음 4단계를 따라 견적을 직접 산출한다:
   1. 헤더 아래 출력된 "IaC 파일 목록"을 읽고 리소스 인벤토리(인스턴스 타입, 갯수, 옵션, 리전)를 추출.
   2. `prices/seoul-cheatsheet.json`을 우선 매칭 단가 소스로 사용. 키가 없으면 `aws pricing get-products --service-code <code> --filters ...`로 조회.
   3. 시간당 USD 합계를 계산한 뒤 `lib/format.sh hourly_table <USD/h>`로 1h/24h/1주/30일 표를 출력.
   4. 출력 마지막에 정확히 다음 disclaimer를 1줄 포함:
      `⚠️ 본 견적은 LLM 추론 + 단가 합산 결과이며 ±30% 오차 가능. 정확도가 필요하면 infracost 사용 권장.`
3. 출력이 infracost JSON 기반 표면 그대로 사용자에게 전달.

### `audit`

1. `lib/audit.sh`을 실행. 결과는 stdout으로 표 출력 + `cache/audit-<account_id>.json`에 캐시.
2. 일일 추정 > $5 또는 누적 > $20일 때 ⚠️ + 삭제 예시 명령이 자동 출력됨. 사용자가 직접 실행할지 결정.
3. AWS 호출 실패 시(자격증명 없음 등) 그대로 사용자에게 안내.

### `watch`

1. SessionStart hook이 자동 호출. 사용자 직접 호출 비권장.
2. 0~2줄 출력. cwd가 IaC 디렉토리(terraform/cloudformation/shell-iac)면 estimate 권장 라인, 활성 리소스 캐시가 있으면 audit 요약 라인.

## Examples (사용 시나리오, 학습 가정 없음)

1. **개인 인프라 프로비저닝 전**
   ```
   $ cd ~/infra/eks-cluster
   $ /aws-cost estimate
   → 24h $X / KRW Y. 진행 결정.
   ```
2. **외부 워크샵·샘플 IaC 띄우기 전**
   ```
   $ git clone <some-aws-sample> && cd <some-aws-sample>/terraform
   $ /aws-cost estimate
   → terraform이면 infracost로 정확 견적. 셸 install.sh면 LLM-fallback + ±30% disclaimer.
   ```
3. **임시 검증 환경 (GPU 인스턴스 등 단기)**
   ```
   $ /aws-cost estimate
   → "시간당 $X. 6시간 벤치마크면 약 $Y" 확인 후 실행 시간 제한.
   ```
4. **장기 잔존 리소스 점검**
   ```
   $ /aws-cost audit
   → 활성 리소스 N개, 일일 추정 $X. ⚠️ 누적 $Y 초과 항목에 삭제 명령 예시.
   ```
5. **세션 시작 자동 자각**
   ```
   (사용자가 새 세션을 열면 watch.sh가 자동 실행)
   [aws-cost] 📁 terraform: my-infra — /aws-cost estimate 실행 권장
   [aws-cost] ⚠️ 활성 리소스 7개, 일일 추정 $52 / KRW 73,360
   ```

## Required IAM (read-only only)

```
ec2:Describe*
eks:List*
eks:Describe*
rds:Describe*
elasticloadbalancing:Describe*
resource-explorer-2:Search       (선택)
resource-explorer-2:GetIndex     (선택)
pricing:GetProducts
pricing:DescribeServices
sts:GetCallerIdentity
```

`ce:*` 권한 **불필요** — 본 스킬은 Cost Explorer API를 호출하지 않는다(요청당 추가 과금 + AWS Budgets와 중복).

## Conventions

- **Region 기준**: `ap-northeast-2` (서울). `prices/seoul-cheatsheet.json`이 단가 소스. 다른 리전은 `aws pricing get-products`로 조회.
- **환율 가정**: 1400 KRW/USD 고정. 출력 footer에 명시. 환경변수 `KRW_PER_USD=<n>`로 override 가능.
- **출력 통화**: USD primary, KRW secondary 병기.
- **Read-only 약속**: 본 스킬은 어떤 모드에서도 `apply`, `destroy`, `delete`, `create-stack` 등 변경 명령을 호출하지 않는다. 삭제 권고는 명령 예시만 출력하고 사용자가 직접 실행한다.

## Files

```
~/.claude/skills/aws-cost/         # (또는 작업 디렉토리 symlink)
├── SKILL.md                       # 본 문서
├── watch.sh                       # SessionStart hook 진입점
├── lib/
│   ├── classify.sh                # 디렉토리 분류
│   ├── format.sh                  # USD/KRW 포매터
│   ├── pricing-lookup.sh          # cheatsheet 조회 helper
│   ├── audit.sh                   # 활성 리소스 인벤토리 + 누적 비용
│   ├── infracost-wrap.sh          # terraform plan + infracost breakdown
│   ├── estimate.sh                # mode dispatch
│   └── prompt-hint.sh             # UserPromptSubmit hook (위험 키워드 reminder)
├── prices/
│   └── seoul-cheatsheet.json      # ap-northeast-2 단가 (DRAFT, 사용자 검증 필요)
└── cache/                         # gitignored. audit/infracost 결과 캐시
```

## Hooks (settings.json)

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.claude/skills/aws-cost/watch.sh" }] }
    ],
    "UserPromptSubmit": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.claude/skills/aws-cost/lib/prompt-hint.sh" }] }
    ]
  }
}
```

차단형 hook은 의도적으로 미사용. 두 hook 모두 항상 `exit 0`.
