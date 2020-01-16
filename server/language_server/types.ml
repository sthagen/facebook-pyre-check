(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

(*  Types for Basic JSON structures.
 *  cf. https://github.com/Microsoft/language-server-protocol/blob/master/protocol.md#basic-json-structures.contents
 *  It is not complete: we include what we need for diagnostic messages. *)

(** The ToAny module represents serializing an OCaml type [t] to a "any" JSON data *)
module type ToAny = sig
  type t

  val to_yojson : t -> Yojson.Safe.json

  val of_yojson : Yojson.Safe.json -> (t, string) result
end

(** The OfAny module represents deserializing "any" JSON data to an OCaml type [t] *)
module type OfAny = sig
  type t

  val of_yojson : Yojson.Safe.json -> (t, string) result
end

(** The Null module represents a `Null type of ToAny *)
module Null : ToAny = struct
  type t = unit

  let to_yojson _ = `Null

  let of_yojson = function
    | `Null -> Ok ()
    | json -> Error (Format.asprintf "Invalid JSON %s" (Yojson.Safe.to_string json))
end

(** The None module represents a None OfAny type *)
module None : OfAny = struct
  type t = unit

  let of_yojson _ = Ok ()
end

module RequestId = struct
  type t =
    | Int of int
    | String of string
  [@@deriving eq, show]

  let to_yojson = function
    | Int id -> `Int id
    | String id -> `String id


  let of_yojson = function
    | `Int id -> Ok (Int id)
    | `String id -> Ok (String id)
    | json -> Error (Format.asprintf "Invalid request id %s" (Yojson.Safe.to_string json))
end

module DocumentUri = struct
  type t = string [@@deriving yojson, eq, show]
end

module Position = struct
  type t = {
    line: int; [@key "line"]
    character: int; [@key "character"]
  }
  [@@deriving yojson, eq, show]

  let from_pyre_position ~line ~column = { line = line - 1; character = column }
end

module Range = struct
  type t = {
    start: Position.t; [@key "start"]
    end_: Position.t; [@key "end"]
  }
  [@@deriving yojson, eq, show]
end

module Location = struct
  type t = {
    uri: DocumentUri.t; [@key "uri"]
    range: Range.t; [@key "range"]
  }
  [@@deriving yojson]
end

module WorkspaceFolder = struct
  type t = {
    uri: string; [@key "uri"]
    name: string; [@key "name"]
  }
  [@@deriving yojson]
end

module DiagnosticSeverity = struct
  type t =
    | Error
    | Warning
    | Information
    | Hint
  [@@deriving eq, show]

  let to_yojson : t -> Yojson.Safe.json = function
    | Error -> `Int 1
    | Warning -> `Int 2
    | Information -> `Int 3
    | Hint -> `Int 4


  let of_yojson : Yojson.Safe.json -> (t, string) Result.result = function
    | `Int 1 -> Result.Ok Error
    | `Int 2 -> Result.Ok Warning
    | `Int 3 -> Result.Ok Information
    | `Int 4 -> Result.Ok Hint
    | _ -> Result.Error "Invalid JSON"
end

module Diagnostic = struct
  type t = {
    range: Range.t; [@key "range"]
    severity: DiagnosticSeverity.t option; [@key "severity"] [@default None]
    code: int option; [@key "code"] [@default None]
    source: string option; [@key "source"] [@default None]
    message: string; [@key "message"]
  }
  [@@deriving yojson, eq, show]
end

module PublishDiagnosticsParameters = struct
  type t = {
    uri: DocumentUri.t; [@key "uri"]
    diagnostics: Diagnostic.t list; [@key "diagnostics"]
  }
  [@@deriving yojson]
end

module TextDocumentIdentifier = struct
  type t = {
    uri: DocumentUri.t;
    version: int option; [@default None]
  }
  [@@deriving yojson]
end

module TextDocumentItem = struct
  type t = {
    uri: DocumentUri.t;
    languageId: string;
    version: int;
    text: string;
  }
  [@@deriving yojson]
end

module VersionedTextDocumentIdentifier = struct
  type t = {
    uri: DocumentUri.t;
    version: int;
  }
  [@@deriving yojson]
end

module TextDocumentPositionParameters = struct
  type t = {
    textDocument: TextDocumentIdentifier.t;
    position: Position.t;
  }
  [@@deriving yojson]
end

module CompletionParameters = struct
  type triggerKind =
    | Invoked
    | TriggerCharacter
    | TriggerForIncompleteCompletions
  [@@deriving eq, show]

  let triggerKindNumber = function
    | Invoked -> 1
    | TriggerCharacter -> 2
    | TriggerForIncompleteCompletions -> 3


  type context = {
    triggerKind: int;
    triggerCharacter: string option; [@default None]
  }
  [@@deriving yojson]

  type t = {
    textDocument: TextDocumentIdentifier.t;
    position: Position.t;
    context: context option; [@default None]
  }
  [@@deriving yojson]
end

module DidCloseTextDocumentParameters = struct
  type t = { textDocument: TextDocumentIdentifier.t } [@@deriving yojson]
end

module DidSaveTextDocumentParameters = struct
  type t = {
    textDocument: TextDocumentIdentifier.t;
    text: string option; [@default None]
  }
  [@@deriving yojson]
end

module DidOpenTextDocumentParameters = struct
  type t = { textDocument: TextDocumentItem.t } [@@deriving yojson]
end

module DidChangeTextDocumentParameters = struct
  module TextDocumentContentChangeEvent = struct
    type t = {
      range: Range.t option; [@default None]
      rangeLength: int option; [@default None]
      text: string;
    }
    [@@deriving yojson]
  end

  type t = {
    textDocument: VersionedTextDocumentIdentifier.t;
    contentChanges: TextDocumentContentChangeEvent.t list;
  }
  [@@deriving yojson]
end

module CodeActionParameters = struct
  module CodeActionContext = struct
    type t = { diagnostics: Diagnostic.t list [@default []] } [@@deriving yojson]
  end

  type t = {
    textDocument: TextDocumentIdentifier.t;
    range: Range.t;
    context: CodeActionContext.t;
  }
  [@@deriving yojson]
end

module TypeCoverageParameters = struct
  type t = { textDocument: TextDocumentIdentifier.t } [@@deriving yojson]
end

module CommandArguments = struct
  type t = {
    uri: DocumentUri.t;
    range: Range.t;
    newText: string;
  }
  [@@deriving yojson, eq, show]
end

module ExecuteCommandParameters = struct
  type t = {
    command: string;
    arguments: CommandArguments.t list;
  }
  [@@deriving yojson]
end

module ShowMessageParameters = struct
  type messageType =
    | ErrorMessage
    | WarningMessage
    | InfoMessage
    | LogMessage
  [@@deriving eq, show]

  let messageTypeNumber = function
    | ErrorMessage -> 1
    | WarningMessage -> 2
    | InfoMessage -> 3
    | LogMessage -> 4


  let fromMessageTypeNumber = function
    | 1 -> ErrorMessage
    | 2 -> WarningMessage
    | 3 -> InfoMessage
    | _ -> LogMessage


  type t = {
    messageType: int; [@key "type"]
    message: string;
  }
  [@@deriving yojson]
end

module ShowStatusParameters = struct
  type progress = {
    numerator: int;
    denominator: int;
  }
  [@@deriving yojson, eq, show]

  type t = {
    type_: int; [@key "type"]
    actions: string list option;
    progress: progress option;
    message: string;
    shortMessage: string option;
  }
  [@@deriving eq, show, yojson]
end

module HandshakeServerParameters = struct
  type t = { version: string } [@@deriving yojson]
end

module HandshakeClientParameters = struct
  type t = { send_confirmation: (bool[@default false]) } [@@deriving yojson]
end

module UpdateFilesParameters = struct
  type t = {
    files: string list;
    invalidated: (string list[@default []]);
  }
  [@@deriving yojson]
end

module DisplayTypeErrorsParameters = struct
  type t = { files: string list [@default []] } [@@deriving yojson]
end

module SaveOptions = struct
  type t = { include_text: bool option [@key "includeText"] [@default None] } [@@deriving yojson]
end

module TextDocumentSyncOptions = struct
  module Kind = struct
    type t =
      | None_
      | Full
      | Incremental

    let get_change = function
      | None_ -> 0
      | Full -> 1
      | Incremental -> 2
  end

  type t = {
    open_close: bool option; [@key "openClose"] [@default None]
    change: int option; [@key "change"] [@default None]
    will_save: bool option; [@key "willSave"] [@default None]
    will_save_wait_until: bool option; [@key "willSaveWaitUntil"] [@default None]
    save: SaveOptions.t option; [@key "save"] [@default None]
  }
  [@@deriving yojson]
end

module CompletionOptions = struct
  type t = {
    resolve_provider: bool option; [@key "resolveProvider"] [@default None]
    trigger_characters: string list option; [@key "triggerCharacters"] [@default None]
  }
  [@@deriving yojson]
end

module SignatureHelpOptions = struct
  type t = { trigger_characters: string list option [@key "triggerCharacters"] [@default None] }
  [@@deriving yojson]
end

module CodeLensOptions = struct
  type t = { resolve_provider: bool option [@key "resolveProvider"] [@default None] }
  [@@deriving yojson]
end

module DocumentOnTypeFormattingOptions = struct
  type t = {
    first_trigger_character: string; [@key "firstTriggerCharacter"]
    more_trigger_character: string list option; [@key "moreTriggerCharacter"] [@default None]
  }
  [@@deriving yojson]
end

module DocumentLinkOptions = struct
  type t = { resolve_provider: bool option [@key "resolveProvider"] [@default None] }
  [@@deriving yojson]
end

module ExecuteCommandOptions = struct
  type t = { commands: string list [@key "commands"] } [@@deriving yojson]
end

module CodeActionOptions = struct
  type t = { codeActionKinds: string list [@key "codeActionKind"] } [@@deriving yojson]
end

module TextEdit = struct
  type t = {
    range: Range.t; [@key "range"]
    newText: string; [@key "newText"]
  }
  [@@deriving yojson, eq, show]
end

module WorkspaceEditChanges = struct
  type t = {
    uri: DocumentUri.t;
    textEdit: TextEdit.t list;
  }
  [@@deriving yojson, eq, show]

  let to_yojson : t -> Yojson.Safe.json =
   fun { uri; textEdit = edits } ->
    let open Core in
    let edits = List.map edits ~f:TextEdit.to_yojson in
    `Assoc [uri, `List edits]
end

module WorkspaceEdit = struct
  type t = { changes: WorkspaceEditChanges.t option [@default None] } [@@deriving yojson, eq, show]
end

(* This will conflict with the already existing Command.Spec *)
module Command_ = struct
  type t = {
    title: string;
    command: string;
    arguments: CommandArguments.t list;
  }
  [@@deriving yojson]
end

module CodeAction = struct
  type t = {
    title: string; [@key "title"]
    kind: string option; [@key "kind"] [@default None]
    diagnostics: Diagnostic.t list option; [@key "diagnostics"] [@default None]
    command: Command_.t option; [@key "command"] [@default None]
  }
  [@@deriving yojson]
end

module ServerCapabilities = struct
  module type S = sig
    type t = {
      text_document_sync: TextDocumentSyncOptions.t option;
      hover_provider: bool option;
      completion_provider: CompletionOptions.t option;
      signature_help_provider: SignatureHelpOptions.t option;
      definition_provider: bool option;
      references_provider: bool option;
      document_highlight_provider: bool option;
      document_symbol_provider: bool option;
      workspace_symbol_provider: bool option;
      code_action_provider: CodeActionOptions.t option;
      code_lens_provider: CodeLensOptions.t option;
      document_formatting_provider: bool option;
      document_range_formatting_provider: bool option;
      document_on_type_formatting_provider: DocumentOnTypeFormattingOptions.t option;
      rename_provider: bool option;
      document_link_provider: DocumentLinkOptions.t option;
      execute_command_provider: ExecuteCommandOptions.t option;
      experimental: experimental option;
      rage_provider: bool option;
    }

    and experimental [@@deriving yojson]
  end

  module Make (AnyExperimental : ToAny) : S with type experimental = AnyExperimental.t = struct
    type t = {
      text_document_sync: TextDocumentSyncOptions.t option;
          [@key "textDocumentSync"] [@default None]
      hover_provider: bool option; [@key "hoverProvider"] [@default None]
      completion_provider: CompletionOptions.t option; [@key "completionProvider"] [@default None]
      signature_help_provider: SignatureHelpOptions.t option;
          [@key "signatureHelpProvider"] [@default None]
      definition_provider: bool option; [@key "definitionProvider"] [@default None]
      references_provider: bool option; [@key "referencesProvider"] [@default None]
      document_highlight_provider: bool option; [@key "documentHighlightProvider"] [@default None]
      document_symbol_provider: bool option; [@key "documentSymbolProvider"] [@default None]
      workspace_symbol_provider: bool option; [@key "workspaceSymbolProvider"] [@default None]
      code_action_provider: CodeActionOptions.t option; [@key "codeActionProvider"] [@default None]
      code_lens_provider: CodeLensOptions.t option; [@key "codeLensProvider"] [@default None]
      document_formatting_provider: bool option; [@key "documentFormattingProvider"] [@default None]
      document_range_formatting_provider: bool option;
          [@key "documentRangeFormattingProvider"] [@default None]
      document_on_type_formatting_provider: DocumentOnTypeFormattingOptions.t option;
          [@key "documentOnTypeFormattingProvider"] [@default None]
      rename_provider: bool option; [@key "renameProvider"] [@default None]
      document_link_provider: DocumentLinkOptions.t option;
          [@key "documentLinkProvider"] [@default None]
      execute_command_provider: ExecuteCommandOptions.t option;
          [@key "executeCommandProvider"] [@default None]
      experimental: experimental option; [@key "experimental"] [@default None]
      rage_provider: bool option; [@key "rageProvider"] [@default None]
    }

    and experimental = AnyExperimental.t [@@deriving yojson]
  end
end

module ClientCapabilities = struct
  module DynamicRegistration = struct
    type t = { dynamic_registration: bool option [@key "dynamicRegistration"] [@default None] }
    [@@deriving of_yojson { strict = false }]
  end

  module WorkspaceClientCapabilities = struct
    type t = {
      apply_edit: bool option; [@key "applyEdit"] [@default None]
      workspace_edit: DynamicRegistration.t option; [@key "workspaceEdit"] [@default None]
      did_change_configuration: DynamicRegistration.t option;
          [@key "didChangeConfiguration"] [@default None]
      did_change_watched_files: DynamicRegistration.t option;
          [@key "didChangeWatchedFiles"] [@default None]
      symbol: DynamicRegistration.t option; [@key "symbol"] [@default None]
      execute_command: DynamicRegistration.t option; [@key "executeCommand"] [@default None]
      workspace_folders: bool option; [@key "workspaceFolders"] [@default None]
      configuration: bool option; [@key "configuration"] [@default None]
    }
    (* strict is false: Nuclide LSP sends nonstandard fields *)
    [@@deriving of_yojson { strict = false }]
  end

  module CompletionItemKind = struct
    type t = { value_set: int list option [@key "valueSet"] [@default None] } [@@deriving of_yojson]
  end

  module TextDocumentClientCapabilities = struct
    type synchronization = {
      dynamic_registration: bool option; [@key "dynamicRegistration"] [@default None]
      will_save: bool option; [@key "willSave"] [@default None]
      will_save_wait_until: bool option; [@key "willSaveWaitUntil"] [@default None]
      did_save: bool option; [@key "didSave"] [@default None]
    }
    [@@deriving of_yojson { strict = false }]

    type completion_item = {
      snippet_support: bool option; [@key "snippetSupport"] [@default None]
      commit_characters_support: bool option; [@key "commitCharactersSupport"] [@default None]
    }
    [@@deriving of_yojson { strict = false }]

    type completion = {
      dynamic_registration: bool option; [@key "dynamicRegistration"] [@default None]
      completion_item: completion_item option; [@key "completionItem"] [@default None]
      completion_item_kind: CompletionItemKind.t option; [@key "completionItemKind"] [@default None]
      context_support: bool option; [@key "contextSupport"] [@default None]
    }
    [@@deriving of_yojson { strict = false }]

    type publish_diagnostics = {
      related_information: bool option; [@key "relatedInformation"] [@default None]
    }
    [@@deriving of_yojson]

    type t = {
      synchronization: synchronization option; [@key "synchronization"] [@default None]
      completion: completion option; [@key "completion"] [@default None]
      hover: DynamicRegistration.t option; [@key "hover"] [@default None]
      signature_help: DynamicRegistration.t option; [@key "signatureHelp"] [@default None]
      references: DynamicRegistration.t option; [@key "references"] [@default None]
      document_highlight: DynamicRegistration.t option; [@default None] [@key "documentHighlight"]
      document_symbol: DynamicRegistration.t option; [@key "documentSymbol"] [@default None]
      formatting: DynamicRegistration.t option; [@key "formatting"] [@default None]
      range_formatting: DynamicRegistration.t option; [@key "rangeFormatting"] [@default None]
      on_type_formatting: DynamicRegistration.t option; [@key "onTypeFormatting"] [@default None]
      definition: DynamicRegistration.t option; [@key "definition"] [@default None]
      code_action: DynamicRegistration.t option; [@key "codeAction"] [@default None]
      code_lens: DynamicRegistration.t option; [@key "codeLens"] [@default None]
      document_link: DynamicRegistration.t option; [@key "documentLink"] [@default None]
      rename: DynamicRegistration.t option; [@key "rename"] [@default None]
      type_definition: DynamicRegistration.t option; [@key "typeDefinition"] [@default None]
      implementation: DynamicRegistration.t option; [@key "implementation"] [@default None]
      color_provider: DynamicRegistration.t option; [@key "colorProvider"] [@default None]
      folding_range: DynamicRegistration.t option; [@key "foldingRange"] [@default None]
      publish_diagnostics: publish_diagnostics option; [@key "publishDiagnostics"] [@default None]
    }
    [@@deriving of_yojson { strict = false }]
  end

  module WindowClientCapabilities = struct
    type t = {
      progress: DynamicRegistration.t option; [@key "progress"] [@default None]
      action_required: DynamicRegistration.t option; [@key "actionRequired"] [@default None]
      status: DynamicRegistration.t option; [@key "status"] [@default None]
    }
    [@@deriving of_yojson { strict = false }]
  end

  module type S = sig
    type t = {
      workspace: WorkspaceClientCapabilities.t option;
      text_document: TextDocumentClientCapabilities.t option;
      experimental: experimental option;
      window: WindowClientCapabilities.t option;
    }

    and experimental [@@deriving of_yojson]
  end

  module Make (AnyExperimental : OfAny) : S with type experimental = AnyExperimental.t = struct
    type t = {
      workspace: WorkspaceClientCapabilities.t option; [@key "workspace"] [@default None]
      text_document: TextDocumentClientCapabilities.t option; [@key "textDocument"] [@default None]
      experimental: experimental option; [@key "experimental"] [@default None]
      window: WindowClientCapabilities.t option; [@key "window"] [@default None]
    }

    and experimental = AnyExperimental.t [@@deriving of_yojson { strict = false }]
  end
end

(** Types for protocol messages. There are three kinds of messages: A Request, Response, and a
    Notification. *)

(** Request Message *)

module RequestMessage = struct
  module type S = sig
    type t = {
      jsonrpc: string;
      id: RequestId.t;
      method_: string;
      parameters: parameters option;
    }

    and parameters [@@deriving of_yojson]
  end

  module Make (AnyParameters : OfAny) : S with type parameters = AnyParameters.t = struct
    type t = {
      jsonrpc: string; [@key "jsonrpc"]
      id: RequestId.t; [@key "id"]
      method_: string; [@key "method"]
      parameters: parameters option; [@key "params"] [@default None]
    }

    and parameters = AnyParameters.t [@@deriving of_yojson]
  end
end

(** Response Message *)

module ResponseError = struct
  module type S = sig
    type t = {
      code: int;
      message: string;
      data: data option;
    }

    and data [@@deriving yojson]
  end

  module Make (AnyData : ToAny) : S with type data = AnyData.t = struct
    type t = {
      code: int; [@key "code"]
      message: string; [@key "message"]
      data: data option; [@key "data"] [@default None]
    }

    and data = AnyData.t [@@deriving yojson]
  end
end

module ResponseMessage = struct
  module type S = sig
    type t = {
      jsonrpc: string;
      id: RequestId.t;
      result: result option;
      error: error option;
    }

    and result

    and error [@@deriving yojson]
  end

  (** A response message is parameterized by a result which can be [Any] option, and a response
      error which can contain an [Any] option data *)
  module Make (AnyResult : ToAny) (ResponseError : ResponseError.S) :
    S with type result = AnyResult.t = struct
    type t = {
      jsonrpc: string; [@key "jsonrpc"]
      id: RequestId.t; [@key "id"]
      result: result option; [@key "result"]
      error: error option; [@key "error"] [@default None]
    }

    and result = AnyResult.t

    and error = ResponseError.t [@@deriving yojson]
  end
end

(** Notification Message *)

module NotificationMessage = struct
  module type S = sig
    type t = {
      jsonrpc: string;
      method_: string;
      parameters: parameters option;
    }

    and parameters [@@deriving yojson]
  end

  module Make (AnyParameters : ToAny) : S with type parameters = AnyParameters.t = struct
    type t = {
      jsonrpc: string; [@key "jsonrpc"]
      method_: string; [@key "method"]
      parameters: parameters option; [@key "params"] [@default None]
    }

    and parameters = AnyParameters.t [@@deriving yojson]
  end
end

module Message = struct
  module type S = sig
    type t = {
      jsonrpc: string;
      method_: string;
      parameters: parameters option;
      id: RequestId.t;
    }

    and parameters [@@deriving yojson]
  end

  module Make (AnyParameters : ToAny) : S with type parameters = AnyParameters.t = struct
    type t = {
      jsonrpc: string; [@key "jsonrpc"]
      method_: string; [@key "method"]
      parameters: parameters option; [@key "params"] [@default None]
      id: RequestId.t; [@key "id"]
    }

    and parameters = AnyParameters.t [@@deriving yojson]
  end
end

(** Requests *)

(** An InitializeRequest Request message cf.
    https://github.com/Microsoft/language-server-protocol/blob/master/protocol.md#initialize-request *)
module InitializeRequest = struct
  module InitializeParameters = struct
    (* A None type module is used for the experimental Any type possible in ClientCapabilities *)
    module ClientCapabilities = ClientCapabilities.Make (None)

    module TraceSetting = struct
      type t =
        | Off
        | Messages
        | Verbose

      let of_yojson = function
        | `String "off" -> Ok Off
        | `String "messages" -> Ok Messages
        | `String "verbose" -> Ok Verbose
        | json -> Error ("JSON trace setting unsupported: " ^ Yojson.Safe.to_string json)
    end

    (* Example: [rootPath] is not required so we set a @default attribute for yojson deriving. This
       means if [rootPath] is not in the JSON, it maps to None. [rootUri] is required, so it does
       not have an @default attribute. But, it may be null, so it remains an option type that maps
       to None if the JSON value is `Null.*)
    type t = {
      process_id: int option; [@default None] [@key "processId"]
      root_path: string option; [@default None] [@key "rootPath"]
      root_uri: DocumentUri.t option; [@key "rootUri"]
      initialization_options: None.t option; [@default None] [@key "initializationOptions"]
      capabilities: ClientCapabilities.t; [@key "capabilities"]
      trace: TraceSetting.t option; [@default None] [@key "trace"]
      workspaceFolders: WorkspaceFolder.t list option; [@default None] [@key "workspaceFolders"]
    }
    [@@deriving of_yojson]
  end

  include RequestMessage.Make (InitializeParameters)
end

module ShutdownRequest = struct
  module ShutdownParameters = None
  include RequestMessage.Make (ShutdownParameters)
end

module TextDocumentDefinitionRequest = RequestMessage.Make (TextDocumentPositionParameters)
module CodeActionRequest = RequestMessage.Make (CodeActionParameters)
module ExecuteCommandRequest = RequestMessage.Make (ExecuteCommandParameters)

module RageRequest = struct
  module RageParameters = None
  include RequestMessage.Make (RageParameters)
end

module CompletionRequest = RequestMessage.Make (CompletionParameters)
module HoverRequest = RequestMessage.Make (TextDocumentPositionParameters)
module DidCloseTextDocument = NotificationMessage.Make (DidCloseTextDocumentParameters)
module DidSaveTextDocument = NotificationMessage.Make (DidSaveTextDocumentParameters)
module DidOpenTextDocument = NotificationMessage.Make (DidOpenTextDocumentParameters)
module DidChangeTextDocument = NotificationMessage.Make (DidChangeTextDocumentParameters)
module ShowMessage = NotificationMessage.Make (ShowMessageParameters)
module HandshakeServer = NotificationMessage.Make (HandshakeServerParameters)
module HandshakeClient = NotificationMessage.Make (HandshakeClientParameters)
module UpdateFiles = NotificationMessage.Make (UpdateFilesParameters)
module DisplayTypeErrors = NotificationMessage.Make (DisplayTypeErrorsParameters)
module TypeCoverage = RequestMessage.Make (TypeCoverageParameters)
module ShowStatus = Message.Make (ShowStatusParameters)

(* A notification request sent from the client to the server. *)
module ShowStatusRequest = NotificationMessage.Make (ShowStatusParameters)

(** Responses *)

(** An InitializeResponse Response message *)
module InitializeResponse = struct
  (* A Null type module is used for the experimental Any type possible in ServerCapabilities *)
  module InitializeResult = struct
    module ServerCapabilities = ServerCapabilities.Make (Null)

    type t = { capabilities: ServerCapabilities.t } [@@deriving yojson]
  end

  (* The data field for InitializeResult consists of a retry value *)
  module InitializeError = ResponseError.Make (struct
    type t = { retry: bool } [@@deriving yojson]
  end)

  include ResponseMessage.Make (InitializeResult) (InitializeError)
end

module ShutdownResponse = struct
  module ShutdownResult = Null
  module ShutdownError = ResponseError.Make (Null)
  include ResponseMessage.Make (ShutdownResult) (ShutdownError)
end

module CompletionItems = struct
  module Kind = struct
    type t =
      | Function
      | Variable
    [@@deriving eq, show]

    let to_yojson : t -> Yojson.Safe.json = function
      | Function -> `Int 3
      | Variable -> `Int 6


    let of_yojson : Yojson.Safe.json -> (t, string) Result.result = function
      | `Int 3 -> Result.Ok Function
      | `Int 6 -> Result.Ok Variable
      | _ -> Result.Error "Invalid JSON"
  end

  type item = {
    label: string;
    kind: Kind.t;
    detail: string;
    textEdit: TextEdit.t;
  }
  [@@deriving show, yojson]

  type t = item list [@@deriving show, yojson]
end

module CompletionResponse = struct
  module CompletionError = ResponseError.Make (Null)
  include ResponseMessage.Make (CompletionItems) (CompletionError)
end

module TextDocumentDefinitionResponse = struct
  module DefinitionResult = struct
    type t = Location.t list [@@deriving yojson]
  end

  module DefinitionError = ResponseError.Make (Null)
  include ResponseMessage.Make (DefinitionResult) (DefinitionError)
end

module MarkedString = struct
  type t = {
    language: string;
    value: string;
  }
  [@@deriving yojson]
end

module HoverResponse = struct
  module HoverResult = struct
    type t = {
      contents: MarkedString.t;
      range: Range.t option;
    }
    [@@deriving yojson]
  end

  module HoverError = ResponseError.Make (Null)
  include ResponseMessage.Make (HoverResult) (HoverError)
end

module CodeActionResponse = struct
  module CodeActionResult = struct
    type t = CodeAction.t list [@@deriving yojson]
  end

  module CodeActionError = ResponseError.Make (Null)
  include ResponseMessage.Make (CodeActionResult) (CodeActionError)
end

module TypeCoverageResponse = struct
  module TypeCoverageResult = struct
    type t = { coveredPercent: int } [@@deriving yojson]
  end

  module TypeCoverageError = ResponseError.Make (Null)
  include ResponseMessage.Make (TypeCoverageResult) (TypeCoverageError)
end

module RageResponse = struct
  module RageResult = struct
    type rageItem = {
      title: string option;
      data: string;
    }
    [@@deriving yojson]

    type t = rageItem list [@@deriving yojson]
  end

  module RageError = ResponseError.Make (Null)
  include ResponseMessage.Make (RageResult) (RageError)
end

module ApplyWorkspaceEditParameters = struct
  type t = { edit: WorkspaceEdit.t } [@@deriving yojson]
end

(** Notifications *)

module PublishDiagnostics = NotificationMessage.Make (PublishDiagnosticsParameters)
(** A PublishDiagnostics Notification *)

module ApplyWorkspaceEdit = Message.Make (ApplyWorkspaceEditParameters)

(** Namespaces *)

(** ErrorCodes possible in responses *)
module ErrorCodes = struct
  type t =
    | ParseError
    | InvalidRequest
    | MethodNotFound
    | InvalidParams
    | InternalError
    | ServerErrorStart
    | ServerErrorEnd
    | ServerNotInitialized
    | UnknownErrorCode
    | RequestCancelled

  let to_yojson : t -> Yojson.Safe.json = function
    | ParseError -> `Int (-32700)
    | InvalidRequest -> `Int (-32600)
    | MethodNotFound -> `Int (-32601)
    | InvalidParams -> `Int (-32602)
    | InternalError -> `Int (-32603)
    | ServerErrorStart -> `Int (-32099)
    | ServerErrorEnd -> `Int (-32000)
    | ServerNotInitialized -> `Int (-32002)
    | UnknownErrorCode -> `Int (-32001)
    | RequestCancelled -> `Int (-32800)
end
