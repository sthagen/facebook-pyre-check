/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

%{
  open Core

  open Pyre
  module Location = Ast.Location
  open ParserExpression
  open ParserStatement

  (* This weird-looking empty module definition is to work around a nasty issue when *)
  (* using menhir infer mode with dune: https://github.com/ocaml/dune/issues/2450 *)
  [@@@warning "-60"]
  module PyreMenhirParser = struct end
  [@@@warning "+60"]

  let with_decorators decorators decoratee =
    match decoratee with
    | { Node.location; value = Statement.Class value } ->
        let decorated = { value with Class.decorators; } in
        { Node.location; value = Statement.Class decorated }
    | { Node.location; value = Statement.Define ({ Define.signature; _} as value) } ->
        let signature =
          { signature with Define.Signature.decorators }
        in
        let decorated = { value with Define.signature } in
        { Node.location; value = Statement.Define decorated }
    | _ -> raise (Failure "Cannot decorate statement")

  type entry =
    | Entry of Dictionary.Entry.t
    | Item of Expression.t
    | Comprehension of Comprehension.Generator.t

  type entries = {
      entries: Dictionary.Entry.t list;
      items: Expression.t list;
      comprehensions: Comprehension.Generator.t list;
    }


  let add_entry so_far = function
    | Entry entry ->
        { so_far with entries = entry :: so_far.entries }
    | Item item ->
        { so_far with items = item :: so_far.items }
    | Comprehension comprehension ->
        { so_far with comprehensions = comprehension :: so_far.comprehensions }

  (* Helper function to combine a start position of type Lexing.position and
   * stop position of type Location.position. *)
  let location_create_with_stop ~start ~stop =
    let position = Location.create ~start ~stop:start in
    { position with Location.stop = stop }

  let binary_operator
    ~left:({ Node.location; _ } as left)
    ~operator
    ~right:({ Node.location = { Location.stop; _ }; _ } as right) =
    Expression.BinaryOperator { BinaryOperator.left; operator; right }
    |> Node.create ~location:{ location with Location.stop }

  let slice ~lower ~upper ~step ~bound_colon ~step_colon =
    let increment { Location.start; stop; _ } =
      let increment ({ Location.column; _ } as position) =
        { position with Location.column = column + 1 }
      in
      { Location.start = increment start; stop = increment stop }
    in
    let lower_location =
      match lower with
      | Some lower -> lower.Node.location
      | None -> Location.create ~start:bound_colon ~stop:bound_colon
    in
    let step_location =
      match step with
      | Some step -> step.Node.location
      | None ->
          begin
            match step_colon with
            | Some colon -> Location.create ~start:colon ~stop:colon |> increment
            | None ->
                begin
                  match upper with
                  | Some { Node.location = ({ Location.stop; _ } as location); _ } ->
                      { location with Location.start = stop }
                  | None -> Location.create ~start:bound_colon ~stop:bound_colon |> increment
                end
          end
    in
    let slice_location =
      { lower_location with Location.stop = step_location.Location.stop  }
    in
    Expression.Slice { Slice.start = lower; stop = upper; step }
    |> Node.create ~location:slice_location


  let create_ellipsis (start, stop) =
    let location = Location.create ~start ~stop in
    Node.create (Expression.Constant AstExpression.Constant.Ellipsis) ~location


  let subscript_access subscript =
    let head, subscripts, subscript_location = subscript in
    let location = Node.location head in
    let index =
      match subscripts with
      | [] -> failwith "subscript can never be empty"
      | [subscript] -> subscript
      | subscripts ->
         let { Node.location = { Location.start; _ }; _ } = List.hd_exn subscripts  in
         let { Node.location = { Location.stop; _ }; _ } = List.last_exn subscripts in
         { Node.location = { Location.start; stop }; value = Expression.Tuple subscripts }
    in
    Expression.Subscript { Subscript.base = head; index }
    |> Node.create ~location:{ subscript_location with Location.start = location.Location.start }

  let with_annotation ~parameter ~annotation =
    let value =
      let { Node.value = { Parameter.annotation = existing; _ } as value; _ } = parameter in
      let annotation =
        match existing, annotation with
        | None, Some annotation -> Some annotation
        | _ -> existing
      in
      { value with Parameter.annotation }
    in
    { parameter with Node.value }

  let create_literal_substring (string_position, (start, stop), value) =
    string_position,
    {
      Substring.kind = Substring.Kind.Literal;
      location = Location.create ~start ~stop;
      value;
    }

  let create_raw_format_substring (string_position, (start, stop), value) =
    string_position,
    {
      Substring.kind = Substring.Kind.RawFormat;
      location = Location.create ~start ~stop;
      value;
    }

  let create_mixed_string = function
    | [] -> Expression.Constant
              (AstExpression.Constant.String {
                   AstExpression.StringLiteral.value = "";
                   kind = AstExpression.StringLiteral.String
              })
    | [ { Substring.kind = Substring.Kind.Literal; value; _ } ] ->
       Expression.Constant
         (AstExpression.Constant.String {
              AstExpression.StringLiteral.value;
              kind = AstExpression.StringLiteral.String
         })
    | _ as pieces ->
       let is_all_literal = List.for_all ~f:(fun { Substring.kind; _ } ->
          match kind with
          | Substring.Kind.Literal -> true
          | Substring.Kind.RawFormat -> false
        )
        in
        if is_all_literal pieces then
          let value =
            List.map pieces ~f:(fun { Substring.value; _ } -> value)
            |> String.concat ~sep:""
          in
          Expression.Constant
            (AstExpression.Constant.String {
                 AstExpression.StringLiteral.value;
                 kind = AstExpression.StringLiteral.String
            })
        else
          Expression.FormatString pieces
%}

(* The syntactic junkyard. *)
%token <Lexing.position> EXCEPT_STAR
%token <Lexing.position * Lexing.position> ASTERIKS
%token <Lexing.position> AWAIT
%token <Lexing.position> COLON
%token <Lexing.position> DEDENT
%token <Lexing.position * Lexing.position> DOT
%token <Lexing.position> LEFTBRACKET
%token <Lexing.position> LEFTCURLY
%token <Lexing.position> LEFTPARENS
%token <Lexing.position> MINUS
%token <Lexing.position> NEWLINE
%token <Lexing.position> NOT
%token <Lexing.position> PLUS
%token <Lexing.position> SLASH
(* the RIGHT* lexemes only contain the end position. *)
%token <Lexing.position> RIGHTBRACKET
%token <Lexing.position> RIGHTCURLY
%token <Lexing.position> RIGHTPARENS
%token <Lexing.position> TILDE

%token <(Lexing.position * Lexing.position) * string list * string> SIGNATURE_COMMENT
%token <(Lexing.position * Lexing.position) * string> ANNOTATION_COMMENT

%token AMPERSAND
%token AMPERSANDEQUALS
%token AND
%token ASTERIKSASTERIKSEQUALS
%token ASTERIKSEQUALS
%token AT
%token ATEQUALS
%token BAR
%token BAREQUALS
%token COMMA
%token COLONEQUALS
%token DOUBLEEQUALS
%token EOF
%token EQUALS
%token EXCLAMATIONMARK
%token HAT
%token HATEQUALS
%token INDENT
%token IS
%token ISNOT
%token LEFTANGLE
%token LEFTANGLEEQUALS
%token LEFTANGLELEFTANGLE
%token LEFTANGLELEFTANGLEEQUALS
%token MINUSEQUALS
%token OR
%token PERCENT
%token PERCENTEQUALS
%token PLUSEQUALS
%token RIGHTANGLE
%token RIGHTANGLEEQUALS
%token RIGHTANGLERIGHTANGLE
%token RIGHTANGLERIGHTANGLEEQUALS
%token SEMICOLON
%token SLASHEQUALS
%token SLASHSLASHEQUALS

(* Declarations. *)
%token <Lexing.position * Lexing.position> ASYNC
%token <Lexing.position> CLASS
%token <Lexing.position> DEFINE
%token <Lexing.position> LAMBDA

(* Values. *)
%token <(Lexing.position * Lexing.position) * float> FLOAT
%token <(Lexing.position * Lexing.position) * float> COMPLEX
%token <(Lexing.position * Lexing.position) * int> INTEGER
%token <(Lexing.position * Lexing.position) * (Lexing.position * Lexing.position) * string> BYTES
%token <(Lexing.position * Lexing.position) * (Lexing.position * Lexing.position) * string> FORMAT
%token <(Lexing.position * Lexing.position) * string> IDENTIFIER
%token <(Lexing.position * Lexing.position) * (Lexing.position * Lexing.position) * string> STRING
%token <(Lexing.position * Lexing.position)> ELLIPSES
%token <(Lexing.position * Lexing.position)> FALSE
%token <(Lexing.position * Lexing.position)> TRUE
%token <(Lexing.position * Lexing.position)> NONE

(* Control. *)
%token <Lexing.position> ASSERT
%token <Lexing.position * Lexing.position> BREAK
%token <Lexing.position * Lexing.position> CONTINUE
%token <Lexing.position> DELETE
%token <Lexing.position> ELSEIF
%token <Lexing.position> FOR
%token <Lexing.position> FROM
%token <Lexing.position> GLOBAL
%token <Lexing.position> IF
%token <Lexing.position> IMPORT
%token <Lexing.position> NONLOCAL
%token <Lexing.position * Lexing.position> PASS
%token <Lexing.position * Lexing.position> RAISE
%token <Lexing.position * Lexing.position> RETURN
%token <Lexing.position> TRY
%token <Lexing.position> WITH
%token <Lexing.position> WHILE
%token <Lexing.position * Lexing.position> YIELD
%token AS
%token ELSE
%token <Lexing.position> EXCEPT
%token FINALLY
%token IN

%left LEFTANGLELEFTANGLE RIGHTANGLERIGHTANGLE
%left NOT
%left BAR
%left HAT
%left AMPERSAND
%left PLUS MINUS
%left ASTERIKS PERCENT SLASH
%left AWAIT
%left TILDE
%left AT
%left DOT

%nonassoc LEFTPARENS


%start <ParserStatement.Statement.statement Ast.Node.t list> parse_module
%start <ParserStatement.Expression.expression Ast.Node.t> parse_expression

%type <ParserStatement.Expression.expression Ast.Node.t> and_test
%type <ParserExpression.Call.Argument.t> argument
%type <ParserExpression.Call.Argument.t list> arguments
%type <ParserStatement.Statement.statement Ast.Node.t> async_statement
%type <ParserStatement.Expression.expression Ast.Node.t> atom
%type <ParserExpression.Call.Argument.t list> bases
%type <Location.t * ParserStatement.Statement.statement Ast.Node.t list> block
%type <Location.t * ParserStatement.Statement.statement Ast.Node.t list> block_or_stub_body
%type <ParserStatement.Expression.expression Ast.Node.t> comparison
%type <Ast.Expression.ComparisonOperator.operator * ParserStatement.Expression.expression Ast.Node.t> comparison_operator
%type <ParserStatement.Statement.statement Ast.Node.t> compound_statement
%type <ParserExpression.Comprehension.Generator.t> comprehension
%type <ParserStatement.Expression.expression Ast.Node.t> condition
%type <Location.t * ParserStatement.Statement.statement> conditional
%type <ParserStatement.Statement.statement Ast.Node.t> decorated_statement
%type <ParserStatement.Expression.expression Ast.Node.t> decorator
%type <ParserExpression.Parameter.t list> define_parameters
%type <string> ellipsis_or_dot
%type <ParserStatement.Expression.expression Ast.Node.t> expression
%type <ParserStatement.Expression.expression Ast.Node.t> expression_list
%type <Location.AstReference.t option> from
%type <string> from_string
%type <ParserStatement.Expression.expression Ast.Node.t> generator
%type <Location.t * ParserStatement.Try.Handler.t> handler
%type <Location.t * ParserStatement.Try.Handler.t> group_handler
%type <Location.t * string> identifier
%type <Location.t * Ast.Statement.Import.import> import
%type <Location.t * Ast.Statement.Import.import Ast.Node.t list> imports
%type <Lexing.position list> list(NEWLINE)
%type <ParserExpression.Expression.t list> list(condition)
%type <(Location.t * ParserStatement.Try.Handler.t) list> list(handler)
%type <(Location.t * ParserStatement.Try.Handler.t) list> list(group_handler)
%type <((Lexing.position * Lexing.position) * ParserExpression.Substring.t) list> mixed_string
%type <Location.t * ParserStatement.Statement.statement Ast.Node.t list> named_optional_block(ELSE)
%type <Location.t * ParserStatement.Statement.statement Ast.Node.t list> named_optional_block(FINALLY)
%type <((Lexing.position * Lexing.position) * (Lexing.position * Lexing.position) * string) list> nonempty_list(BYTES)
%type <Lexing.position list> nonempty_list(NEWLINE)
%type <(Ast.Expression.ComparisonOperator.operator * ParserStatement.Expression.expression Ast.Node.t) list> nonempty_list(comparison_operator)
%type <ParserExpression.Comprehension.Generator.t list> nonempty_list(comprehension)
%type <ParserStatement.Expression.t list> nonempty_list(decorator)
%type <string list> nonempty_list(ellipsis_or_dot)
%type <ParserStatement.Expression.expression Ast.Node.t> not_test
%type <((Lexing.position * Lexing.position) * string) option> option(ANNOTATION_COMMENT)
%type <unit option> option(COMMA)
%type <((Lexing.position * Lexing.position) * string list * string) option> option(SIGNATURE_COMMENT)
%type <ParserExpression.Expression.t option> option(annotation)
%type <ParserExpression.Expression.t option> option(comment_annotation)
%type <ParserStatement.Expression.t option> option(raise_from)
%type <ParserStatement.Expression.expression Ast.Node.t option> option(return_annotation)
%type <ParserStatement.Expression.expression Ast.Node.t option> option(test)
%type <ParserStatement.Expression.t option> option(test_list)
%type <ParserStatement.Expression.expression Ast.Node.t> or_test
%type <ParserExpression.Call.Argument.t list> parser_generator_separated_list(COMMA,argument)
%type <(Location.t * string) list> parser_generator_separated_list(COMMA,identifier)
%type <(Location.t * Ast.Statement.Import.import) list> parser_generator_separated_list(COMMA,import)
%type <ParserExpression.Parameter.t list> parser_generator_separated_list(COMMA,lambda_parameter)
%type <ParserStatement.Expression.t list> parser_generator_separated_list(COMMA,subscript_key)
%type <ParserStatement.Expression.t list> parser_generator_separated_list(COMMA,test)
%type <(ParserStatement.Expression.t * ParserStatement.Expression.t option) list> parser_generator_separated_list(COMMA,with_item)
%type <(Location.t * string) list> parser_generator_separated_list(DOT,identifier)
%type <ParserStatement.Statement.statement Ast.Node.t list list> parser_generator_separated_list_of_lists(SEMICOLON,small_statement)
%type <(Location.t * string) list> parser_generator_separated_nonempty_list(COMMA,identifier)
%type <(Location.t * Ast.Statement.Import.import) list> parser_generator_separated_nonempty_list(COMMA,import)
%type <ParserStatement.Expression.t list> parser_generator_separated_nonempty_list(COMMA,subscript_key)
%type <(ParserStatement.Expression.t * ParserStatement.Expression.t option) list> parser_generator_separated_nonempty_list(COMMA,with_item)
%type <(Location.t * string) list> parser_generator_separated_nonempty_list(DOT,identifier)
%type <ParserStatement.Statement.statement Ast.Node.t list list> parser_generator_separated_nonempty_list_of_lists(SEMICOLON,small_statement)
%type <ParserStatement.Expression.expression Ast.Node.t> raise_from
%type <Location.t * Location.AstReference.t> reference
%type <ParserStatement.Expression.t list> separated_nonempty_list(COMMA,expression)
%type <ParserStatement.Expression.expression Ast.Node.t list * bool> separated_nonempty_list_indicator(COMMA,expression)
%type <ParserStatement.Expression.expression Ast.Node.t list * bool> separated_nonempty_list_indicator(COMMA,test)
%type <ParserStatement.Expression.expression Ast.Node.t list * bool> separated_nonempty_list_indicator_tail(COMMA,expression)
%type <ParserStatement.Expression.expression Ast.Node.t list * bool> separated_nonempty_list_indicator_tail(COMMA,test)
%type <ParserStatement.Expression.expression Ast.Node.t> set_or_dictionary
%type <entry> set_or_dictionary_entry
%type <entries> set_or_dictionary_maker
%type <Location.t * ParserStatement.Statement.statement Ast.Node.t list> simple_statement
%type <ParserStatement.Statement.statement Ast.Node.t list> small_statement
%type <Location.t * ParserStatement.Statement.statement Ast.Node.t list> statement
%type <Location.t * ParserStatement.Statement.statement Ast.Node.t list> statements
%type <ParserStatement.Expression.expression Ast.Node.t> subscript_key
%type <(value:ParserStatement.Expression.expression Ast.Node.t -> annotation:ParserExpression.Expression.t option -> index_in_chain:int option -> ParserStatement.Statement.statement Ast.Node.t) list> targets
%type <ParserStatement.Expression.expression Ast.Node.t> test
%type <ParserStatement.Expression.expression Ast.Node.t> test_list
%type <ParserStatement.Expression.expression Ast.Node.t> test_with_generator
%type <ParserStatement.Expression.expression Ast.Node.t> value
%type <ParserStatement.Expression.t * ParserStatement.Expression.t option> with_item
%type <ParserStatement.Expression.expression Ast.Node.t> yield_form
%%

parse_module:
  | statements = statements; EOF { snd statements }
  ;

parse_expression:
  | expression = expression; EOF { expression }
  ;

(* Statements. *)

statements:
  | { Location.any, [] }
  | NEWLINE; statements = statements { statements }
  | statement = statement; statements = statements {
      (* The recursion always terminates in the empty statement case. This logic avoids
       * propagating the end location information from there. *)
      let location =
        match (snd statements) with
        | [] -> fst statement
        | _ -> {(fst statement) with Location.stop = (fst statements).Location.stop;}
       in
      location, (snd statement)@(snd statements)
    }
  ;

statement:
  | statements = simple_statement { statements }
  | statement = compound_statement { statement.Node.location, [statement] }
  | statement = decorated_statement { statement.Node.location, [statement] }
  | statement = async_statement { statement.Node.location, [statement] }

simple_statement:
  | statements = parser_generator_separated_nonempty_list_of_lists(SEMICOLON, small_statement);
    NEWLINE {
      let flattened_statements = List.concat statements in
      let head = List.hd_exn flattened_statements in
      let last = List.last_exn flattened_statements in
      let location = {head.Node.location with Location.stop = Node.stop last} in
      location, flattened_statements
    }
  ;

small_statement:
  | target = test_list;
    operator = compound_operator;
    value = value {
      [{
        Node.location = {
          target.Node.location with Location.stop =
            value.Node.location.Location.stop;
        };
        value = Statement.AugmentedAssign {
          AugmentedAssign.target = target;
          operator;
          value;
        };
      }]
    }
  | target = test_list;
    annotation = annotation {
      [{
        Node.location = {
          target.Node.location with Location.stop =
            annotation.Node.location.Location.stop;
        };
        value = Statement.Assign {
          Assign.target = target;
          annotation = Some annotation;
          value = None;
          index_in_chain = None;
        };
      }]
    }
  | target = test_list;
    annotation = comment_annotation {
      [{
        Node.location = {
          target.Node.location with Location.stop =
            annotation.Node.location.Location.stop;
        };
        value = Statement.Assign {
          Assign.target = target;
          annotation = Some annotation;
          value = None;
          index_in_chain = None;
        };
      }]
    }
  | target = test_list;
    annotation = annotation;
    EQUALS;
    value = test_list {
      [{
        Node.location = {
          target.Node.location with Location.stop =
            value.Node.location.Location.stop;
        };
        value = Statement.Assign {
          Assign.target = target;
          annotation = Some annotation;
          value = Some value;
          index_in_chain = None;
        };
      }]
    }
  | target = test_list;
    annotation = annotation;
    EQUALS;
    value = value {
      [{
        Node.location = {
          target.Node.location with Location.stop =
            value.Node.location.Location.stop;
        };
        value = Statement.Assign {
          Assign.target = target;
          annotation = Some annotation;
          value = Some value;
          index_in_chain = None;
        };
      }]
    }
  | targets = targets; value = value; annotation = comment_annotation? {
      let is_chain = List.length targets > 1 in
      List.mapi ~f:(fun index target -> target ~value ~annotation ~index_in_chain:(Option.some_if is_chain index)) targets
  }
  | targets = targets; ellipsis = ELLIPSES {
      let value = create_ellipsis ellipsis in
      let is_chain = List.length targets > 1 in
      List.mapi ~f:(fun index target -> target ~value ~annotation:None ~index_in_chain:(Option.some_if is_chain index)) targets
    }
  | target = test_list;
    annotation = annotation;
    EQUALS;
    ellipsis = ELLIPSES {
      let ellipsis = create_ellipsis ellipsis in
      [{
        Node.location = {
          target.Node.location with Location.stop =
            ellipsis.Node.location.Location.stop;
        };
        value = Statement.Assign {
          Assign.target = target;
          annotation = Some annotation;
          value = Some ellipsis;
          index_in_chain = None;
        };
      }]
    }

  | start = ASSERT; test = test {
      [{
        Node.location = location_create_with_stop ~start ~stop:(Node.stop test);
        value = Statement.Assert { Assert.test = test; message = None }
      }]
    }
  | start = ASSERT; test = test;
    COMMA; message = test {
      [{
        Node.location = location_create_with_stop ~start ~stop:(Node.stop test);
        value = Statement.Assert { Assert.test = test; message = Some message }
      }]
    }

  | position = BREAK {
      let start, stop = position in
      [{ Node.location = Location.create ~start ~stop; value = Statement.Break }]
    }

  | position = CONTINUE {
      let start, stop = position in
      [{ Node.location = Location.create ~start ~stop; value = Statement.Continue }]
    }

  | test = test_list {
      [{ Node.location = test.Node.location; value = Statement.Expression test }]
    }

  | value = value {
      [{ Node.location = value.Node.location; value = Statement.Expression value }]
    }

  | start = GLOBAL; globals = parser_generator_separated_nonempty_list(COMMA, identifier) {
      let last = List.last_exn globals in
      let stop = (fst last).Location.stop in
      [{
        Node.location = location_create_with_stop ~start ~stop;
        value = Statement.Global (List.map globals ~f:snd);
      }]
    }

  | start = IMPORT; imports = imports; {
      [{
        Node.location = location_create_with_stop ~start ~stop:((fst imports).Location.stop);
        value = Statement.Import { Import.from = None; imports = snd imports };
      }]
    }
  | start = FROM; from = from; IMPORT; imports = imports {
      [{
        Node.location = location_create_with_stop ~start ~stop:((fst imports).Location.stop);
        value = Statement.Import {
          Import.from;
          imports = snd imports;
        };
      }]
    }

  | start = NONLOCAL; nonlocals = parser_generator_separated_nonempty_list(COMMA, identifier) {
      let stop = (fst (List.last_exn nonlocals)).Location.stop in
      [{
        Node.location = location_create_with_stop ~start ~stop;
        value = Statement.Nonlocal (List.map nonlocals ~f:snd);
      }]
    }

  | position = PASS {
      let start, stop = position in
      [{ Node.location = Location.create ~start ~stop; value = Statement.Pass }]
    }

  | position = RAISE; test = test_list?; raise_from = raise_from? {
      let start, stop = position in
      let location =
        match (test, raise_from) with
        | None, None -> Location.create ~start ~stop
        | Some node, None ->
          location_create_with_stop ~start ~stop:(Node.stop node)
        | _, Some { Node.location; _ } ->
          location_create_with_stop ~start ~stop:(location.Location.stop)
      in
      [{
        Node.location;
        value = Statement.Raise { Raise.expression = test; from = raise_from };
      }]
    }

  | return = RETURN; test = test_list? {
      let start, stop = return in
      let location =
        match test with
        | None -> Location.create ~start ~stop
        | Some node -> location_create_with_stop ~start ~stop:(Node.stop node)
      in
      [{
        Node.location;
        value = Statement.Return { Return.expression = test; is_implicit = false };
      }]
    }

  | delete = DELETE;
    expressions = separated_nonempty_list(COMMA, expression) {
      let stop = Node.stop (List.last_exn expressions) in
      [{
        Node.location = location_create_with_stop ~start:delete ~stop;
        value = Statement.Delete expressions;
      }]
    }
  ;

raise_from:
  | FROM; test_list = test_list { test_list }
  ;

compound_statement:
  | definition = CLASS; name = reference;
    bases = bases; colon_position = COLON;
    body = block_or_stub_body {
      let location = Location.create ~start:definition ~stop:colon_position in
      let body_location, body = body in
      let location = { location with Location.stop = body_location.Location.stop } in
      let _, name = name in
      {
        Node.location;
        value = Statement.Class {
          Class.name = name;
          base_arguments = bases;
          body;
          decorators = [];
        };
      }
    }

  | definition = DEFINE; name = reference;
    LEFTPARENS;
    parameters = define_parameters;
    RIGHTPARENS;
    return_annotation = return_annotation?;
    COLON;
    signature_comment = SIGNATURE_COMMENT?;
    body = block_or_stub_body {
      let body_location, body = body in
      let location =
        location_create_with_stop ~start:definition ~stop:body_location.Location.stop
      in
      let annotation =
        match return_annotation with
        | Some return_annotation -> Some return_annotation
        | None ->
          signature_comment
          >>= (fun ((start, stop), _, return_annotation) ->
              Some {
                Node.location = Location.create ~start ~stop;
                value = Expression.Constant (
                          AstExpression.Constant.String
                            (AstExpression.StringLiteral.create return_annotation)
                        );
              }
            )
      in
      let parameters =
        match signature_comment with
        | Some ((start, stop), parameter_annotations, _)
          when not (List.is_empty parameter_annotations) ->
            let add_annotation ({ Node.value = parameter; _ } as parameter_node) annotation =
                match annotation with
                | None ->
                    parameter_node
                | Some annotation -> {
                    parameter_node with
                    Node.value = {
                      parameter with
                        Parameter.annotation = Some {
                          Node.location = Location.create ~start ~stop;
                          value = Expression.Constant (
                                    AstExpression.Constant.String
                                      (AstExpression.StringLiteral.create annotation)
                                  );
                        };
                      }
                  }
            in
            (* We don't know whether a define is a method at this point, and mypy's documentation
               specifies that a method's self should NOT be annotated:
               `https://mypy.readthedocs.io/en/latest/python2.html`.

                Because we don't know whether we are parsing a method at this point or whether
                there's any decorators that mean a function doesn't have a self parameter, we make
                the angelic assumption that annotations lacking a single annotation knowingly elided
                the self annotation. *)
            let unannotated_parameter_count =
               List.length parameters - List.length parameter_annotations
            in
            if unannotated_parameter_count = 0 || unannotated_parameter_count = 1 then
              let parameter_annotations =
                List.init ~f:(fun _ -> None) unannotated_parameter_count @
                List.map ~f:Option.some parameter_annotations
              in
              List.map2_exn
                ~f:add_annotation
                parameters
                parameter_annotations
            else
              parameters
        | _ ->
            parameters
      in
      let _, name = name in
      {
        Node.location;
        value = Statement.Define {
          Define.signature = {
            Define.Signature.name = name;
            parameters = parameters;
            decorators = [];
            return_annotation = annotation;
            async = false;
          };
          body
        };
      }
    }

  | start = FOR; target = expression_list; IN; iterator = test_list; COLON;
    ANNOTATION_COMMENT?; body = block; orelse = named_optional_block(ELSE) {
      let stop = begin match orelse with
      | _, [] -> (fst body).Location.stop
      | location, _ -> location.Location.stop
      end in
      {
        Node.location = location_create_with_stop ~start ~stop;
        value = Statement.For {
          For.target = target;
          iterator = iterator;
          body = snd body;
          orelse = snd orelse;
          async = false
        };
      }
    }

  | start = IF; value = conditional {
      let value_location, value = value in
      {
        Node.location = location_create_with_stop ~start ~stop:value_location.Location.stop;
        value
      }
    }

  (* TryStar requires at least 1 group_handler because with no handlers it is ambiguous with Try *)
  | start = TRY; COLON;
    body = block;
    first_handler = group_handler;
    handlers = list(group_handler);
    orelse = named_optional_block(ELSE);
    finally = named_optional_block(FINALLY) {
      let handlers = first_handler::handlers in
      let stop =
        begin
          match handlers, snd orelse, snd finally with
          | _, _, (_::_) -> fst finally
          | _, (_::_), [] -> fst orelse
          | (_::_), [], [] -> (fst (List.last_exn handlers))
          | _ -> (fst body)
        end.Location.stop
      in
      {
        Node.location = location_create_with_stop ~start ~stop;
        value = Statement.Try {
          Try.body = snd body;
          handlers = List.map ~f:snd handlers;
          orelse = snd orelse;
          finally = snd finally;
          handles_exception_group = true
        };
      }
    }

  | start = TRY; COLON;
    body = block;
    handlers = list(handler);
    orelse = named_optional_block(ELSE);
    finally = named_optional_block(FINALLY) {
      let stop =
        begin
          match handlers, snd orelse, snd finally with
          | _, _, (_::_) -> fst finally
          | _, (_::_), [] -> fst orelse
          | (_::_), [], [] -> (fst (List.last_exn handlers))
          | _ -> (fst body)
        end.Location.stop
      in
      {
        Node.location = location_create_with_stop ~start ~stop;
        value = Statement.Try {
          Try.body = snd body;
          handlers = List.map ~f:snd handlers;
          orelse = snd orelse;
          finally = snd finally;
          handles_exception_group = false
        };
      }
    }

  | start = WITH;
    items = parser_generator_separated_nonempty_list(COMMA, with_item); COLON;
    ANNOTATION_COMMENT?;
    body = block {
      {
        Node.location = location_create_with_stop ~start ~stop:(fst body).Location.stop;
        value = Statement.With {
          With.items = items;
          body = snd body;
          async = false;
        };
      }
    }

  | start = WHILE; test = test_list; COLON;
    body = block; orelse = named_optional_block(ELSE) {
      let stop =
        match orelse with
        | _, [] -> (fst body).Location.stop
        | location, _ -> location.Location.stop in
      {
        Node.location = location_create_with_stop ~start ~stop;
        value = Statement.While { While.test = test; body = snd body; orelse = snd orelse };
      }
    }
  ;

decorated_statement:
  | decorators = decorator+; statement = compound_statement {
      with_decorators decorators statement
    }
  | decorators = decorator+; statement = async_statement {
      with_decorators decorators statement
    }
  ;

async_statement:
  | position = ASYNC; statement = compound_statement {
      let location = location_create_with_stop ~start:(fst position) ~stop:(Node.stop statement) in
      match statement with
      | { Node.value = Statement.Define ({ Define.signature; _ } as value); _ } ->
          let signature = { signature with Define.Signature.async = true } in
          let decorated = { value with Define.signature } in
          {
            Node.location;
            value = Statement.Define decorated;
          }
      | { Node.value = Statement.For value; _ } ->
          let with_async = { value with For.async = true } in
          {
            Node.location;
            value = Statement.For with_async;
          }
      | { Node.value = Statement.With value; _ } ->
          let with_async = { value with With.async = true } in
          {
            Node.location;
            value = Statement.With with_async;
          }
      | _ -> raise (Failure "Async not supported on statement.")
    }
  ;

block_or_stub_body:
  | ellipsis = ELLIPSES; NEWLINE
  | NEWLINE+; INDENT; ellipsis = ELLIPSES; NEWLINE; DEDENT; NEWLINE* {
    let location = Location.create ~start:(fst ellipsis) ~stop:(snd ellipsis) in
    let body = [
      Node.create
        ~location
        (Statement.Expression
          (Node.create
            ~location
            (Expression.Constant AstExpression.Constant.Ellipsis)
          )
        )
    ] in
    location, body
   }
  | statements = block { statements }
  ;

block:
  | simple_statement = simple_statement; { simple_statement }
  | NEWLINE+; INDENT; statements = statements; DEDENT; NEWLINE* {
      statements
    }
  ;

named_optional_block(NAME):
  | { Location.any, [] }
  | NAME; COLON; block = block { block }
  ;

conditional:
  | test = test_list; COLON;
    body = block; orelse = named_optional_block(ELSE) {
      {
        test.Node.location with
        Location.stop =
          match orelse with
          | _, [] -> (fst body).Location.stop
          | location, _ -> location.Location.stop;
      },
      Statement.If { If.test = test; body = snd body; orelse = snd orelse }
    }
  | test = test_list; COLON;
    body = block;
    else_start = ELSEIF; value = conditional {
      let stop = (fst value).Location.stop in
      { test.Node.location with Location.stop },
      Statement.If {
        If.test = test;
        body = (snd body);
        orelse = [{
          Node.location =
            location_create_with_stop ~start:else_start ~stop;
          value = snd value
        }];
      }
    }
 ;

bases:
  | { [] }
  | LEFTPARENS; bases = parser_generator_separated_list(COMMA, argument); RIGHTPARENS {
      bases
    }
  ;

decorator:
  | AT; expression = expression; NEWLINE+ {
      expression
    }
  ;

identifier:
  | identifier = IDENTIFIER {
      let start, stop = fst identifier in
      Location.create ~start ~stop, snd identifier
    }
  | position = ASYNC {
      Location.create ~start:(fst position) ~stop:(snd position),
      "async"
    }
  ;

reference:
  | identifiers = parser_generator_separated_nonempty_list(DOT, identifier) {
      let location =
        let (start, _) = List.hd_exn identifiers in
        let (stop, _) = List.last_exn identifiers in
        { start with Location.stop = stop.Location.stop }
      in
      let reference =
        List.map ~f:snd identifiers
        |> Reference.create_from_list
      in
      location, reference
    }
  ;

define_parameters:
  | parameter = define_parameter;
    COMMA;
    annotation = comment_annotation?;
    parameters = define_parameters { (with_annotation ~parameter ~annotation) :: parameters }
  | parameter = define_parameter;
    annotation = comment_annotation? { [with_annotation ~parameter ~annotation] }
  | { [] }

%inline define_parameter:
  (* `*` itself is a valid parameter... *)
  | asteriks = ASTERIKS {
      {
        Node.location = Location.create ~start:(fst asteriks) ~stop:(snd asteriks);
        value = {
            Parameter.name = "*";
            value = None;
            annotation = None;
        };
      }
    }
  | slash = SLASH {
    {
      Node.location = Location.create ~start:slash ~stop:slash;
      value = {
          Parameter.name = "/";
          value = None;
          annotation = None;
      };
    }
  }
  | name = name; annotation = annotation? {
      let location =
        let name_location = fst name in
        match annotation with
        | None -> name_location
        | Some { Node.location = { Location.stop; _ }; _ } -> { name_location with Location.stop }
      in
      {
        Node.location;
        value = { Parameter.name = snd name; value = None; annotation };
      }
    }
  | name = name; annotation = annotation?; EQUALS; value = test {
      let location =
        let name_location = fst name in
        match annotation with
        | None -> name_location
        | Some { Node.location = { Location.stop; _ }; _ } -> { name_location with Location.stop }
      in
      {
        Node.location;
        value = { Parameter.name = snd name; value = Some value; annotation };
      }
    }
  ;

%inline lambda_parameter:
  (* `*` is a valid parameter for lambdas as well. *)
  | asteriks = ASTERIKS {
      {
        Node.location = Location.create ~start:(fst asteriks) ~stop:(snd asteriks);
        value = {
            Parameter.name = "*";
            value = None;
            annotation = None;
        };
      }
    }
  | name = name {
      {
        Node.location = fst name;
        value = { Parameter.name = snd name; value = None; annotation = None }
      }
    }
  | name = name; EQUALS; value = test {
      {
        Node.location = { (fst name) with Location.stop = value.Node.location.Location.stop };
        value = { Parameter.name = snd name; value = Some value; annotation = None};
      }
    }
  ;

%inline name:
  | expression = expression {
      let rec identifier expression =
        match expression with
        | { Node.location; value = Expression.Name (Name.Identifier identifier) } ->
            (location, identifier)
        | { Node.location; value = Expression.Starred (Starred.Once expression) } ->
            location,
            identifier expression
            |> snd
            |> fun identifier -> "*" ^ identifier
        | { Node.location; value = Expression.Starred (Starred.Twice expression) } ->
            location,
            identifier expression
            |> snd
            |> fun identifier -> "**" ^ identifier
        | _ ->
            raise (Failure "Unexpected parameters") in
      identifier expression
    }
  ;

%inline annotation:
  | COLON; expression = expression { expression }
  ;

%inline comment_annotation:
  | annotation = ANNOTATION_COMMENT {
      let (start, stop), annotation = annotation in
      annotation
      |> String.strip ~drop:(function | '\'' | '"' -> true | _ -> false)
      |> AstExpression.StringLiteral.create
      |> fun string -> Expression.Constant (AstExpression.Constant.String string)
      |> Node.create ~location:(Location.create ~start ~stop)
    }

%inline return_annotation:
  | MINUS; RIGHTANGLE; expression = expression { expression }
  ;

%inline subscript:
  | head = expression;
    left = LEFTBRACKET;
    subscripts = parser_generator_separated_nonempty_list(COMMA, subscript_key);
    right = RIGHTBRACKET {
      head, subscripts, Location.create ~start:left ~stop:right
    }
  ;

with_item:
  | resource = test { resource, None }
  | resource = test; AS; target = expression { resource, Some target }
  ;

handler:
  | start = EXCEPT; COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = None; name = None; body = snd handler_body }
    }
  | start = EXCEPT; kind = expression; COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = Some kind; name = None; body = snd handler_body }
    }
  | start = EXCEPT;
    kind = expression; AS; name = identifier;
    COLON; handler_body = block
  | start = EXCEPT;
    kind = expression; COMMA; name = identifier;
    COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = Some kind; name = Some ({Node.location=(fst name); value=(snd name)}); body = snd handler_body }
    }
  | start = EXCEPT;
    kind = or_test; COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = Some kind; name = None; body = snd handler_body }
    }
  | start = EXCEPT;
    kind = or_test; AS; name = identifier;
    COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = Some kind; name = Some ({Node.location=(fst name); value=(snd name)}); body = snd handler_body }
    }
  ;

