(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Response : sig
  module TypeErrors : sig
    val to_json : Analysis.AnalysisError.Instantiated.t list -> Yojson.Safe.json
  end

  module Stop : sig
    val to_json : unit -> Yojson.Safe.json
  end
end

module Request : sig
  val origin : socket:Unix.file_descr -> Yojson.Safe.t -> Protocol.Request.origin option

  val format_request : Yojson.Safe.t -> Protocol.Request.t
end

val handshake_message
  :  string ->
  LanguageServer.Types.NotificationMessage.Make(LanguageServer.Types.HandshakeServerParameters).t

val socket_added_message : Yojson.Safe.t
