open Lwt.Infix

let ( >>!= ) = Lwt_result.bind

type conn = [`Remote of Current_ocluster.Connection.t | `Local of Ocaml_ci_api.Solver.t Lwt.t]

let pool = "solver"

let solve_to_custom req builder =
  let params =
    Yojson.Safe.to_string
    @@ Ocaml_ci_api.Worker.Solve_request.to_yojson req
  in
  let builder =
    Ocaml_ci_api.Raw.Solve.Builder.Solver.Solve.Params.init_pointer builder
  in
  Ocaml_ci_api.Raw.Solve.Builder.Solver.Solve.Params.request_set builder params

module Op = struct
  type t = No_context

  let id = "backend-solver"

  module Key = struct
    type t = Ocaml_ci_api.Worker.Solve_request.t

    let digest t = Yojson.Safe.to_string (Ocaml_ci_api.Worker.Solve_request.to_yojson t)
  end

  module Value = struct
    type t = Current_ocluster.Connection.t

    let digest _t = "remote"
  end

  module Outcome = struct

    type t = Ocaml_ci_api.Worker.Solve_response.t

    let marshal t =
      Yojson.Safe.to_string
        (Ocaml_ci_api.Worker.Solve_response.to_yojson t)

    let unmarshal s =
      let s =
        Yojson.Safe.from_string s
        |> Ocaml_ci_api.Worker.Solve_response.of_yojson
      in
      match s with
      | Ok x -> x
      | Error e -> Fmt.failwith "Backend Solve_response: %s" e
  end

  let solve build_job job =
    Capnp_rpc_lwt.Capability.with_ref build_job
      (Current_ocluster.Connection.run_job ~job)

  let run No_context job request (conn:Value.t) =
    let action =
      Cluster_api.Submission.custom_build
      @@ Cluster_api.Custom.v ~kind:"solve"
      @@ solve_to_custom request
    in
    let build_pool =
      Current_ocluster.Connection.pool ~job ~pool ~action ~cache_hint:"" conn
    in
    Current.Job.start_with ~pool:build_pool job ~level:Current.Level.Average >>=
    fun build_job ->
    solve build_job job >>!= fun response ->
    match
      Ocaml_ci_api.Worker.Solve_response.of_yojson
        (Yojson.Safe.from_string response)
    with
    | Ok x -> Lwt_result.return x
    | Error ex -> Fmt.failwith "Backend solve response fail: %s" ex

  let pp f _ = Fmt.string f "Backend Solver Analyse"
  let auto_cancel = true
  let latched = true
end

module Remote_solve = Current_cache.Generic(Op)

let solve t request ~log  = match t with
    | `Local ci ->
      ci >>= fun solver -> Ocaml_ci_api.Solver.solve solver request ~log
    | `Remote rconn ->
      Remote_solve.run No_context request rconn
      |> Current_incr.observe



let local ?solver_dir () : conn =
  `Local (Lwt.return (Solver_pool.spawn_local ?solver_dir ()))

let create ?solver_dir uri =
  match uri with
  | None    -> local ?solver_dir ()
  | Some ur ->
    let vat = Capnp_rpc_unix.client_only_vat () in
    let sr = Capnp_rpc_unix.Vat.import_exn vat ur in
    `Remote (Current_ocluster.Connection.create sr)

let local_ci t : Ocaml_ci_api.Solver.t Lwt.t = match t with
  | `Local ci -> ci
  | `Remote _ -> Fmt.failwith "Not a local solver"
