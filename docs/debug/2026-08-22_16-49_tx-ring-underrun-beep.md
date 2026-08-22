# 디버그 로그: TX 링 언더런 — 삐삐삐삐 (다발성 단음)

**날짜:** 2026-08-22 16:49
**파일:** bridge/Sources/JarvisPCMRealtime/include/JarvisPCMRealtime.h
**심각도:** High

## 1. 문제 설명

### 증상
1 kHz 1초 진단 톤 테스트 시 연속적인 "삐—" 대신 "삐삐삐삐" (약 1초 동안 반복되는 짧은 단음들)

### 환경
- 브랜치: phase4-cp1-realtime-foundation
- 이전 수정: `CallAudioToneRingProducer` (5ms DispatchSource 펌프) 추가했으나 여전히 증상 동일

## 2. 근본 원인 분석

### TX 링 크기 불일치

```
JARVIS_PCM_TX_RING_FRAMES = 9600  // 200ms @ 48kHz
톤 길이 = 48000 프레임              // 1000ms @ 48kHz
```

`sendTestTone()`이 호출되면:
1. `JarvisPCMRuntimeRequestTone` → toneState = 1 (queued)
2. 48000 프레임 sine 생성
3. `toneProducer.start()` → 링에 최초 9600 프레임만 기록 (링 가득 참)
4. 5ms DispatchSource 타이머가 나머지를 펌핑 시도

### 언더런 발생 메커니즘

IOProc는 ~512 프레임/콜백(~10.67ms) 또는 ~960 프레임/콜백(~20ms)으로 링을 드레인한다.
DispatchSource 타이머는 비실시간이며 OS 스케줄링 지터(jitter) 때문에 지연될 수 있다.

시나리오:
```
T=0ms    : 9600 프레임 적재 (200ms 분량)
T=10ms   : IOProc가 512 프레임 소비 → 링에 9088 남음
T=15ms   : 타이머 발화 예정 → OS 지연으로 T=25ms에 발화
T=20ms   : IOProc가 512 프레임 소비 → 링에 8576 남음
...
T=200ms  : 링 소진 → copied=0 → 출력 버퍼를 0으로 memset (묵음)
T=205ms  : 타이머 발화, 9600 프레임 재적재
T=215ms  : IOProc가 sine 다시 읽음 → 다시 비프음
           → "삐삐삐삐" 패턴
```

### IOProc 언더런 처리 코드

```c
// JarvisPCMRealtime.c: JarvisPCMInjectIOProc
uint32_t copied = ConsumeTXRing(ctx, samples, (uint32_t)frameCount);
if (copied < (uint32_t)frameCount) {
    memset(
        samples + copied * JARVIS_PCM_CHANNEL_COUNT,
        0,  // ← 언더런 시 나머지를 묵음으로 채움
        ...
    );
}
```

링이 소진되면 IOProc는 출력의 나머지 부분을 0(묵음)으로 채운다.
이것이 sine 음 → 묵음 → sine 음 → 묵음의 반복을 만들어 "삐삐삐삐"처럼 들리게 한다.

## 3. 시도한 해결책

### 시도 1 (이전): MainActor 50ms 타이머 → DispatchSource 5ms 백그라운드 펌프
- 결과: 여전히 동일한 증상 (DispatchSource도 비실시간이므로 지터 문제 해결 안 됨)

### 시도 2 (현재 적용): 링 크기를 1초 전체 분량으로 확장 + 단일 쓰기

**변경사항:**
- `JARVIS_PCM_TX_RING_FRAMES`: 9600 → 48000
- 메모리 영향: 76.8KB → 384KB (heap 할당, 문제없음)
- Swift 코드 변경 불필요: `CallAudioToneRingProducer.start()`의 첫 `writeAvailable()` 호출에서 48000 프레임 전체가 한 번에 기록됨 → 타이머 조건(`framesWritten * 2 < interleavedStereo.count`)이 false → 타이머 생성 안 됨

**왜 이 방법이 작동하는가:**
- 링에 1초 전체 sine이 미리 적재됨
- IOProc는 512 프레임씩 약 94번 콜백에 걸쳐 드레인 (각 콜백 ~10ms → 전체 약 940ms)
- 링 소진 전에 1초가 완료되므로 언더런 없음
- `toneFramesRemaining`이 0에 도달하면 `MarkToneComplete` → toneState = 0 (idle)

## 4. 최종 검증 기준

- `txUnderrunCount`가 톤 재생 중 0을 유지해야 함
- 사용자가 하나의 연속적인 1초 "삐—" 소리를 들어야 함
- 단위 테스트 `testWriteTXFramesReturnsPartialWhenRingIsFull` 통과 (상수 변경 반영)
