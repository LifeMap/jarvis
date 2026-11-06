# Jarvis Admin

Phase 7 single-user control center. Requires Node.js 22.11 or newer.

```bash
cp .env.example .env.local
npm install
npm run dev
```

The Admin console is available at `http://127.0.0.1:5174`. Port 5174 is fixed so it does not
collide with the existing Web Playground on port 5173. The API must be running separately on the
`API_ORIGIN` address (port 8787 by default).

`VITE_API_BASE_URL` defaults to `/api`. During local development, Vite proxies `/api` to
`API_ORIGIN` and injects the server-only `JARVIS_API_TOKEN`; the token is not bundled into browser
JavaScript. For Cloudflare Pages, `functions/api/[[path]].ts` provides the equivalent server-side
proxy. Configure `JARVIS_API_ORIGIN` as a Pages environment variable and `JARVIS_API_TOKEN` as a
Pages Secret. Protect the whole Admin application with Cloudflare Access; the API Bearer token
remains defense in depth.

`VITE_PLAYGROUND_URL` can point the Playground navigation item to the deployed `web/` application.
API keys and OAuth tokens are never managed from Admin.

## Android 통화 설정

**통화 → 통화 설정**에서 장치별 자동 수신 대기(기본 3초), 첫 인사,
말투/답변 길이, 캘린더 조회·가예약 사용 여부를 설정합니다.
맥미니는 설정을 약 10초마다 가져오고 다음 통화부터 적용합니다.
이 화면은 기존 `/api` 프록시를 사용하므로 별도 설정 UI 서버가 필요하지 않습니다.
Worker에 `/api/android-calls` 설정 API가 배포되어 있어야 합니다.

### 맥미니 main 배포 (기존 PM2)

맥미니의 Jarvis 저장소 루트에서 실행합니다. `git pull --ff-only`가 로컬 변경이나
브랜치 차이로 실패하면 이후 명령을 실행하지 말고 충돌을 먼저 확인하세요.

```bash
git pull --ff-only origin main &&
npm ci --prefix admin &&
npm run build --prefix admin &&
pm2 restart jarvis-admin
```

빌드에는 개발 의존성도 필요하므로 `npm ci --omit=dev`는 사용하지 않습니다.
`admin/.env.local`과 기존 PM2·Cloudflare Tunnel 설정은 유지합니다.
완료 후 `https://admin.twms.ai`를 새로고침하고 **통화** 메뉴를 확인합니다.
