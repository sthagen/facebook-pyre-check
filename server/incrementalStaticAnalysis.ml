(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Analysis

let run_additional_check ~configuration ~environment ~source_paths ~check =
  match Analysis.Check.get_check_to_run ~check_name:check with
  | Some (module Check) ->
      let ast_environment = TypeEnvironment.ast_environment environment in
      let sources =
        List.filter_map source_paths ~f:(fun { SourcePath.qualifier; is_external; _ } ->
            if is_external then
              None
            else
              AstEnvironment.ReadOnly.get_source ast_environment qualifier)
      in
      List.concat_map sources ~f:(fun source ->
          Check.run ~configuration ~environment:(TypeEnvironment.read_only environment) ~source)
      |> List.map
           ~f:
             (AnalysisError.instantiate
                ~lookup:
                  (AstEnvironment.ReadOnly.get_real_path_relative ~configuration ast_environment))
  | None ->
      Log.warning "No check corresponding to `%s` found." check;
      []