group_handler:
  | start = EXCEPT_STAR; kind = expression; COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = Some kind; name = None; body = snd handler_body }
    }
  | start = EXCEPT_STAR;
    kind = expression; AS; name = identifier;
    COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = Some kind; name = Some ({Node.location=(fst name); value=(snd name)}); body = snd handler_body }
    }
  | start = EXCEPT_STAR;
    kind = or_test; COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = Some kind; name = None; body = snd handler_body }
    }
  | start = EXCEPT_STAR;
    kind = or_test; AS; name = identifier;
    COLON; handler_body = block {
      location_create_with_stop ~start ~stop:(fst handler_body).Location.stop,
      { Try.Handler.kind = Some kind; name = Some ({Node.location=(fst name); value=(snd name)}); body = snd handler_body }
    }
  ;

from:
  | from = from_string {
      Some (Reference.create from)
    }
  ;

from_string:
  | identifier = identifier {
      snd identifier
  }
  | identifier = identifier; from_string = from_string {
      (snd identifier) ^ from_string
    }
  | relative = nonempty_list(ellipsis_or_dot) {
      String.concat relative
    }
  | relative = nonempty_list(ellipsis_or_dot);
    from_string = from_string {
      (String.concat relative) ^ from_string
    }
  ;

ellipsis_or_dot:
  | DOT {
      "."
    }
  | ELLIPSES {
      "..."
    }
  ;

