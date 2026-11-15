# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.ApiSpec do
  @behaviour OpenApiSpex.OpenApi
  alias OpenApiSpex.{OpenApi, Info, Server, Components, Paths}

  def spec do
    routes =
      Enum.filter(
        MondekWeb.Router.__routes__(),
        &(String.starts_with?(&1.path, "/api/v1/") and &1.plug != MondekWeb.API.SpecController)
      )

    %OpenApi{
      info: %Info{
        title: "Mondek HTTP API",
        version: "1",
        description:
          "Experimental same-release API. Authentication and authorization are not implemented. Runner, resource and reviewed operator operations share this contract."
      },
      servers: [%Server{url: "/"}],
      paths: Paths.from_routes(routes),
      components: %Components{schemas: MondekWeb.API.Schemas.definitions()}
    }
  end
end

defmodule MondekWeb.API.SpecController do
  use Phoenix.Controller, formats: [:json, :html]
  import Plug.Conn

  def show(conn, _),
    do:
      json(
        conn,
        OpenApiSpex.OpenApi.to_map(MondekWeb.API.ApiSpec.spec(), vendor_extensions: false)
      )

  def docs(conn, _) do
    html(conn, """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Mondek API</title><style>body{font:16px system-ui;max-width:960px;margin:2rem auto;padding:1rem}summary{cursor:pointer;padding:1rem;background:#eef}pre{overflow:auto}details{margin:1rem 0}</style></head><body><h1>Mondek HTTP API</h1><p>Experimental same-release contract. <a href="/api/v1/openapi.json">Download OpenAPI</a>. Authentication and authorization are not implemented.</p><main id="operations"></main><script>fetch('/api/v1/openapi.json').then(r=>r.json()).then(s=>{for(const [path,item] of Object.entries(s.paths)){for(const [method,op] of Object.entries(item)){if(!op.operationId)continue;const d=document.createElement('details'),h=document.createElement('summary'),p=document.createElement('p'),pre=document.createElement('pre');h.textContent=method.toUpperCase()+' '+path+' — '+op.summary;p.textContent=op.description;pre.textContent=JSON.stringify(op,null,2);d.append(h,p,pre);document.getElementById('operations').append(d)}}})</script></body></html>
    """)
  end
end
