open Format
open Utils

exception SyntaxError of string * Sexpr.sexpr;;
exception UnknownForm of string;;

let error = fun s exp -> raise (SyntaxError (s, Sexpr.Group exp))

let binOps = ["+"; "-"; "*"; "/"; "<"; ">"; "OR"; "AND"; "EQUAL"; "EQ"; "EQL"]

let graph = [
  '-'; '.'; ','; '&'; ':'; ';'; '*'; '%'; '}'; '{'; ']'; '['; '!'; '^'; '@';
  '~'; '('; ')'; '?'; '='; '<'; '>'; '#']

let is_simple_symbol s =
  let contains = String.contains s in
  not (List.exists contains graph)

let literal_symbol s =
  let l = (String.length s) - 1 in
  if s.[l] = s.[0] && s.[0] = '|'
  then String.sub s 1 (l - 1)
  else s

let translate_op op =
  match op with
  | "+" -> "ADD"
  | "-" -> "SUB"
  | "*" -> "MUL"
  | "/" -> "DIV"
  | "<" -> "LT"
  | ">" -> "GT"
  | _ as x -> x

type tree =
  | Apply of tree * tree list
  | Assign of string * tree
  | Block of StringSet.t * tree list
  | Char of char
  | Cons of tree * tree
  | Float of float
  | IfThen of tree * tree
  | IfThenElse of tree * tree * tree
  | Global of string
  | Int of int
  | Jump of string
  | Label of string
  | Lambda of string list * tree
  | Return of tree
  | Loop of tree
  | String of string
  | Symbol of string

(* conversion from S-Expressions *)

let rec convert_symbol_list = function
  | (Sexpr.Symbol symbol)::symbols -> symbol::(convert_symbol_list symbols)
  | [] -> []
  | e -> error "Expected a list of symbols" e

let rec convert exp =
  try
    begin
      match exp with
      | Sexpr.Float n -> Float n
      | Sexpr.Group g -> convert_group g
      | Sexpr.Int n -> Int n
      | Sexpr.Quote (Sexpr.Group g) ->
          let reduce = fun a b -> Cons (convert a, b) 
          in List.fold_right reduce g (Symbol "nil")
      | Sexpr.Quote (Sexpr.Symbol s) -> Symbol s
      | Sexpr.String s -> String s
      | Sexpr.Symbol s -> Symbol s
      | e -> raise (SyntaxError ("Unknown s-expression", e))
    end
  with SyntaxError (s, exp) ->
    printf "@[<v 2>*SYNTAX ERROR* %s:@," s; Sexpr.print exp; printf "@]@.";
    Symbol "*invalid*"

and convert_group = function
  | (Sexpr.Symbol op)::body when List.mem op binOps && List.length body > 1 ->
      convert_bin_op (translate_op op) body
  | (Sexpr.Symbol name)::body -> (
      try
        convert_spec_form name body
      with UnknownForm _ ->
        Apply (Symbol name , List.map convert body))
  | (Sexpr.Group func)::body ->
      Apply (convert_group func, List.map convert body)
  | e -> error "Malformed group" e

and convert_bin_op op = function
  | head::tail ->
      let reduce = fun a b -> Apply (Symbol op, [a; convert b])
      in List.fold_left reduce (convert head) tail
  | e -> error "BinOp requires at least 2 args" e

and convert_spec_form = function
  | "BLOCK" -> convert_block
  | "char" -> convert_char
  | "DEFVAR" -> convert_defvar
  | "DEFUN" -> convert_fun_decl
  | "IF" -> convert_if
  | "LABEL" -> convert_label
  | "LAMBDA" -> convert_lambda
  | "LET" -> convert_let
  | "LOOP" -> convert_loop
  | "PROGN" -> convert_progn
  | "RETURN" -> convert_return
  | "SETQ" -> convert_setq
  | e -> raise (UnknownForm e)

and convert_block = function
  | (Sexpr.Symbol label)::rest ->
      Block (StringSet.empty, List.map convert rest)
  | e -> error "Malformed block s-form" e

and convert_label = function
  | [Sexpr.Symbol label] ->
      Label label
  | e -> error "Malformed label s-form" e

and convert_char = function
  | [Sexpr.Quote (Sexpr.Symbol c)] -> Char c.[0]
  | e -> error "Malformed char s-form" e

and convert_lambda = function
  | (Sexpr.Group args)::body ->
      Lambda (convert_symbol_list args, convert_progn body)
  | e -> error "Malformed lambda s-form" e

and convert_loop body = Loop (convert_progn body)

