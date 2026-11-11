import { useState } from 'react';
import { CallSettings } from './CallSettings';
import './call-settings.css';

export function CallSettingsPanel() {
  const [deviceId,setDeviceId]=useState('mac-mini');
  const validDevice=/^[A-Za-z0-9_-]{1,64}$/.test(deviceId);
  return <section className="card android-call-controls">
    <h2>통화 서비스 설정</h2>
    <p>맥미니의 자동 수신 대기 시간, 첫 인사, 말투와 캘린더 사용을 설정합니다.</p>
    <p><label>통화 설정 장치 ID <input value={deviceId} onChange={e=>setDeviceId(e.target.value)} maxLength={64}/></label></p>
    {validDevice?<CallSettings key={deviceId} deviceId={deviceId}/>:<p role="status">장치 ID는 영문, 숫자, 밑줄, 하이픈으로 입력하세요.</p>}
  </section>;
}
