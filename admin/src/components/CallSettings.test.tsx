import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { CallSettings } from './CallSettings';
import { defaultCallSettings } from '../../../contracts/calls/settings';
afterEach(()=>{cleanup();vi.unstubAllGlobals();});
it('loads defaults and persists changed delay, greeting and calendar switch',async()=>{
 let saved:unknown;
 vi.stubGlobal('fetch',vi.fn(async(_url:unknown,init?:RequestInit)=>{
  if(init?.method==='PUT')saved=JSON.parse(String(init.body));
  return Response.json({settings:defaultCallSettings});
 }));
 render(<CallSettings deviceId="mac-mini"/>);
 const button=screen.getByRole('button',{name:'통화 설정 저장'});
 await waitFor(()=>expect(button).toBeEnabled());
 expect(screen.getByLabelText('자동 수신 대기 시간 (초)')).toHaveValue(3);
 fireEvent.change(screen.getByLabelText('자동 수신 대기 시간 (초)'),{target:{value:'5'}});
 fireEvent.change(screen.getByLabelText('첫 인사'),{target:{value:'안녕하세요. AI 비서입니다.'}});
 fireEvent.click(screen.getByRole('checkbox'));
 fireEvent.click(button);
 await screen.findByText(/저장했습니다/);
 expect(saved).toMatchObject({answerDelaySeconds:5,greeting:'안녕하세요. AI 비서입니다.',calendarEnabled:false});
});
it('does not permit overwriting settings after a load failure',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>new Response('{}',{status:503})));
 render(<CallSettings deviceId="mac-mini"/>);
 await screen.findByText(/불러오지 못했습니다/);
 expect(screen.getByRole('button',{name:'통화 설정 저장'})).toBeDisabled();
});
