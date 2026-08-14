import type { SqlExecutor } from "../storage/sql";
import type { McpServerRegistration, StoredMcpServer } from "./types";

interface Row { id:string;name:string;endpoint:string;transport:string;enabled:number;auth_type:string;credential_reference:string|null;service:string|null;provider_id:string|null;description:string|null;capability_mapping_json:string;created_at:string;updated_at:string }

export class McpServerRepository {
  constructor(private readonly db: SqlExecutor) {}
  list(): StoredMcpServer[] { return this.db.sql<Row>`SELECT * FROM mcp_server_configuration ORDER BY created_at`.map(mapRow); }
  get(id:string):StoredMcpServer|undefined { const [row]=this.db.sql<Row>`SELECT * FROM mcp_server_configuration WHERE id=${id}`;return row?mapRow(row):undefined; }
  create(input:McpServerRegistration):StoredMcpServer {
    if(this.get(input.id))throw new Error(`MCP server ${input.id} is already registered`);
    const now=new Date().toISOString();
    this.db.sql`INSERT INTO mcp_server_configuration (id,name,endpoint,transport,enabled,auth_type,credential_reference,service,provider_id,description,capability_mapping_json,created_at,updated_at) VALUES (${input.id},${input.name},${input.endpoint},${input.transport},${input.enabled?1:0},${input.authType},${input.credentialReference??null},${input.service??null},${input.providerId??null},${input.description??null},${JSON.stringify(input.capabilityMapping)},${now},${now})`;
    return this.get(input.id)!;
  }
  setEnabled(id:string,enabled:boolean):StoredMcpServer|undefined {this.db.sql`UPDATE mcp_server_configuration SET enabled=${enabled?1:0},updated_at=${new Date().toISOString()} WHERE id=${id}`;return this.get(id);}
  delete(id:string):boolean {const exists=Boolean(this.get(id));if(exists)this.db.sql`DELETE FROM mcp_server_configuration WHERE id=${id}`;return exists;}
}

function mapRow(row:Row):StoredMcpServer{return{id:row.id,name:row.name,endpoint:row.endpoint,transport:row.transport as StoredMcpServer["transport"],enabled:Boolean(row.enabled),authType:row.auth_type as StoredMcpServer["authType"],...(row.credential_reference?{credentialReference:row.credential_reference}:{}),...(row.service?{service:row.service as NonNullable<StoredMcpServer["service"]>}:{}),...(row.provider_id?{providerId:row.provider_id}:{}),...(row.description?{description:row.description}:{}),capabilityMapping:JSON.parse(row.capability_mapping_json) as Record<string,string>,createdAt:row.created_at,updatedAt:row.updated_at}}
