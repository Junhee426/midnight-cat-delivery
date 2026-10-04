# Midnight Cat Delivery

치즈와 턱시도, 두 고양이가 밤의 골목에서 편지를 배달하는 3D 게임입니다.
Godot 4.5.1 (Standard, GDScript) · Compatibility 렌더러 · WebGL 2 / WebAssembly 단일 스레드 웹 빌드.

첫 번째 골목에서 **편지 수령 → 낮은 상자 → 담장 → 실외기 → 좁은 난간 → 간판 → 302호 창턱 → 편지 전달**까지
실제 충돌체 위를 걷고 충전 점프로 이동해 배달 1건을 완료할 수 있습니다. 전달하면 창턱에 편지가 놓이고 302호 창문에 불이 켜집니다.

## 조작

| 동작 | PC 키보드·마우스 | 게임패드 | 휴대폰(가로) |
| --- | --- | --- | --- |
| 이동 | WASD / 방향키 | 왼쪽 스틱 | 왼쪽 아래 이동 스틱 |
| 달리기 | Shift | LB | RUN (켜기/끄기) |
| 점프 | Space 누르기 → 웅크려 충전 → 떼기 | A | JUMP 누르고 있다가 떼기 |
| 편지 받기/전달 | E | X | LETTER |
| 고양이 교체 | Tab | Y | CAT |
| 길 안내 (다음 발판 표시) | Q | RB | ROUTE |
| 마지막 안전 지점으로 | R | Back | – |
| 일시정지 | Esc / 화면의 일시정지 버튼 | Start | 일시정지 버튼 |
| 시점 | 게임 화면 클릭 후 마우스, 또는 오른쪽 버튼 드래그 | 오른쪽 스틱 | 오른쪽 빈 곳 드래그 |

- 웹에서는 시작 직후 마우스를 자동으로 잡지 않습니다. 게임 화면을 클릭할 때만 포인터를 고정하고, Esc로 풀리면 일시정지되며 스스로 다시 잡지 않습니다.
- 창/탭 포커스를 잃으면 일시정지하고 이동·점프·질주 입력을 모두 해제합니다.
- 떨어지면(골목 끝 난간 너머) 마지막으로 밟은 발판(안전 지점)으로 돌아오고, 물고 있던 편지도 그대로 유지됩니다.
- ROUTE/Q는 다음 목표 지점을 잠시 표시하는 임시 길 안내 기능입니다(냄새·청각 시뮬레이션이 아님).

## 실행

필요: Godot **4.5.1** (Standard). 웹 빌드에는 같은 버전의 export templates가 필요합니다([WEB_SETUP.md](WEB_SETUP.md)).

```bash
# 에디터에서 열기 (F5로 실행)
godot --path . -e

# 엔진 내 자동 검사: 실제 입력으로 전체 동선을 통과하고 배달까지 확인 (실패 시 exit 1)
godot --headless --path . --import
godot --headless --path . --fixed-fps 60 --disable-vsync -- --smoke-test

# import → 자동 검사 → Web export → export 정적 검사 (CI와 같은 명령)
GODOT=godot tools/build_web.sh

# GitHub Pages와 같은 하위 경로로 로컬 실행 → http://localhost:8060/midnight-cat-delivery/
python3 tools/serve_web.py
```

`index.html`을 파일로 직접 여는 방식(file://)은 동작하지 않습니다. 반드시 HTTP 서버(로컬) 또는 HTTPS(배포)로 여세요.

실제 브라우저 검사(개발용, Node + Playwright 필요):

```bash
python3 tools/serve_web.py &
NODE_PATH="$(npm root -g)" node tools/browser_test.cjs      # 결과·스크린샷: builds/qa/
```

`?qa=1`을 붙이면 브라우저 검사용 읽기 전용 상태(`window.mcdQA`)만 추가로 공개됩니다. 게임 상태를 바꾸거나 동작을 대신하지 않습니다.

## 구조

| 파일 | 역할 |
| --- | --- |
| `project.godot` | 프로젝트 설정 (Compatibility 렌더러, 입력 맵, 터치→마우스 변환 끔) |
| `scenes/main.tscn` | 시작 장면 (`scripts/world.gd`) |
| `scripts/world.gd` | 골목·발판·편지/302호·체크포인트·추락 복귀·게임 흐름·포커스 처리·`?qa=1` 진단 |
| `scripts/player.gd` | `CharacterBody3D` 이동, 충전 점프(코요테 타임·점프 버퍼), SpringArm 3인칭 카메라, 바닥 그림자 |
| `scripts/cat_visual.gd` | 치즈/턱시도 절차적 메시와 애니메이션 (컨트롤러와 분리) |
| `scripts/touch_controls.gd` | 멀티터치: 이동 스틱, 카메라 드래그, JUMP/LETTER/CAT/ROUTE/RUN |
| `scripts/hud.gd` | HUD·일시정지·홈·완료·세로 화면 안내 (PC·웹·터치 공용) |
| `scripts/qa/smoke_test.gd` | `--smoke-test` 엔진 검사 (웹 export에서는 제외) |
| `export_presets.cfg` | Web 프리셋 (단일 스레드, PWA 끔, `builds/web/index.html`) |
| `web/shell.html` | 웹 시작·로딩·오류 화면 |
| `.github/workflows/pages.yml` | 웹 빌드·Pages 배포 |
| `tools/` | 빌드/검사/로컬 서버/입력 맵/폰트 서브셋 스크립트 |

### 캐릭터 표시 교체

`player.gd`는 `CatVisual`의 `set_kind()`, `set_motion()`, `set_carrying()`, `play_land()`만 호출합니다.
리깅된 GLB + `AnimationTree`로 바꿀 때는 같은 메서드를 가진 노드로 `cat_visual.gd`를 대체하면 됩니다.
현재 고양이는 참고 이미지를 바탕으로 색·무늬·비율을 맞춘 **임시 절차적 메시**이며, 디자인을 정확히 재현한 모델은 아닙니다.

### 폰트

HUD 한글은 NanumGothic Bold(SIL OFL 1.1, `assets/fonts/OFL.txt`)의 서브셋입니다. UI 문구에 새 글자를 추가하면
`python3 tools/subset_font.py <NanumGothic-Bold.ttf 경로>`로 다시 만드세요. 빠진 글자가 있으면 스모크 테스트가 실패합니다.

문서: [WEB_SETUP.md](WEB_SETUP.md) (웹 export·Pages 배포) · [VALIDATION.md](VALIDATION.md) (수행한 검사와 미검증 항목)
