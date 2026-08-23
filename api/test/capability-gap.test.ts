import{describe,expect,it}from"vitest";import{detectCapabilityGap,detectMissingCapabilityResponse}from"../src/capability-gap/capability-gap-detector";

describe("Capability Gap detector",()=>{
  it("classifies explicit unsupported integration mutations",()=>{
    expect(detectCapabilityGap("Notion 데이터베이스에 회의 내용을 등록해줘",[],[])).toMatchObject({service:"notion",requestedCapability:"Notion 페이지/데이터베이스 작성",blocking:true});
    expect(detectCapabilityGap("이 PDF에 전자서명해줘",[],[])).toMatchObject({service:"pdf",blocking:true});
  });

  it("records live or location requests that current tools cannot serve",()=>{
    expect(detectCapabilityGap("내 위치를 기반으로 바이크타기 좋은 날씨인지 확인해줘",[],[])).toMatchObject({service:"weather",requestedCapability:"위치 기반 날씨 조회",blocking:false});
    expect(detectCapabilityGap("지금 내위치에서 비오는데 언제 그칠까?",[],[])).toMatchObject({service:"weather",blocking:false});
    expect(detectCapabilityGap("아니야 서울의 날씨가 아니라 나의 위치정보를 기반으로 다시 알려줘",[],[])).toMatchObject({service:"weather",blocking:false});
  });

  it("does not classify discussion, supported failures, or registered MCP capabilities",()=>{
    expect(detectCapabilityGap("Notion 연동은 좋은 것 같아",[],[])).toBeNull();
    expect(detectCapabilityGap("날씨는 좋은 것 같아",[],[])).toBeNull();
    expect(detectCapabilityGap("안녕",[],[])).toBeNull();
    expect(detectCapabilityGap("파이썬 list가 뭐야?",[],[])).toBeNull();
    expect(detectCapabilityGap("메일 보내줘",[],[])).toBeNull();
    expect(detectCapabilityGap("Gmail OAuth가 만료됐어. 다시 연결해줘",[],[])).toBeNull();
    expect(detectCapabilityGap("Calendar Provider timeout을 확인해줘",[],[])).toBeNull();
    expect(detectCapabilityGap("Slack으로 메시지 보내줘",[],[{id:"slack",name:"Slack MCP",endpoint:"https://example.test/mcp",transport:"streamable-http",enabled:false,authType:"oauth",service:"search",providerId:"slack-mcp",capabilityMapping:{},createdAt:"",updatedAt:""}])).toBeNull();
  });

  it("recognizes capabilities from generically named discovered MCP tools",()=>{
    expect(detectCapabilityGap("Notion에 페이지를 작성해줘",[],[{id:"work",name:"Work tools",endpoint:"https://example.test/mcp",transport:"streamable-http",enabled:true,authType:"none",service:"search",providerId:"work-mcp",capabilityMapping:{},createdAt:"",updatedAt:""}],["notion_create_page"])).toBeNull();
  });

  it("detects assistant replies that admit a missing capability",()=>{
    expect(detectMissingCapabilityResponse("실시간 날씨 데이터를 직접 확인할 수 있는 기능이 없습니다.")).toBe(true);
    expect(detectMissingCapabilityResponse("저는 이와 같은 외부 도구를 사용하지 않습니다.")).toBe(true);
    expect(detectMissingCapabilityResponse("안녕하세요. Jarvis 테스트 응답입니다.")).toBe(false);
  });
});