and convert_defvar = function
  | [Sexpr.Symbol name] ->
      Global name
  | e -> error "Malformed defvar s-form" e

and convert_fun_decl = function
  | [Sexpr.Symbol name; Sexpr.Group args; body] ->
      Assign (name, Lambda (convert_symbol_list args, convert body))
  | e -> error "Malformed defun s-form" e

and convert_let = function
  | (Sexpr.Group symbols)::body ->
      let symbols = convert_symbol_list symbols in
      Block (makeStringSet symbols, List.map convert body)
  | e -> error "Malformed let s-form" e

and convert_return = function
  | [value] ->
      Return (convert value)
  | e -> error "Malformed return s-form" e

and convert_setq = function
  | [Sexpr.Symbol name; value] ->
      Assign (name, convert value)
  | e -> error "Malformed setq s-form" e

and convert_progn body =
  Block (StringSet.empty, List.map convert body)

and convert_if = function
  | pred::if_true::[] ->
      IfThen (convert pred, convert if_true)
  | pred::if_true::if_false::[] ->
      IfThenElse (convert pred, convert if_true, convert if_false)
  | e -> error "Malformed if s-form" e

(* stringification *)
let rec print = function
  | Apply (func, args) ->
      print func; print_char '('; print_list ", " args; print_char ')'
  | Assign (name, Lambda (args, body)) ->
      printf "@[<v>def "; print_symbol name;
      printf "(@[<hov>"; print_symbols args; printf "@])@,";
      print_fun_body body; printf "@]"
  | Assign (name, value) ->
      print_symbol name; printf " := "; print value
  | Block (vars, tree) ->
      printf "@[<v>@[<v 2>begin@,"; print_block vars tree; printf "@]@,end@]"
  | Char c -> 
      printf "'%c'" c
  | Cons (a, Cons _) as lst ->
      printf "@[<1>["; print_cons lst; printf "]@]"
  | Cons (a, b) ->
      print_char '{'; print a; printf "; "; print b; print_char '}'
  | Float n ->
      print_float n
  | IfThen (pred, if_true) ->
      printf "@[<v>";
      printf "@[<v 2>if*@,"; print pred; printf "@]@,";
      printf "@[<v 2>then@,"; print if_true; printf "@]@,endif@]"
  | IfThenElse (pred, if_true, if_false) ->
      printf "@[<v>";
      printf "@[<v 2>if@,"; print pred; printf "@]@,";
      printf "@[<v 2>then@,"; print if_true; printf "@]@,";
      printf "@[<v 2>else@,"; print if_false; printf "@]@,endif@]"
  | Int n ->
      print_int n
  | Jump name ->
      printf "jump %s" name
  | Global name ->
      printf "global %s" name
  | Lambda (args, body) ->
      printf "@[<v>fn (@[<hov>"; print_symbols args; printf "@]) -> @,";
      print_fun_body body; printf "@] "
  | Label name ->
      printf "label %s:" name
  | Loop (Block (vars, exps)) ->
      printf "@[<v>@[<v 2>loop@,"; print_block vars exps; printf "@]@,endloop@]"
  | Loop tree ->
      printf "@[<v>@[<v 2>loop@,"; print tree; printf "@]@,endloop@]"
  | Return tree ->
      printf "return "; print tree
  | String str ->
      printf "\"%s\"" (String.escaped str)
  | Symbol name ->
      print_symbol name

and print_list sep trees =
  match trees with
  | tree::[] -> print tree
  | tree::rest ->
      print tree; print_string sep; print_list sep rest
  | [] -> ()

and print_cons = function
  | Cons (a, (Cons (_, _) as rest)) ->
      print a; printf ";@ "; print_cons rest
  | Cons (a, Symbol "nil") ->
      print a
  | _ -> failwith "Not a list."

and print_fun_body body =
  match body with
  | Block (_, _) ->
      print body
  | _ ->
      printf "@[<v 2>begin@,"; print body; printf "@]@,end"

and print_symbol name = 
  let name = literal_symbol name in
  if is_simple_symbol name
  then print_string name
  else printf "|%s|" name

and print_symbols = function
  | x::[] -> print_symbol x 
  | x::xs -> print_symbol x; printf ",@ "; print_symbols xs
  | [] -> ()

and print_block vars exps =
  if not (StringSet.is_empty vars) then
    begin
      printf "var @["; print_symbols (StringSet.elements vars); printf "@]@,"
    end;
  print_block' exps

and print_block' exps =
  match exps with
  | [] -> ()
  | tree::[] -> print tree
  | tree::rest -> print tree; printf "@,"; print_block' rest