imports:
  | imports = parser_generator_separated_nonempty_list(COMMA, import) {
      let location =
        let (start, _) = List.hd_exn imports in
        let (stop, _) = List.last_exn imports in
        { start with Location.stop = stop.Location.stop }
      in
      location, List.map imports ~f:(fun (location, value) -> { Node.value; location })
    }
  | start = LEFTPARENS;
    imports = parser_generator_separated_nonempty_list(COMMA, import);
    stop = RIGHTPARENS {
      (Location.create ~start ~stop),
      List.map imports ~f:(fun (location, value) -> { Node.value; location })
    }
  ;

import:
  | position = ASTERIKS {
      let location =
        let start, stop = position in
        Location.create ~start ~stop
      in
      location,
      {
        Ast.Statement.Import.name = Reference.create "*";
        alias = None;
      }
    }
  | name = reference {
      fst name,
      {
        Ast.Statement.Import.name = snd name;
        alias = None;
      }
    }
  | name = reference;
    AS; alias = identifier {
      {(fst name) with Location.stop = (fst alias).Location.stop},
      {
        Ast.Statement.Import.name = snd name;
        alias = Some (snd alias);
      }
    }
  ;

%inline target:
  | target = test_list {
      let assignment_with_annotation ~value ~annotation ~index_in_chain =
        {
          Node.location = {
            target.Node.location with Location.stop =
              value.Node.location.Location.stop;
          };
          value = Statement.Assign {
            Assign.target = target;
            annotation = annotation;
            value = Some value;
            index_in_chain;
          };
        }
      in
      assignment_with_annotation
    }

