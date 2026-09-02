#!/usr/bin/env python3
"""Idempotent Railway networking bootstrap for stable V5."""
import json,os,sys,urllib.error,urllib.request
API="https://backboard.railway.com/graphql/v2"; TOKEN=(os.getenv("RAILWAY_TOKEN") or os.getenv("RAILWAY_API_TOKEN") or "").strip(); PROJECT_TOKEN=os.getenv("RAILWAY_TOKEN","").strip(); PROJECT_ID=os.getenv("RAILWAY_PROJECT_ID","").strip(); ENV_ID=os.getenv("RAILWAY_ENVIRONMENT_ID","").strip(); SERVICE_ID=os.getenv("RAILWAY_SERVICE_ID","").strip(); SERVICE_NAME=os.getenv("RAILWAY_SERVICE_NAME","").strip(); TARGET=8080
class ApiError(RuntimeError): pass
def call(q,v,mode):
 h={"Content-Type":"application/json","User-Agent":"railway-universal-stable/5.5"}; h["Project-Access-Token" if mode=="project" else "Authorization"]=TOKEN if mode=="project" else "Bearer "+TOKEN
 req=urllib.request.Request(API,data=json.dumps({"query":q,"variables":v or {}}).encode(),headers=h,method="POST")
 try:
  with urllib.request.urlopen(req,timeout=15) as r: b=json.loads(r.read().decode())
 except urllib.error.HTTPError as e: raise ApiError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")
 except Exception as e: raise ApiError(str(e))
 if b.get("errors"): raise ApiError(json.dumps(b["errors"],ensure_ascii=False)[:1200])
 return b.get("data") or {}
def gql(q,v=None):
 if not TOKEN: raise ApiError("no Railway token")
 if PROJECT_TOKEN:
  try:return call(q,v,"project")
  except ApiError as first:
   try: print("RAILWAY_API_AUTH=BEARER_FALLBACK",flush=True); return call(q,v,"bearer")
   except ApiError: raise first
 return call(q,v,"bearer")
def resolve():
 global PROJECT_ID,ENV_ID,SERVICE_ID
 if not PROJECT_ID or not ENV_ID:
  if not PROJECT_TOKEN: raise ApiError("RAILWAY_PROJECT_ID and RAILWAY_ENVIRONMENT_ID required")
  d=gql("query { projectToken { projectId environmentId } }").get("projectToken") or {}; PROJECT_ID=PROJECT_ID or str(d.get("projectId","")); ENV_ID=ENV_ID or str(d.get("environmentId",""))
 if not PROJECT_ID or not ENV_ID: raise ApiError("unable to resolve project/environment")
 if not SERVICE_ID:
  d=gql("query($id:String!){ project(id:$id){ services{edges{node{id name}}} } }",{"id":PROJECT_ID}); es=(((d.get("project") or {}).get("services") or {}).get("edges") or [])
  ms=[e["node"] for e in es if e.get("node",{}).get("name")==SERVICE_NAME]
  if len(ms)==1:SERVICE_ID=ms[0]["id"]
  elif len(es)==1:SERVICE_ID=es[0]["node"]["id"]
  else:raise ApiError("unable to identify service; set RAILWAY_SERVICE_ID")
def setup():
 if not TOKEN: print("RAILWAY_API_SETUP=SKIP reason=no_token",flush=True); return 0
 resolve(); print("RAILWAY_API_SETUP=CHECK",flush=True)
 d=gql("query($id:String!){ environment(id:$id){ config(decryptVariables:false) } }",{"id":ENV_ID}); cfg=((d.get("environment") or {}).get("config")) or {}
 if isinstance(cfg,str):
  try:cfg=json.loads(cfg)
  except Exception:cfg={}
 sc=((cfg.get("services") or {}).get(SERVICE_ID)) or {}; sd=(sc.get("networking") or {}).get("serviceDomains") or {}; vals=sd.values() if isinstance(sd,dict) else sd if isinstance(sd,list) else []
 has_domain=bool(os.getenv("RAILWAY_PUBLIC_DOMAIN","").strip()) or any(isinstance(x,dict) and str(x.get("domain","")).strip() for x in vals)
 d=gql("query($serviceId:String!,$environmentId:String!){ tcpProxies(serviceId:$serviceId,environmentId:$environmentId){ id domain proxyPort applicationPort } }",{"serviceId":SERVICE_ID,"environmentId":ENV_ID}); ps=d.get("tcpProxies") or []; has_tcp=any(isinstance(x,dict) and int(x.get("applicationPort",-1))==TARGET for x in ps)
 changed=False
 if not has_domain:
  print("RAILWAY_API_ACTION=CREATE_PUBLIC_DOMAIN",flush=True); gql("mutation($input:ServiceDomainCreateInput!){ serviceDomainCreate(input:$input){ domain } }",{"input":{"serviceId":SERVICE_ID,"environmentId":ENV_ID}}); changed=True; print("RAILWAY_API_PUBLIC_DOMAIN=CREATED",flush=True)
 else: print("RAILWAY_API_PUBLIC_DOMAIN=EXISTS",flush=True)
 if not has_tcp:
  print("RAILWAY_API_ACTION=CREATE_TCP_PROXY target=8080",flush=True); r=gql("mutation($input:TCPProxyCreateInput!){ tcpProxyCreate(input:$input){ id domain proxyPort applicationPort } }",{"input":{"serviceId":SERVICE_ID,"environmentId":ENV_ID,"applicationPort":TARGET}}); p=r.get("tcpProxyCreate") or {}; print(f"RAILWAY_API_TCP_PROXY=CREATED domain={p.get('domain','')} port={p.get('proxyPort','')} target=8080",flush=True); changed=True
 else: print("RAILWAY_API_TCP_PROXY=EXISTS target=8080",flush=True)
 if changed:
  gql("mutation($serviceId:String!,$environmentId:String!){ serviceInstanceRedeploy(serviceId:$serviceId,environmentId:$environmentId) }",{"serviceId":SERVICE_ID,"environmentId":ENV_ID}); print("RAILWAY_API_SETUP=REDEPLOY_REQUESTED",flush=True); return 10
 print("RAILWAY_API_SETUP=READY",flush=True); return 0
if __name__=="__main__":
 try:sys.exit(setup())
 except Exception as e:print(f"RAILWAY_API_SETUP=ERROR {e}",file=sys.stderr);sys.exit(20)
