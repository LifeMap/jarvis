interface VoiceControlsProps {
  sttSupported: boolean;
  isListening: boolean;
  sttError: string | null;
  onStartListening: () => void;
  onStopListening: () => void;
  ttsSupported: boolean;
  isSpeaking: boolean;
  canSpeak: boolean;
  onSpeak: () => void;
  onStopSpeaking: () => void;
}

export function VoiceControls(props: VoiceControlsProps) {
  return (
    <div className="voice-controls">
      <div>
        <span className="control-label">Speech to text</span>
        <button
          className="secondary-button"
          type="button"
          disabled={!props.sttSupported}
          onClick={props.isListening ? props.onStopListening : props.onStartListening}
        >
          {props.isListening ? "인식 중지" : "마이크 입력"}
        </button>
        {!props.sttSupported && <small>이 브라우저는 STT를 지원하지 않습니다.</small>}
        {props.sttError && <small className="inline-error" role="alert">{props.sttError}</small>}
      </div>
      <div>
        <span className="control-label">Text to speech</span>
        <button
          className="secondary-button"
          type="button"
          disabled={!props.ttsSupported || !props.canSpeak}
          onClick={props.isSpeaking ? props.onStopSpeaking : props.onSpeak}
        >
          {props.isSpeaking ? "재생 중지" : "Jarvis 응답 듣기"}
        </button>
        {!props.ttsSupported && <small>이 브라우저는 TTS를 지원하지 않습니다.</small>}
      </div>
    </div>
  );
}
