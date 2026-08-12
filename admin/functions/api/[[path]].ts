interface Env{JARVIS_API_ORIGIN:string;JARVIS_API_TOKEN:string}
interface Context{request:Request;env:Env;params:{path:string[]|string}}
export const onRequest=async({request,env,params}:Context):Promise<Response>=>{
  if(!env.JARVIS_API_ORIGIN||!env.JARVIS_API_TOKEN)return Response.json({error:"Admin API proxy is not configured"},{status:503});
  const path=Array.isArray(params.path)?params.path.join("/"):params.path;const incoming=new URL(request.url);const target=new URL(`/api/${path}`,env.JARVIS_API_ORIGIN);target.search=incoming.search;
  const headers=new Headers();headers.set("authorization",`Bearer ${env.JARVIS_API_TOKEN}`);headers.set("accept","application/json");const contentType=request.headers.get("content-type");if(contentType)headers.set("content-type",contentType);
  const response=await fetch(target,{method:request.method,headers,body:["GET","HEAD"].includes(request.method)?undefined:request.body,redirect:"manual"});
  return new Response(response.body,{status:response.status,headers:{"content-type":response.headers.get("content-type")??"application/json","cache-control":"no-store"}});
};
