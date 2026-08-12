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
  locationStatus: "unsupported"|"requesting"|"available"|"denied"|"error";
  locationAccuracy?: number;
  onRefreshLocation: () => void;
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
      <div>
        <span className="control-label">Request location</span>
        <button className="secondary-button" type="button" disabled={props.locationStatus==="unsupported"||props.locationStatus==="requesting"} onClick={props.onRefreshLocation}>위치 새로고침</button>
        <small>{locationMessage(props.locationStatus,props.locationAccuracy)}</small>
      </div>
    </div>
  );
}

function locationMessage(status:VoiceControlsProps["locationStatus"],accuracy?:number){
  if(status==="available")return `현재 요청에 전달됨${accuracy!==undefined?` (정확도 약 ${Math.round(accuracy)}m)`:""}`;
  if(status==="requesting")return "브라우저 위치 권한 확인 중…";
  if(status==="denied")return "위치 권한이 거부되어 전달하지 않습니다.";
  if(status==="unsupported")return "이 브라우저는 위치정보를 지원하지 않습니다.";
  return "위치를 가져오지 못했습니다. Chat 기능은 계속 사용할 수 있습니다.";
}