targets:
  | target = target; EQUALS { [target] }
  | targets = targets; target = target; EQUALS { targets @ [target] }
  ;

value:
  | test = test_list { test }
  | yield_form = yield_form { yield_form }
  ;

(* Expressions. *)

atom:
  | identifier = identifier {
      {
        Node.location = fst identifier;
        value = Expression.Name (Name.Identifier (snd identifier));
      }
    }

  | ellipsis = ELLIPSES {
      let location = Location.create ~start:(fst ellipsis) ~stop:(snd ellipsis) in
      Node.create (Expression.Constant AstExpression.Constant.Ellipsis) ~location
    }

  | left = expression;
    operator = binary_operator;
    right = expression; {
      binary_operator ~left ~operator ~right
    }

  | bytes = BYTES+ {
      let (start, stop), _, _ = List.hd_exn bytes in
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Constant (AstExpression.Constant.String (
          AstExpression.StringLiteral.create
            ~bytes:true
            (String.concat (List.map bytes ~f:(fun (_, _, value) -> value)))
        ));
      }
    }

  | format = FORMAT; mixed_string = mixed_string {
      let all_strings = create_raw_format_substring format :: mixed_string in
      let all_pieces = List.map all_strings ~f:snd in
      let (head, _), (last, _) = List.hd_exn all_strings, List.last_exn all_strings in
      let (start, _) = head in
      let (_, stop) = last in
      {
        Node.location = Location.create ~start ~stop;
        value = create_mixed_string all_pieces;
      }
    }

  | name = expression;
    start = LEFTPARENS;
    arguments = arguments;
    stop = RIGHTPARENS {
      let call_location = Location.create ~start ~stop in
      Expression.Call { Call.callee = name; arguments }
      |> Node.create
        ~location:({ name.Node.location with Location.stop = call_location.Location.stop })
    }

  | set_or_dictionary = set_or_dictionary {
      set_or_dictionary
    }

  | position = FALSE {
      let start, stop = position in
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Constant AstExpression.Constant.False;
      }
    }

  | number = COMPLEX {
      let start, stop = fst number in
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Constant (AstExpression.Constant.Complex (snd number));
      }
    }

  | number = FLOAT {
      let start, stop = fst number in
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Constant (AstExpression.Constant.Float (snd number));
      }
    }

  | number = INTEGER {
      let start, stop = fst number in
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Constant (AstExpression.Constant.Integer (snd number));
      }
    }

  | position = NONE {
      let start, stop = position in
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Constant AstExpression.Constant.NoneLiteral;
      }
    }

  | start = LEFTBRACKET;
    items = parser_generator_separated_list(COMMA, test);
    stop = RIGHTBRACKET {
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.List items;
      }
    }
  | start = LEFTBRACKET;
    element = test;
    generators = comprehension+;
    stop = RIGHTBRACKET {
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.ListComprehension { Comprehension.element; generators };
      }
    }

  | start = LEFTCURLY;
    element = test;
    generators = comprehension+;
    stop = RIGHTCURLY {
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.SetComprehension { Comprehension.element; generators };
      }
    }

  | position = ASTERIKS; test = expression {
    let start, _ = position in
    let location = location_create_with_stop ~start ~stop:(Node.stop test) in
    match test with
    | {
        Node.value = Expression.Starred (Starred.Once test);
        _;
      } -> {
        Node.location;
        value = Expression.Starred (Starred.Twice test);
      }
    | _ -> {
        Node.location;
        value = Expression.Starred (Starred.Once test);
      }
    }

  | string = STRING; mixed_string = mixed_string {
      let all_strings = create_literal_substring string :: mixed_string in
      let all_pieces = List.map all_strings ~f:snd in
      let (head, _), (last, _) = List.hd_exn all_strings, List.last_exn all_strings in
      let (start, _) = head in
      let (_, stop) = last in
      {
        Node.location = Location.create ~start ~stop;
        value = create_mixed_string all_pieces;
      }
    }

  | position = TRUE {
      let start, stop = position in
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Constant AstExpression.Constant.True
      }
    }

  | operator = unary_operator; operand = expression {
      let start, operator = operator in
      let { Node.value; _ } = operand in
      let location = location_create_with_stop ~start ~stop:(Node.stop operand)
      in
      match operator, value with
      | AstExpression.UnaryOperator.Negative,
        Expression.Constant (AstExpression.Constant.Integer literal) -> {
        Node.location;
        value = Expression.Constant (AstExpression.Constant.Integer (-1 * literal));
      }
      | _, _ -> {
        Node.location;
        value = Expression.UnaryOperator {
          UnaryOperator.operator = operator;
          operand;
        };
      }
    }
  ;

