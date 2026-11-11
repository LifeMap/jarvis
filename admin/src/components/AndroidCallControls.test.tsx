import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { defaultCallSettings } from '../../../contracts/calls/settings';
import { AndroidCallControls } from './AndroidCallControls';
let requests:Array<{url:string;body:Record<string,unknown>}>=[];
beforeEach(()=>{
 requests=[];
 vi.stubGlobal('fetch',vi.fn(async(input:RequestInfo|URL,init?:RequestInit)=>{
  const url=String(input);
  if(init?.method==='POST'){requests.push({url,body:JSON.parse(String(init.body))});return new Response(JSON.stringify({id:'job-test'}));}
  if(url.endsWith('/settings'))return new Response(JSON.stringify({settings:defaultCallSettings}));
  return new Response(JSON.stringify(url.endsWith('/devices')?{devices:[]}:{jobs:[]}));
 }));
});
afterEach(()=>{cleanup();vi.unstubAllGlobals();});
it('requires explicit confirmation and sends number, purpose, device and idempotency ID',async()=>{
 render(<AndroidCallControls/>);
 const button=screen.getByRole('button',{name:'발신 요청'});expect(button).toBeDisabled();
 fireEvent.change(screen.getByLabelText('전화번호'),{target:{value:'01012345678'}});
 fireEvent.change(screen.getByLabelText('통화 목적과 허용 범위'),{target:{value:'방문 시간 확인'}});
 fireEvent.click(screen.getByRole('checkbox',{name:/위 번호/}));expect(button).toBeEnabled();fireEvent.click(button);
 await waitFor(()=>expect(requests).toHaveLength(1));
 expect(requests[0]?.body).toMatchObject({deviceId:'mac-mini',phoneNumber:'01012345678',purpose:'방문 시간 확인',confirmed:true});
 expect(requests[0]?.body.requestId).toMatch(/^[a-f0-9-]{36}$/);
 expect(await screen.findByText(/발신 요청이 등록되었습니다/)).toBeInTheDocument();expect(button).toBeDisabled();
});
it('changing the destination invalidates prior confirmation',async()=>{
 render(<AndroidCallControls/>);fireEvent.click(screen.getByRole('checkbox',{name:/위 번호/}));
 fireEvent.change(screen.getByLabelText('장치 ID'),{target:{value:'another-mini'}});
 expect(screen.getByRole('button',{name:'발신 요청'})).toBeDisabled();
 await waitFor(()=>expect(screen.getByText('발신 요청이 없습니다.')).toBeInTheDocument());
});
it('normalizes a formatted phone number and immediately displays the queued request',async()=>{
 render(<AndroidCallControls/>);
 await screen.findByText('발신 요청이 없습니다.');
 fireEvent.change(screen.getByLabelText('전화번호'),{target:{value:'010-1234-5678'}});
 fireEvent.change(screen.getByLabelText('통화 목적과 허용 범위'),{target:{value:' 방문 시간 확인 '}});
 fireEvent.click(screen.getByRole('checkbox',{name:/위 번호/}));
 fireEvent.click(screen.getByRole('button',{name:'발신 요청'}));
 await waitFor(()=>expect(requests).toHaveLength(1));
 expect(requests[0]?.body).toMatchObject({phoneNumber:'01012345678',purpose:'방문 시간 확인'});
 expect(await screen.findByText(/010-1234-5678 · 발신 대기/)).toBeInTheDocument();
});
it('does not submit a whitespace-only purpose',async()=>{
 render(<AndroidCallControls/>);
 fireEvent.change(screen.getByLabelText('전화번호'),{target:{value:'01012345678'}});
 fireEvent.change(screen.getByLabelText('통화 목적과 허용 범위'),{target:{value:'   '}});
 fireEvent.click(screen.getByRole('checkbox',{name:/위 번호/}));
 fireEvent.click(screen.getByRole('button',{name:'발신 요청'}));
 expect(await screen.findByText('전화번호와 전달할 용건을 확인해 주세요.')).toBeInTheDocument();
 expect(requests).toHaveLength(0);
});
