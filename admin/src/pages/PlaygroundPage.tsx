const PRODUCTION_PLAYGROUND = 'https://playground.twms.ai';
export function playgroundUrl(configured: string | undefined, development: boolean): string {
  if (configured) {
    try {
      const url = new URL(configured);
      const local = ['localhost', '127.0.0.1', '[::1]', '0.0.0.0'].includes(url.hostname);
      if (['https:', 'http:'].includes(url.protocol) && (development || !local)) return url.href;
    } catch { /* Fall back to the environment's default. */ }
  }
  return development ? 'http://127.0.0.1:5173' : PRODUCTION_PLAYGROUND;
}
export function PlaygroundPage() {
  const url = playgroundUrl(import.meta.env.VITE_PLAYGROUND_URL, import.meta.env.DEV);
  return <section className="card playground">
    <p>기존 웹 플레이그라운드를 그대로 유지합니다. Agent 대화, 도구 디버그, 승인, 스케줄, 음성 인식·합성 검증은 전용 플레이그라운드에서 수행합니다.</p>
    <a href={url}>플레이그라운드 열기 ↗</a>
  </section>;
}
