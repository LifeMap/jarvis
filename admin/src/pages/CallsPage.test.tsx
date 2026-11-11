import {afterEach,expect,it,vi} from 'vitest';
import {cleanup,fireEvent,render,screen,waitFor} from '@testing-library/react';
import {CallsPage} from './CallsPage';
vi.mock('../components/AndroidCallControls',()=>({AndroidCallControls:()=>null}));
afterEach(()=>{cleanup();vi.unstubAllGlobals();});
const rows=['a','b'].map(id=>({id,status:'completed',caller:{name:id,phoneNumber:id==='a'?'01011111111':'01022222222'},startedAt:'2026-11-11T01:00:00Z',endedAt:'2026-11-11T01:01:00Z',summary:'요약 '+id,hasAudio:false,updatedAt:'2026-11-11T01:01:00Z'}));
const detail=(i:number)=>({...rows[i],transcript:[{role:'caller',text:'대화 '+rows[i]!.id}],audioPath:null});
it('late detail from a previous selection cannot replace the current conversation',async()=>{
 let resolveA!:(value:Response)=>void;
 vi.stubGlobal('fetch',vi.fn(async(input:unknown)=>String(input).endsWith('/calls')?Response.json({calls:rows}):String(input).endsWith('/a')?new Promise<Response>(r=>resolveA=r):Response.json(detail(1))));
 render(<CallsPage/>);fireEvent.click(await screen.findByRole('button',{name:/01011111111/}));fireEvent.click(screen.getByRole('button',{name:/01022222222/}));
 expect(await screen.findByText('대화 b')).toBeInTheDocument();resolveA(Response.json(detail(0)));await waitFor(()=>expect(screen.queryByText('대화 a')).not.toBeInTheDocument());expect(screen.getByText('대화 b')).toBeInTheDocument();expect(screen.getByText('저장된 녹음이 없습니다.')).toBeInTheDocument();
});
it('failed detail can be retried and summary search filters the list',async()=>{
 let failed=true;vi.stubGlobal('fetch',vi.fn(async(input:unknown)=>String(input).endsWith('/calls')?Response.json({calls:rows}):failed?new Response('{}',{status:503}):Response.json(detail(0))));
 render(<CallsPage/>);await screen.findByRole('button',{name:/01011111111/});fireEvent.change(screen.getByRole('searchbox'),{target:{value:'요약 a'}});expect(screen.queryByRole('button',{name:/01022222222/})).not.toBeInTheDocument();fireEvent.click(screen.getByRole('button',{name:/01011111111/}));
 const retry=await screen.findByRole('button',{name:'다시 시도'});failed=false;fireEvent.click(retry);expect(await screen.findByText('대화 a')).toBeInTheDocument();
});
