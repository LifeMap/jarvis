import { useCallback, useEffect, useState } from 'react';
import { AndroidCallControls } from '../components/AndroidCallControls';
import { calls } from '../services/admin';
import type { CallDetail } from '../types';
import { Badge, Empty, ErrorBanner, Loading } from '../components/AsyncState';
import { useLoad } from '../hooks/useLoad';
import { display } from '../utils/display';
import './calls.css';

const date=(value:string)=>new Date(value).toLocaleString('ko-KR',{timeZone:'Asia/Seoul',month:'long',day:'numeric',hour:'2-digit',minute:'2-digit'});
const caller=(name:string)=>!name||name==='unknown'?'이름 미확인':name;
function duration(start:string,end:string|null){if(!end)return '진행 중';const seconds=Math.max(0,Math.round((Date.parse(end)-Date.parse(start))/1000));return `${Math.floor(seconds/60)}분 ${seconds%60}초`;}
export function CallsPage(){
  const load=useLoad(useCallback(calls.list,[]));
  const [id,setId]=useState<string|null>(null),[selected,setSelected]=useState<CallDetail|null>(null);
  const [query,setQuery]=useState(''),[detailLoading,setDetailLoading]=useState(false),[detailError,setDetailError]=useState(''),[retry,setRetry]=useState(0),[audioError,setAudioError]=useState(false);
  useEffect(()=>{
    let cancelled=false;setSelected(null);setDetailError('');setAudioError(false);
    if(!id){setDetailLoading(false);return;}
    setDetailLoading(true);
    calls.detail(id).then(value=>{if(!cancelled)setSelected(value);}).catch(()=>{if(!cancelled)setDetailError('통화 내용을 불러오지 못했습니다. 다시 시도해 주세요.');}).finally(()=>{if(!cancelled)setDetailLoading(false);});
    return()=>{cancelled=true;};
  },[id,retry]);
  const rows=[...(load.data?.calls??[])].sort((a,b)=>Date.parse(b.startedAt)-Date.parse(a.startedAt));
  const filtered=rows.filter(row=>[row.caller.name,row.caller.phoneNumber,row.summary??''].join(' ').toLowerCase().includes(query.trim().toLowerCase()));
  return <div className="calls-page">
    <div className="calls-workspace">
      <section className="card calls-list" aria-label="통화 내역">
        <div className="calls-heading"><h2>통화 내역 <small>{rows.length}건</small></h2><button disabled={load.loading} onClick={()=>{void load.reload();setRetry(n=>n+1);}}>새로고침</button></div>
        <label className="calls-search">통화 검색<input type="search" placeholder="이름, 전화번호, 요약 검색" value={query} onChange={e=>setQuery(e.target.value)}/></label>
        <p className="calls-hint">최신순 · 한국 시간</p>
        {load.loading?<Loading/>:load.error?<ErrorBanner message={load.error}/>:!rows.length?<Empty/>:!filtered.length?<p className="calls-empty">검색 결과가 없습니다.</p>:<ul className="calls-items">{filtered.map(row=><li key={row.id}>
          <button className={`call-item${id===row.id?' selected':''}`} aria-pressed={id===row.id} onClick={()=>setId(row.id)}>
            <span className="calls-heading"><strong>{caller(row.caller.name)}</strong><Badge tone={row.status==='completed'?'good':row.status==='active'?'warn':'bad'}>{display(row.status)}</Badge></span>
            <span className="call-number">{row.caller.phoneNumber==='unknown'?'번호 미확인':row.caller.phoneNumber}</span>
            <span className="call-preview">{row.summary||'아직 요약이 없습니다.'}</span>
            <span className="call-meta">{date(row.startedAt)} · {row.direction==='outgoing'?'발신':'수신'} · {row.hasAudio?'녹음 있음':'녹음 없음'}</span>
          </button>
        </li>)}</ul>}
      </section>
      <section className="card call-detail" aria-label="선택한 통화" aria-busy={detailLoading}>
        {!id?<div className="calls-empty"><h2>통화를 선택해 주세요</h2><p>요약, 대화 내용과 녹음을 이곳에서 함께 확인할 수 있습니다.</p></div>:detailLoading?<Loading/>:detailError?<><ErrorBanner message={detailError}/><button onClick={()=>setRetry(n=>n+1)}>다시 시도</button></>:selected&&<>
          <header className="call-detail-heading"><div><h2>{caller(selected.caller.name)}</h2><p>{selected.caller.phoneNumber==='unknown'?'번호 미확인':selected.caller.phoneNumber} · {date(selected.startedAt)} · {duration(selected.startedAt,selected.endedAt)}</p></div><Badge tone={selected.status==='completed'?'good':selected.status==='active'?'warn':'bad'}>{display(selected.status)}</Badge></header>
          <section className="call-summary"><h3>통화 요약</h3><p>{selected.summary||'아직 생성된 요약이 없습니다.'}</p></section>
          <section className="call-recording"><h3>통화 녹음</h3>{selected.audioPath?<><audio key={`${selected.id}-${retry}`} aria-label="선택한 통화 녹음" controls preload="none" src={selected.audioPath} onError={()=>setAudioError(true)}/>{audioError&&<p role="status">녹음을 불러오지 못했습니다. 새로고침 후 다시 재생해 주세요.</p>}</>:<p>저장된 녹음이 없습니다.</p>}</section>
          {!!selected.holds?.length&&<section className="call-schedule"><h3>일정 요청</h3>{selected.holds.map((hold,index)=><p key={index}>{date(hold.start)} ~ {date(hold.end)}</p>)}<small>전달받은 일정 요청이며 확정 일정이 아닙니다.</small></section>}
          <section className="call-conversation"><h3>대화 내용 <small>{selected.transcript.length}개 발언</small></h3>{selected.transcript.length?<ol>{selected.transcript.map((turn,index)=><li key={index} className={turn.role==='caller'?'caller':'jarvis'}><strong>{turn.role==='caller'?'상대방':'Jarvis'}</strong><p>{turn.text}</p></li>)}</ol>:<p>저장된 대화 내용이 없습니다.</p>}</section>
        </>}
      </section>
    </div>
    <details className="calls-controls"><summary>장치 상태 및 발신 요청</summary><AndroidCallControls/></details>
  </div>;
}