expression:
  | atom = atom { atom }

  | start = LEFTPARENS; stop = RIGHTPARENS {
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Tuple [];
      }
    }

  | start = LEFTPARENS; test = test_list; stop = RIGHTPARENS {
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Parenthesis test;
      }
    }

  | expression = expression; DOT; identifier = identifier {
      let location =
        { expression.Node.location with Location.stop = Location.stop (fst identifier) }
      in
      {
        Node.location;
        value = Expression.Name (
          Name.Attribute { Name.Attribute.base = expression; attribute = snd identifier }
        )
      }
    }

  | subscript = subscript { subscript_access subscript }

  | start = AWAIT; expression = expression {
      {
        Node.location = location_create_with_stop ~start ~stop:(Node.stop expression);
        value = Expression.Await expression;
      }
    }

  | LEFTPARENS; generator = generator; RIGHTPARENS { generator }

  | LEFTPARENS; yield_form = yield_form; RIGHTPARENS { yield_form }
  ;

expression_list:
  | items = separated_nonempty_list_indicator(COMMA, expression) {
      match items with
      | head::[], has_trailing_comma ->
          if has_trailing_comma then
            {
              Node.location = head.Node.location;
              value = Expression.Tuple [head];
            }
          else head
      | (head :: _) as items, _ ->
          let last = List.last_exn items in
          {
            Node.location = { head.Node.location with Location.stop = Node.stop last };
            value = Expression.Tuple items;
          }
      | _ -> raise (Failure "invalid atom")
    }
  ;

