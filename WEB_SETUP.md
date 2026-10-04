# 웹 export와 GitHub Pages 배포

실제 적용값의 기준은 **`export_presets.cfg`(Web 프리셋)와 `project.godot`** 두 파일입니다.
이 문서는 값을 다시 정의하지 않고, 핵심 값은 `tools/check_web_export.sh`가 생성된 `index.html`에서 검사합니다.

핵심 계약 (값은 `export_presets.cfg` 참고):

- `platform="Web"`, 단일 스레드(`variant/thread_support=false`), GDExtension 없음(`variant/extensions_support=false`)
- 커스텀 셸 `res://web/shell.html`, 캔버스 크기 정책 Adaptive(`html/canvas_resize_policy=2`)
- PWA·서비스워커 끔, cross-origin isolation 헤더 강제 끔 → SharedArrayBuffer 없이 GitHub Pages에서 시작
- 출력 `builds/web/index.html` (+ `index.js`, `index.wasm`, `index.pck` 등 — export 후 이름을 바꾸지 말고 함께 배포)
- 렌더러 Compatibility(`project.godot`). 모바일용 VRAM 텍스처 압축(ETC2/ASTC)은 쓰지 않으므로 export와 import 설정 모두 꺼져 있습니다.
  켜려면 `vram_texture_compression/for_mobile`과 `project.godot`의 `rendering/textures/vram_compression/import_etc2_astc`를 **함께** 켜세요.

## 1. 엔진과 템플릿 (로컬)

Godot 4.5.1 Standard와 같은 버전의 export templates가 필요합니다. 웹 단일 스레드 템플릿만 있으면 됩니다.

```bash
V=4.5.1
curl -fLO https://github.com/godotengine/godot/releases/download/$V-stable/Godot_v$V-stable_linux.x86_64.zip
curl -fLO https://github.com/godotengine/godot/releases/download/$V-stable/Godot_v$V-stable_export_templates.tpz
unzip Godot_v$V-stable_linux.x86_64.zip
mkdir -p ~/.local/share/godot/export_templates/$V.stable
unzip -j Godot_v$V-stable_export_templates.tpz 'templates/web_nothreads_*' 'templates/version.txt' \
  -d ~/.local/share/godot/export_templates/$V.stable
```

Windows는 에디터의 *편집기 → Export 템플릿 관리*에서 4.5.1을 설치해도 됩니다(`%APPDATA%\Godot\export_templates\4.5.1.stable`).
엔진 실행 파일·템플릿·`.tpz`는 저장소에 넣지 않습니다(`.gitignore`).

## 2. 로컬 빌드와 확인

```bash
GODOT=/path/to/godot tools/build_web.sh   # import → --smoke-test → Web export → 정적 검사
python3 tools/serve_web.py                # http://localhost:8060/midnight-cat-delivery/
```

- `serve_web.py`는 GitHub Pages처럼 `/<저장소 이름>/` 하위 경로로만 제공합니다(`--prefix`로 변경). 루트(`/index.wasm`)는 404이므로 절대경로 문제를 바로 알 수 있습니다.
- `index.html`을 더블클릭(file://)하면 셸이 “HTTP 서버로 열어 달라”는 안내를 보여 줍니다.
- 생성된 `builds/web/index.html`을 직접 고치지 말고 `web/shell.html`을 고친 뒤 다시 export하세요.
  셸은 4.5.1의 `$GODOT_URL`, `$GODOT_CONFIG`, `$GODOT_HEAD_INCLUDE`, `$GODOT_THREADS_ENABLED`, `$GODOT_PROJECT_NAME`을 씁니다.
  4.5.1이 만드는 config 객체에는 `threads` 키가 없으므로 기능 검사는 `Engine.getMissingFeatures({ threads: GODOT_THREADS_ENABLED })`로 하며, 생성 HTML에서 `GODOT_THREADS_ENABLED = false`인지 검사 스크립트가 확인합니다.

## 3. GitHub Pages 배포

워크플로: `.github/workflows/pages.yml`

- 트리거: `main` push 또는 수동 실행(workflow_dispatch). deploy 잡은 `refs/heads/main`에서만 실행되며 다른 브랜치·PR에서는 배포되지 않습니다.
- build 잡(`contents: read`): Godot 4.5.1과 같은 버전의 Web 템플릿 설치(캐시) → 버전 일치 확인 → `tools/build_web.sh` → `builds/web` 업로드.
- deploy 잡(`pages: write`, `id-token: write`): build 성공 후 `github-pages` 환경에 배포하고 실제 URL을 출력합니다.
- 토큰을 코드에 넣지 않습니다. GitHub가 제공하는 OIDC 인증만 씁니다.

처음 한 번 저장소에서 설정:

1. GitHub 저장소 → **Settings → Pages**
2. **Build and deployment → Source**를 **GitHub Actions**로 선택
3. `main`에 push하거나 **Actions → “Web build & GitHub Pages” → Run workflow**
4. 완료되면 deploy 잡 요약과 `github-pages` 환경에 URL이 표시됩니다. 보통 `https://<사용자>.github.io/<저장소>/` 형식입니다.

배포 후 확인: 위 URL을 HTTPS로 열어 시작 → 이동/점프 → 편지 → 배달까지 해 보고, 개발자 도구 Network 탭에서 404가 없는지 봅니다.
`?qa=1`을 붙이면 `window.mcdQA`로 읽기 전용 상태를 볼 수 있어 `tools/browser_test.cjs`를 배포 URL에 그대로 돌릴 수 있습니다:
`NODE_PATH="$(npm root -g)" node tools/browser_test.cjs https://<사용자>.github.io/<저장소>/`

## 문제 해결

| 증상 | 확인 |
| --- | --- |
| 검은 화면 / “게임 엔진 파일을 불러오지 못했습니다” | `index.js`·`index.wasm`·`index.pck`가 같은 폴더에 함께 올라갔는지, 이름이 export 그대로인지 |
| 필요한 기능이 없다는 오류 | WebGL 2를 지원하는 최신 브라우저인지(하드웨어 가속 꺼짐 포함) |
| 로컬에서만 실패 | file://로 연 것은 아닌지, `.wasm`이 `application/wasm`으로 제공되는지(`serve_web.py`는 설정됨) |
| 배포가 안 됨 | Settings → Pages의 Source가 GitHub Actions인지, `github-pages` 환경 보호 규칙이 `main`을 허용하는지 |
