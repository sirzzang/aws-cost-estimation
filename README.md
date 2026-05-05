# aws-cost — Claude Code skill

AWS IaC(terraform / CloudFormation / shell)로 띄울 환경의 **사전 비용 견적(estimate)** + 현재 계정의 **활성 리소스 사후 감사(audit)** + SessionStart 시 자동 1~2줄 알림(watch).

## Why this exists

IaC로 띄운 AWS 리소스를 destroy하지 못하고 잊어버려 누적 청구가 발생하는 패턴을 차단하기 위한 개인 도구. "프로비저닝 시점에 시간·일별 단가를 자각하지 못한다"는 점이 근본 원인이라 보고, 그걸 자동화로 자극하는 작은 스킬을 만들었습니다. 본 repo는 **개인 작업 기록**이며 누군가 널리 쓸 거라 기대하지 않습니다.

## Modes

| 모드 | 호출 | 용도 |
|------|------|------|
| `estimate` | `/aws-cost estimate [path]` | IaC 디렉토리 분류 → terraform이면 infracost로 정확 견적, 그 외는 LLM-fallback 절차로 견적 (±30% 오차 disclaimer 의무) |
| `audit` | `/aws-cost audit` | 현재 인증된 AWS 계정의 활성 리소스 인벤토리 + LaunchTime 기반 누적 추정 비용 + 삭제 권고 명령 예시 |
| `watch` | SessionStart hook이 자동 호출 | cwd가 IaC 디렉토리면 estimate 권장 1줄, 활성 리소스 캐시가 있으면 audit 1줄. 둘 다 없으면 silent. |

## Disclaimers (꼭 먼저 읽으세요)

