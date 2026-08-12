import { useEffect, useState } from "react";

export function useTextToSpeech() {
  const isSupported = "speechSynthesis" in window && "SpeechSynthesisUtterance" in window;
  const [isSpeaking, setIsSpeaking] = useState(false);

  useEffect(() => () => window.speechSynthesis?.cancel(), []);

  const speak = (text: string) => {
    if (!isSupported || !text) return;
    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = navigator.language || "ko-KR";
    utterance.onstart = () => setIsSpeaking(true);
    utterance.onend = () => setIsSpeaking(false);
    utterance.onerror = () => setIsSpeaking(false);
    window.speechSynthesis.speak(utterance);
  };

  const stop = () => {
    window.speechSynthesis.cancel();
    setIsSpeaking(false);
  };

  return { isSupported, isSpeaking, speak, stop };
}