mixed_string:
  | { [] }
  | first_string = FORMAT; rest = mixed_string {
      create_raw_format_substring first_string :: rest
    }
  | first_string = STRING; rest = mixed_string {
      create_literal_substring first_string :: rest
    }
  ;

comparison:
  | expression = expression { expression }

  | left = expression; comparisons = nonempty_list(comparison_operator) {
      let rec comparison ({ Node.location; _ } as left) comparisons =
        match comparisons with
        | (operator, right) :: comparisons when List.length comparisons > 0 ->
            let left =
              Expression.ComparisonOperator { ComparisonOperator.left; operator; right }
              |> Node.create ~location:({ location with Location.stop = Node.stop right })
            in
            let right = comparison right comparisons in
            Expression.BooleanOperator {
              BooleanOperator.left;
              operator = AstExpression.BooleanOperator.And;
              right;
            }
            |> Node.create ~location;
        | [operator, right] ->
            Expression.ComparisonOperator { ComparisonOperator.left; operator; right }
            |> Node.create ~location:({ location with Location.stop = Node.stop right })
        | _ ->
            failwith "The parser is a lie! Did not get a non-empty comparison list."
      in
      comparison left comparisons
    }
  ;

not_test:
  | comparison = comparison { comparison }
  | start = NOT; not_test = not_test {
      let location = location_create_with_stop ~start ~stop:(Node.stop not_test) in
      {
        Node.location;
        value = Expression.UnaryOperator {
          UnaryOperator.operator = AstExpression.UnaryOperator.Not;
          operand = not_test;
        }
      }
  }
  ;

