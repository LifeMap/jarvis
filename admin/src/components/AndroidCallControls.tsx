import './call-settings.css';
import { CallSettings } from './CallSettings';
import { useEffect, useState, type FormEvent } from 'react';
import { api } from '../services/api-client';
interface Device { deviceId:string;link:string;phone:string;busy:boolean;outbound:boolean;autoAnswer:boolean;updatedAt:string }
export function AndroidCallControls() {
  const [devices,setDevices]=useState<Device[]>([]);
  const [requestId,setRequestId]=useState(()=>crypto.randomUUID());
  const [jobs,setJobs]=useState<Array<{id:string;device_id:string;phone:string;status:string}>>([]);
  const [deviceId,setDeviceId]=useState('mac-mini');
  const [number,setNumber]=useState('');
  const [purpose,setPurpose]=useState('');
  const [confirmed,setConfirmed]=useState(false);
  const [sending,setSending]=useState(false);
  const [message,setMessage]=useState('');
  const [statusError,setStatusError]=useState('');
  useEffect(()=>{
    let mounted=true;
    async function refresh(){try{const result=await api<{devices:Device[]}>('/android-calls/devices');if(!Array.isArray(result.devices))throw new Error('Invalid devices response');if(mounted){setDevices(result.devices);setStatusError('');}const recent=await api<{jobs:Array<{id:string;device_id:string;phone:string;status:string}>}>('/android-calls/jobs');if(mounted&&Array.isArray(recent.jobs)){setJobs(recent.jobs);}}catch{if(mounted)setStatusError('통화 장치 상태를 불러오지 못했습니다.');}}
    void refresh();const timer=setInterval(()=>void refresh(),10000);
    return()=>{mounted=false;clearInterval(timer);};
  },[]);
  async function submit(event:FormEvent) {
    event.preventDefault();if(sending||!confirmed)return;
    setSending(true);setMessage('');
    try{const result=await api<{id:string}>('/android-calls/jobs',{method:'POST',body:JSON.stringify({requestId,deviceId,phoneNumber:number,purpose,confirmed:true})});setMessage(`발신 요청이 등록되었습니다. 작업: ${result.id}`);setConfirmed(false);setRequestId(crypto.randomUUID());}
    catch{setMessage('발신 요청의 접수 여부를 확인하지 못했습니다. 중복 발신을 피하려면 작업 목록을 확인한 뒤 다시 요청하세요.');}
    finally{setSending(false);}
  }
  return <section className="card android-call-controls">
    <h2>Android 통화 서비스</h2>
    {statusError && <p role="status">{statusError}</p>}
    {devices.length===0?<p>연결 상태를 보고한 맥미니가 없습니다.</p>:devices.map(device=>{
      const stale=Date.now()-Date.parse(device.updatedAt)>30000;
      return <p key={device.deviceId}>{device.deviceId} · {stale?'상태 보고 지연':device.link} · {device.phone} · 자동 수신 {device.autoAnswer?'켜짐':'꺼짐'} · 발신 {device.outbound?'켜짐':'꺼짐'}</p>;
    })}
    <form onSubmit={submit}>
      <p><label>장치 ID <input value={deviceId} onChange={e=>{setDeviceId(e.target.value);setConfirmed(false);setRequestId(crypto.randomUUID());}} pattern="[A-Za-z0-9_-]{1,64}" required disabled={sending}/></label></p>
      <p><label>전화번호 <input type="tel" value={number} onChange={e=>{setNumber(e.target.value);setConfirmed(false);setRequestId(crypto.randomUUID());}} pattern="\+?[0-9]{3,20}" required disabled={sending}/></label></p>
      <p><label>통화 목적과 허용 범위 <textarea value={purpose} onChange={e=>{setPurpose(e.target.value);setConfirmed(false);setRequestId(crypto.randomUUID());}} maxLength={4000} required disabled={sending}/></label></p>
      <p><label><input type="checkbox" checked={confirmed} onChange={e=>setConfirmed(e.target.checked)} disabled={sending}/> 위 번호로 AI가 실제 전화를 거는 것에 동의합니다.</label></p>
      <button type="submit" disabled={!confirmed||sending}>{sending?'요청 중…':'발신 요청'}</button>
      <p>요청은 5분 후 만료됩니다. 맥미니에서 발신이 활성화되어 있어야 실행됩니다.</p>
      {message&&<p role="status">{message}</p>}
    </form>
    <CallSettings deviceId={deviceId}/>
    <h3>최근 발신 요청</h3>
    {jobs.length===0?<p>발신 요청이 없습니다.</p>:<ul>{jobs.slice(0,10).map(job=><li key={job.id}>{job.phone} · {job.status} · {job.id}</li>)}</ul>}
  </section>;
}
