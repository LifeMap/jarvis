import { expect, it } from 'vitest';
import { playgroundUrl } from './PlaygroundPage';
it('uses the public playground in production even with an old loopback setting',()=>{
 for(const value of [undefined,'http://127.0.0.1:5173','http://localhost:5173','http://[::1]:5173'])expect(playgroundUrl(value,false)).toBe('https://playground.twms.ai');
});
it('preserves development and explicit external deployment URLs',()=>{
 expect(playgroundUrl(undefined,true)).toBe('http://127.0.0.1:5173');
 expect(playgroundUrl('https://playground.example.test',false)).toBe('https://playground.example.test/');
});