and_test:
  | not_test = not_test { not_test }
  | left = not_test; AND; right = and_test {
      let location = { (Node.location left) with Location.stop = Node.stop right } in
      {
        Node.location;
        value = Expression.BooleanOperator {
          BooleanOperator.left;
          operator = AstExpression.BooleanOperator.And;
          right;
        }
      }
   }
  ;

or_test:
  | and_test = and_test { and_test }
  | left = and_test; OR; right = or_test {
      let location = { (Node.location left) with Location.stop = Node.stop right } in
      {
        Node.location;
        value = Expression.BooleanOperator {
          BooleanOperator.left;
          operator = AstExpression.BooleanOperator.Or;
          right;
        }
      }
   }
  ;

test_with_generator:
  | generator = generator { generator }
  | test = test { test }
  ;

test:
  | or_test = or_test { or_test }

  | target = identifier; COLONEQUALS; value = test {
      {
        Node.location = { (fst target) with Location.stop = Node.stop value };
        value = Expression.WalrusOperator {
          WalrusOperator.target =
            Expression.Name (Name.Identifier (snd target))
            |> Node.create ~location:(fst target);
          value = value;
        }
      }
    }

  | target = or_test;
    IF;
    test = test_list;
    ELSE;
    alternative = test {
      {
        Node.location = { target.Node.location with Location.stop = Node.stop alternative };
        value = Expression.Ternary { Ternary.target; test; alternative };
      }
    }
  | start = LAMBDA;
    parameters = parser_generator_separated_list(COMMA, lambda_parameter);
    COLON;
    body = test {
      {
        Node.location =  location_create_with_stop ~start ~stop:(Node.stop body);
        value = Expression.Lambda { Lambda.parameters; body }
      }
    }
  ;

test_list:
  | items = separated_nonempty_list_indicator(COMMA, test) {
      match items with
      | head :: [], has_trailing_comma ->
        if has_trailing_comma then
          {
            Node.location = head.Node.location;
            value = Expression.Tuple [head];
          }
        else
          head
      | (head :: _ as items), _ ->
          let last = List.last_exn items in
          {
            Node.location = { head.Node.location with Location.stop = Node.stop last };
            value = Expression.Tuple items;
          }
      | _ -> raise (Failure "invalid atom")
    }
  ;

yield_form:
  | yield_token = YIELD; test = test_list?; {
      let start, stop = yield_token in
      let location =
        Option.map
         ~f:(fun test -> location_create_with_stop ~start ~stop:(Node.stop test))
         test
        |> Option.value ~default:(Location.create ~start ~stop)
      in
      {
        Node.location;
        value = Expression.Yield test;
      }
    }

  | yield_token = YIELD; FROM; test = test_list; {
      let start, _ = yield_token in
      let location = location_create_with_stop ~start ~stop:(Node.stop test) in
      {
        Node.location;
        value = Expression.YieldFrom test;
      }
    }
  ;

%inline binary_operator:
  | PLUS { AstExpression.BinaryOperator.Add }
  | AT { AstExpression.BinaryOperator.MatMult }
  | AMPERSAND { AstExpression.BinaryOperator.BitAnd }
  | BAR { AstExpression.BinaryOperator.BitOr }
  | HAT { AstExpression.BinaryOperator.BitXor }
  | SLASH; SLASH { AstExpression.BinaryOperator.FloorDiv }
  | SLASH { AstExpression.BinaryOperator.Div }
  | LEFTANGLELEFTANGLE { AstExpression.BinaryOperator.LShift }
  | PERCENT { AstExpression.BinaryOperator.Mod }
  | ASTERIKS; ASTERIKS { AstExpression.BinaryOperator.Pow }
  | ASTERIKS { AstExpression.BinaryOperator.Mult }
  | RIGHTANGLERIGHTANGLE { AstExpression.BinaryOperator.RShift }
  | MINUS { AstExpression.BinaryOperator.Sub }
  ;

