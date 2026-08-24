import{useCallback,useState}from"react";import{calls}from"../services/admin";import type{CallDetail}from"../types";import{Badge,Empty,ErrorBanner,Loading}from"../components/AsyncState";import{useLoad}from"../hooks/useLoad";import{display}from"../utils/display";
export function CallsPage(){
  const load=useLoad(useCallback(calls.list,[]));
  const[selected,setSelected]=useState<CallDetail|null>(null);
  if(load.loading)return <Loading/>;
  if(load.error)return <ErrorBanner message={load.error}/>;
  const rows=load.data!.calls;
  return <div className="history-grid">
    <section className="card">
      <h2>수신 전화</h2>
      {rows.length===0?<Empty/>:<table><thead><tr><th>시간</th><th>이름</th><th>번호</th><th>상태</th><th>요약</th><th>오디오</th><th/></tr></thead>
      <tbody>{rows.map(row=><tr key={row.id}><td>{new Date(row.startedAt).toLocaleString()}</td><td>{row.caller.name}</td><td>{row.caller.phoneNumber}</td><td><Badge tone={row.status==="completed"?"good":"bad"}>{display(row.status)}</Badge></td><td>{row.summary??"—"}</td><td>{row.hasAudio?"있음":"없음"}</td><td><button onClick={async()=>setSelected(await calls.detail(row.id))}>상세</button></td></tr>)}</tbody></table>}
    </section>
    {selected&&<aside className="card detail">
      <h2>통화 상세</h2>
      <dl>
        <dt>이름</dt><dd>{selected.caller.name}</dd>
        <dt>번호</dt><dd>{selected.caller.phoneNumber}</dd>
        <dt>용건</dt><dd>{selected.summary??"—"}</dd>
        <dt>전사</dt><dd>{selected.transcript.length?selected.transcript.map((turn,index)=><p key={`${turn.role}-${index}`}>{turn.role}: {turn.text}</p>):"없음"}</dd>
        <dt>녹음</dt><dd>{selected.audioPath?<audio controls src={selected.audioPath}/>:"없음"}</dd>
      </dl>
    </aside>}
  </div>;
}
