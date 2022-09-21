val make_ci :
  engine:Current.Engine.t ->
  Ocaml_ci_api.Raw.Build.Service.CI.t Capnp_rpc_lwt.Capability.t