comparison_operator:
  | DOUBLEEQUALS; operand = expression { AstExpression.ComparisonOperator.Equals, operand }
  | RIGHTANGLE; operand = expression { AstExpression.ComparisonOperator.GreaterThan, operand }
  | RIGHTANGLEEQUALS; operand = expression {
      AstExpression.ComparisonOperator.GreaterThanOrEquals, operand
    }
  | IN; operand = expression { AstExpression.ComparisonOperator.In, operand }
  | IS; operand = expression { AstExpression.ComparisonOperator.Is, operand }
  | ISNOT; operand = expression { AstExpression.ComparisonOperator.IsNot, operand }
  | LEFTANGLE; operand = expression { AstExpression.ComparisonOperator.LessThan, operand }
  | LEFTANGLEEQUALS; operand = expression {
      AstExpression.ComparisonOperator.LessThanOrEquals, operand
    }
  | EXCLAMATIONMARK; EQUALS; operand = expression {
      AstExpression.ComparisonOperator.NotEquals, operand
    }
  | NOT; IN; operand = expression { AstExpression.ComparisonOperator.NotIn, operand }
  ;

%inline compound_operator:
  | PLUSEQUALS { AstExpression.BinaryOperator.Add }
  | ATEQUALS { AstExpression.BinaryOperator.MatMult }
  | AMPERSANDEQUALS { AstExpression.BinaryOperator.BitAnd }
  | BAREQUALS { AstExpression.BinaryOperator.BitOr }
  | HATEQUALS { AstExpression.BinaryOperator.BitXor }
  | SLASHSLASHEQUALS { AstExpression.BinaryOperator.FloorDiv }
  | SLASHEQUALS { AstExpression.BinaryOperator.Div }
  | LEFTANGLELEFTANGLEEQUALS { AstExpression.BinaryOperator.LShift }
  | PERCENTEQUALS { AstExpression.BinaryOperator.Mod }
  | ASTERIKSASTERIKSEQUALS { AstExpression.BinaryOperator.Pow }
  | ASTERIKSEQUALS { AstExpression.BinaryOperator.Mult }
  | RIGHTANGLERIGHTANGLEEQUALS { AstExpression.BinaryOperator.RShift }
  | MINUSEQUALS { AstExpression.BinaryOperator.Sub }
  ;

%inline unary_operator:
  | position = TILDE { position, AstExpression.UnaryOperator.Invert }
  | position = MINUS { position, AstExpression.UnaryOperator.Negative }
  | position = NOT { position, AstExpression.UnaryOperator.Not }
  | position = PLUS { position, AstExpression.UnaryOperator.Positive }
  ;

arguments:
  | arguments = parser_generator_separated_list(COMMA, argument) { arguments }
  | test = test_with_generator { [{ Call.Argument.name = None; value = test }] }
  | test = generator; COMMA { [{ Call.Argument.name = None; value = test }] }
  ;

argument:
  | identifier = identifier; EQUALS; value = test {
     {
        Call.Argument.name = Some { Node.location = fst identifier; value = snd identifier };
        value;
      }
    }
  | value = test { { Call.Argument.name = None; value } }
  ;

subscript_key:
  | index = test { index }
  | lower = test?; bound_colon = COLON; upper = test? {
      slice ~lower ~upper ~step:None ~bound_colon ~step_colon:None
    }
  | lower = test?; bound_colon = COLON; upper = test?; step_colon = COLON; step = test? {
      slice ~lower ~upper ~step ~bound_colon ~step_colon:(Some step_colon)
    }
  ;

(* Collections. *)
set_or_dictionary_entry:
  | test = test {
      match test with
      | { Node.value = Expression.Starred (Starred.Twice keywords); _ } ->
          Entry (Dictionary.Entry.Splat keywords)
      | _ ->
          Item test
    }
  | key = test; COLON; value = test {
      Entry (Dictionary.Entry.KeyValue Dictionary.Entry.KeyValue.{ key = key; value = value; })
    }
  ;

set_or_dictionary_maker:
  | entry = set_or_dictionary_entry {
      add_entry { entries = []; comprehensions = []; items = [] } entry
    }
  | items = set_or_dictionary_maker; COMMA; entry = set_or_dictionary_entry {
      add_entry items entry
    }
  | items = set_or_dictionary_maker; comprehension = comprehension {
      add_entry items (Comprehension comprehension)
    }
  ;

set_or_dictionary:
  | start = LEFTCURLY; stop = RIGHTCURLY {
      {
        Node.location = Location.create ~start ~stop;
        value = Expression.Dictionary [];
      }
    }
  | start = LEFTCURLY; items = set_or_dictionary_maker; COMMA?; stop = RIGHTCURLY {
      let value =
        match items with
        | { entries; comprehensions = []; items = [] } ->
             Expression.Dictionary (List.rev entries)
        | { entries = [Dictionary.Entry.KeyValue entry]; items = []; comprehensions  } ->
              Expression.DictionaryComprehension {
                Comprehension.element = entry;
                generators = List.rev comprehensions;
              }
        | { items; entries = []; comprehensions = [] } ->
               Expression.Set (List.rev items)
        | { items = [item]; comprehensions; entries = [] } ->
             Expression.SetComprehension {
               Comprehension.element = item;
               generators = List.rev comprehensions;
             }
        | _ -> failwith "Invalid dictionary or set"
      in
      { Node.location = Location.create ~start ~stop; value }
    }

generator:
  | element = test; generators = comprehension+ {
      let stop =
        let { Comprehension.Generator.iterator; conditions; _ } = List.last_exn generators in
        match List.rev conditions with
        | [] -> Node.stop iterator
        | condition :: _ -> Node.stop condition
      in
      {
        Node.location = { element.Node.location with Location.stop };
        value = Expression.Generator { Comprehension.element; generators };
      }
    }
  ;

comprehension:
  | ASYNC; FOR; target = expression_list; IN; iterator = or_test;
    conditions = list(condition) {
      { Comprehension.Generator.target; iterator; conditions; async = true }
    }
  | FOR; target = expression_list; IN; iterator = or_test;
    conditions = list(condition) {
      { Comprehension.Generator.target; iterator; conditions; async = false }
    }

  ;

condition:
  | IF; test = or_test { test }
  ;

(* Helper rule dumping ground. *)

parser_generator_separated_list(SEPARATOR, item):
  | { [] }
  | item = item { [item] }
  | item = item; SEPARATOR; rest = parser_generator_separated_list(SEPARATOR, item) {
      item::rest
    }
  ;

separated_nonempty_list_indicator_tail(SEPARATOR, item):
  | { [], false }
  | SEPARATOR { [], true }
  | SEPARATOR; item = item; rest = separated_nonempty_list_indicator_tail(SEPARATOR, item) {
      let rest, has_trailing = rest in
      item :: rest, has_trailing
    }
  ;

separated_nonempty_list_indicator(SEPARATOR, item):
  | item = item; rest = separated_nonempty_list_indicator_tail(SEPARATOR, item) {
      let rest, has_trailing = rest in
      item :: rest, has_trailing
    }
  ;


parser_generator_separated_nonempty_list(SEPARATOR, item):
  | item = item { [item] }
  | item = item; SEPARATOR; rest = parser_generator_separated_list(SEPARATOR, item) {
      item::rest
    }
  ;

parser_generator_separated_list_of_lists(SEPARATOR, list_item):
  | { [] }
  | list_item = list_item { [list_item] }
  | list_item = list_item; SEPARATOR;
    rest = parser_generator_separated_list_of_lists(SEPARATOR, list_item) {
      list_item::rest
    }
  ;

parser_generator_separated_nonempty_list_of_lists(SEPARATOR, list_item):
  | list_item = list_item { [list_item] }
  | list_item = list_item; SEPARATOR;
    rest = parser_generator_separated_list_of_lists(SEPARATOR, list_item) {
      list_item::rest
    }
  ;
