import { useEffect, useState, type FormEvent } from 'react';
import { api } from '../services/api-client';
import { defaultCallSettings, validCallSettings, type CallSettings as Settings } from '../../../contracts/calls/settings';
export function CallSettings({deviceId}:{deviceId:string}) {
  const [settings,setSettings]=useState<Settings>({...defaultCallSettings});
  const [loaded,setLoaded]=useState(false),[saving,setSaving]=useState(false),[message,setMessage]=useState('');
  useEffect(()=>{
    let cancelled=false;setLoaded(false);setMessage('');
    if(!/^[A-Za-z0-9_-]{1,64}$/.test(deviceId))return;
    api<{settings:Settings}>(`/android-calls/devices/${deviceId}/settings`).then(r=>{if(!validCallSettings(r.settings))throw new Error('Invalid settings');if(!cancelled){setSettings(r.settings);setLoaded(true);}}).catch(()=>{if(!cancelled)setMessage('통화 설정을 불러오지 못했습니다. Worker 업데이트와 연결을 확인해 주세요.');});
    return()=>{cancelled=true;};
  },[deviceId]);
  async function save(e:FormEvent){
    e.preventDefault();if(!loaded||saving)return;setSaving(true);setMessage('');
    try{await api(`/android-calls/devices/${deviceId}/settings`,{method:'PUT',body:JSON.stringify(settings)});setMessage('저장했습니다. 맥미니가 설정을 가져온 뒤 시작하는 다음 통화부터 적용됩니다.');}
    catch{setMessage('설정을 저장하지 못했습니다. 다시 시도해 주세요.');}finally{setSaving(false);}
  }
  return <section aria-label="통화 설정">
    <form onSubmit={save} className="call-settings-form"><fieldset disabled={!loaded||saving}>
      <label>자동 수신 대기 시간 (초)<input type="number" min={0} max={30} step={1} required value={settings.answerDelaySeconds} onChange={e=>setSettings({...settings,answerDelaySeconds:Number(e.target.value)})}/></label>
      <label>수신 통화의 캘린더 사용<select value={settings.calendarEnabled?'enabled':'disabled'} onChange={e=>setSettings({...settings,calendarEnabled:e.target.value==='enabled'})}><option value="enabled">일정 조회 및 요청 접수</option><option value="disabled">사용하지 않음</option></select></label>
      <label className="settings-wide">첫 인사<textarea aria-label="첫 인사" rows={3} required maxLength={500} value={settings.greeting} onChange={e=>setSettings({...settings,greeting:e.target.value})}/><small>{settings.greeting.length} / 500자</small></label>
      <label className="settings-wide">말투와 답변 길이<textarea aria-label="말투와 답변 길이" rows={4} required maxLength={1000} value={settings.style} onChange={e=>setSettings({...settings,style:e.target.value})}/><small>{settings.style.length} / 1000자</small></label>
      <button type="submit">{saving?'저장 중…':'통화 설정 저장'}</button>
      {message&&<span className="settings-wide call-settings-message" role="status">{message}</span>}
    </fieldset></form>
    <p>변경 내용은 맥미니가 설정을 가져온 뒤 시작하는 다음 통화부터 적용됩니다. 진행 중인 통화에는 기존 설정을 유지하며, 맥미니는 약 10초마다 설정을 가져옵니다.</p>
    <p>일정 조회와 요청 접수는 Jarvis의 기존 Google 계정 연결을 사용합니다. 일정 요청은 쓰기 권한이 있는 ‘Jarvis’ 캘린더에 저장되며 확정 일정이 아닙니다.</p>
    <p>필요한 정보 수집 → 전달 내용 확인 → 상대방의 종료 대기. 자동 콜백은 사용하지 않습니다.</p>
  </section>;
}