1. **공개된 본 repo는 민감 정보 익명화 완료** — 사용자 식별자, AWS 계정 ID, 이메일, 절대경로 등 개인 정보 제거.
2. **`prices/seoul-cheatsheet.json`은 ap-northeast-2 기준 작성 시점 스냅샷이며 예시일 뿐**입니다. AWS 단가는 자주 변하고, 본 스냅샷은 작성자가 수동으로 채운 DRAFT 상태입니다. 다른 리전, GPU 인스턴스 군, Fargate 단가는 특히 빠르게 변하므로 그대로 신뢰하지 마세요. 정확한 단가가 필요하면 `aws pricing get-products` 또는 [infracost](https://www.infracost.io)를 사용하세요.
3. **목적은 "대략 파악"**입니다. ±15~30% 오차를 가정하고 의사결정 보조 도구로만 쓰세요. 실제 청구액은 AWS Budgets / Cost Explorer 콘솔이 ground truth입니다. 본 도구는 비용 사고를 **막기 위한 인지 자극**이지 회계 도구가 아닙니다.

## Install

```bash
# 1) ~/.claude/skills 아래로 clone
git clone https://github.com/sirzzang/aws-cost-estimation.git ~/.claude/skills/aws-cost

# 2) (선택) IDE 진입 편의용 역방향 symlink
ln -s ~/.claude/skills/aws-cost ~/projects/aws-cost-skill

# 3) (선택) SessionStart + UserPromptSubmit hook 등록
#    ~/.claude/settings.json의 hooks 키 아래에 다음 두 항목을 추가:
#    "SessionStart":     [{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/skills/aws-cost/watch.sh"}]}]
#    "UserPromptSubmit": [{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/skills/aws-cost/lib/prompt-hint.sh"}]}]
```

### 의존성

| 도구 | 필수 여부 | 용도 |
|------|-----------|------|
| `bash` 4+, `jq`, `python3` | 필수 | 모든 스크립트 |
| `aws` CLI (configured) | audit 모드 | read-only describe/list 호출 |
| `terraform` | estimate terraform path | `terraform plan -refresh=false -backend=false` |
| `infracost` | 권장 (없어도 동작) | terraform 정확 견적. 미설치 시 LLM fallback. |

## Examples

### 1) 아무 디렉토리에서 그냥 `/aws-cost`

watch는 출력이 없고(IaC 신호 없음 + 활성 리소스 캐시 없음), Claude가 모드를 선택하라고 안내합니다.

```
❯ /aws-cost

⏺ Bash($HOME/.claude/skills/aws-cost/watch.sh)
  ⎿  (No output)

watch 모드는 출력이 없네요 — 현재 디렉토리가 IaC 디렉토리가 아니고 활성 리소스 감사
캐시도 없는 상태입니다.

어떤 모드를 실행할까요?
  estimate  /aws-cost estimate [경로]   IaC 비용 사전 견적
  audit     /aws-cost audit             활성 리소스 + 누적 추정 + 삭제 권고
```

### 2) Terraform 디렉토리에서 `/aws-cost estimate .`

EKS + GPU 노드 그룹이 있는 IaC 디렉토리에서 호출. infracost가 미설치 환경이라 LLM-fallback 절차가 동작 → 디렉토리 IaC 파일을 읽고 `var.tf` default 값으로 idle/실습 두 시나리오를 분리 견적합니다.

```
⏺ /aws-cost estimate — <some-iac-dir>/ Terraform 견적
  환율 가정: 1 USD = 1,400 KRW · 리전: ap-northeast-2

  리소스 인벤토리 (var.tf defaults)
  ┌──────────────────────┬────────────────────────────┬────────────┬────────┐
  │       구성요소       │           수량              │ 단가 USD/h │  소계  │
  ├──────────────────────┼────────────────────────────┼────────────┼────────┤
  │ EKS Control Plane    │ × 1                         │ 0.10       │ 0.1000 │
  │ System NG (primary)  │ t3.medium × 2               │ 0.0512     │ 0.1024 │
  │ System NG EBS        │ gp3 30 GiB × 2              │ 0.0912/GB월│ 0.0075 │
  │ GPU NG (실습 중)      │ g5.xlarge × 2              │ 1.408      │ 2.8160 │
  │ GPU NG EBS           │ gp3 100 GiB × 2             │ 0.0912/GB월│ 0.0250 │
  │ NAT Gateway          │ single-NAT × 1              │ 0.059      │ 0.0590 │
  └──────────────────────┴────────────────────────────┴────────────┴────────┘

  (A) Idle baseline — gpu_desired_size=0
  ── 시간당   USD $0.27 / KRW 376
  ── 24h     USD $6.45 / KRW 9,035
  ── 1주     USD $45.18 / KRW 63,245
  ── 30일    USD $193.61 / KRW 271,051

  (B) GPU 실습 운용 — desired=2 (g5.xlarge × 2)
  ── 시간당   USD $3.11 / KRW 4,354
  ── 24h     USD $74.64 / KRW 104,492
  ── 1주     USD $522.46 / KRW 731,446
  ── 30일    USD $2239.12 / KRW 3,134,769

  ⚠️ 본 견적은 LLM 추론 + 단가 합산 결과이며 ±30% 오차 가능. 정확도가 필요하면 infracost 사용 권장.
```

> 위 단가표는 **예시이며 작성 시점 스냅샷**입니다. 본인 환경 시점의 실제 단가는 `aws pricing get-products` 또는 infracost로 재확인하세요.

### 3) `/aws-cost audit` — 활성 리소스 0건 케이스

destroy를 잘 마친 직후나 잔존 리소스가 없는 상태에서의 정상 출력. 이 라인이 보이는 게 안전 신호입니다.

```
❯ /aws-cost audit

⏺ Bash(~/.claude/skills/aws-cost/lib/audit.sh)
  ⎿  💰 Account 123456789012 — region ap-northeast-2 — as of 2026-05-05T04:05:46Z
     활성 리소스 0개  /  일일 추정 USD $0.00 / KRW 0  /  누적 추정 USD $0.00 / KRW 0
     ───────────────────────────

⏺ AWS 비용 감사 결과
  계정: 123456789012 (ap-northeast-2 / 서울)
  기준 시각: 2026-05-05T04:05:46Z

  ┌─────────────┬────────────┐
  │    항목     │     값     │
  ├─────────────┼────────────┤
  │ 활성 리소스 │ 0개        │
  │ 일일 추정   │ $0.00 / ₩0 │
  │ 누적 추정   │ $0.00 / ₩0 │
  └─────────────┴────────────┘

  서울 리전에 떠있는 비용 발생 리소스가 없습니다. 정리할 항목 없음. (환율 1,400 KRW/USD 가정)

  ▎ 참고: 이 감사는 ap-northeast-2 단일 리전 기준입니다. 다른 리전(us-east-1 등)에 잔존 리소스가
  ▎ 있을 수 있다면 해당 리전에서 별도 확인이 필요합니다.
```

> audit은 단일 리전 기준이라는 점에 주의. 환경변수 `AWS_REGION` 또는 `AWS_DEFAULT_REGION`로 다른 리전을 지정해서 추가 호출할 수 있습니다.

## Required IAM (read-only)

```
ec2:Describe*
eks:List*, eks:Describe*
rds:Describe*
elasticloadbalancing:Describe*
resource-explorer-2:Search       (optional)
resource-explorer-2:GetIndex     (optional)
pricing:GetProducts
pricing:DescribeServices
sts:GetCallerIdentity
```

`ce:*` 권한은 **사용하지 않습니다**. Cost Explorer API는 호출당 $0.01 추가 과금이고, 동일한 가시화는 AWS Budgets로 가능하기 때문에 의도적으로 제외했습니다.

## Limitations

- **Terraform 외(CFN/shell)는 LLM-fallback 절차**로 동작합니다. Claude가 IaC 파일을 읽고 단가를 합산하므로 ±30% 오차 가능. disclaimer가 자동 표기됩니다.
- `terraform plan`이 외부 backend(S3, Terraform Cloud 등)를 강제 요구하는 환경에서는 `-backend=false`로 init이 실패할 수 있고, 그 경우 LLM-fallback로 자동 전환됩니다.
- **시간 단가 기반**입니다. Spot, Reserved, Savings Plan, 데이터 전송 비용은 반영되지 않습니다.
- 환율은 `1400 KRW/USD`로 고정. 환경변수 `KRW_PER_USD=<n>`로 override 가능.
- 단가표는 `ap-northeast-2` 기준만 들어 있습니다. 다른 리전은 `aws pricing get-products`로 fallback 조회.
- 본 도구는 실제 청구액을 보여주지 않습니다(`ce:*` 미사용). 실제 청구는 AWS Budgets / Cost Explorer 콘솔에서 확인하세요.
- watch hook은 항상 `exit 0`이고 3초 hard timeout이 있어 세션 시작을 차단하지 않습니다.

## Files

```
~/.claude/skills/aws-cost/
├── SKILL.md                     # frontmatter + 3 모드 + Examples + Required IAM
├── watch.sh                     # SessionStart hook 진입점
├── lib/
│   ├── classify.sh              # IaC 디렉토리 분류
│   ├── format.sh                # USD/KRW 포매터 + hourly_table
│   ├── pricing-lookup.sh        # cheatsheet 조회 helper
│   ├── audit.sh                 # 활성 리소스 인벤토리 + 누적 비용
│   ├── infracost-wrap.sh        # terraform plan + infracost breakdown
│   ├── estimate.sh              # 모드 dispatch (terraform / LLM-fallback)
│   └── prompt-hint.sh           # UserPromptSubmit hook (위험 키워드 reminder)
├── prices/
│   └── seoul-cheatsheet.json    # ap-northeast-2 단가 스냅샷 (DRAFT, 예시)
└── samples/
    └── fixtures/                # classify regression 픽스처
```

## License

MIT (홀더: sirzzang). 자세한 내용은 [LICENSE](LICENSE) 참조. 본 코드는 **as-is**로 제공되며 작성자는 본 도구 사용으로 인한 어떠한 비용·손실에 대해서도 책임지지 않습니다.

## 작성 노트

본 스킬은 Claude Code(Opus 4.7) `oh-my-claudecode:plan` + `oh-my-claudecode:ralph` 워크플로우로 PRD-driven 자동 작성된 결과입니다. 단가표는 LLM이 작성한 수동 스냅샷이라 검증되지 않은 값이 포함될 수 있습니다.
