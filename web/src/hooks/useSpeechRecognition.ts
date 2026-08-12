import { useEffect, useRef, useState } from "react";

interface SpeechRecognitionState {
  isSupported: boolean;
  isListening: boolean;
  error: string | null;
  start: () => void;
  stop: () => void;
}

export function useSpeechRecognition(onTranscript: (transcript: string) => void): SpeechRecognitionState {
  const Recognition = window.SpeechRecognition ?? window.webkitSpeechRecognition;
  const recognitionRef = useRef<SpeechRecognition | null>(null);
  const [isListening, setIsListening] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => () => recognitionRef.current?.abort(), []);

  const start = () => {
    if (!Recognition || isListening) return;

    const recognition = new Recognition();
    recognition.lang = navigator.language || "ko-KR";
    recognition.continuous = false;
    recognition.interimResults = false;
    recognition.onresult = (event) => {
      const transcript = event.results[event.resultIndex]?.[0]?.transcript?.trim();
      if (transcript) onTranscript(transcript);
    };
    recognition.onerror = (event) => {
      setError(`음성 인식 실패: ${event.message || event.error}`);
      setIsListening(false);
    };
    recognition.onend = () => setIsListening(false);
    recognitionRef.current = recognition;
    setError(null);
    setIsListening(true);

    try {
      recognition.start();
    } catch (startError) {
      setError(startError instanceof Error ? startError.message : "음성 인식을 시작할 수 없습니다.");
      setIsListening(false);
    }
  };

  const stop = () => recognitionRef.current?.stop();

  return { isSupported: Boolean(Recognition), isListening, error, start, stop };
}
