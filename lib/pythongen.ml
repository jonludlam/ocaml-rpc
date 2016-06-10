(* Python generator *)

type 'a comp = 'a
  
type _ fn =
  | Function : 'a Idl.Param.t * 'b fn -> ('a -> 'b) fn
  | Returning : 'a Idl.Param.t -> 'a comp fn
      
module Method = struct
  type 'a t = {
    name : string;
    description : string;
    ty : 'a fn
  }
end

type boxed_fn =
  | BoxedFunction : 'a Method.t -> boxed_fn
    
module Interface = struct

  type t = {
    details : Idl.Interface.description;
    methods : boxed_fn list;
  }
  
  let prepend_arg : t -> 'a Idl.Param.t -> t = fun interface param ->
    let prepend : type b. b fn -> ('a -> b) fn = fun arg ->
      Function (param, arg)
    in
    {interface with methods = List.map (fun (BoxedFunction m) ->
         BoxedFunction Method.({ name = m.name; description = m.description; ty = prepend m.ty}))
         interface.methods}
end

type description = Interface.t

let describe i = Interface.({details=i; methods=[]})

  
type typedefs =
  | BoxedTypedef : 'a Types.def -> typedefs
    
let rec find_inputs : type a. a fn -> Idl.Param.boxed list = fun m ->
  match m with
  | Function (x,y) -> (Idl.Param.Boxed x) :: find_inputs y
  | Returning _ -> []
                   
let rec find_output : type a. a fn -> Idl.Param.boxed = fun m ->
  match m with
  | Returning x -> Idl.Param.Boxed x
  | Function (x,y) -> find_output y
                        
module Interfaces = struct
  type t = {
    name : string;
    title : string;
    description : string;
    type_decls : typedefs list;
    interfaces : Interface.t list;
  }  
  
  let empty name title description =
    { name; title; description; type_decls=[]; interfaces=[] }
    
  let add_interface is i =
    let new_typedefs =
      List.concat (List.map (fun (BoxedFunction m) ->
          let inputs = find_inputs m.Method.ty in
          let output = find_output m.Method.ty in
          let defs = List.map (fun (Idl.Param.Boxed p) -> BoxedTypedef (p.Idl.Param.typedef)) (output::inputs) in
          let new_types = List.filter
              (fun def -> not (List.mem def is.type_decls)) defs in
          new_types) i.Interface.methods)
    in
    { is with type_decls = new_typedefs @ is.type_decls; interfaces = i :: is.interfaces }
    
end

type 'a res = Interface.t -> Interface.t
                               
let returning a = Returning a
let (@->) = fun t f -> Function (t, f)
    
let declare name description ty interface =
  let m = BoxedFunction Method.({name; description; ty}) in
  Interface.({interface with methods = interface.methods @ [m]})


type t =
  | Block of t list
  | Line of string

let rec lines_of_t t =
  let indent = String.make 4 ' ' in
  match t with
  | Line x -> [ x ]
  | Block xs ->
    let all = List.concat (List.map lines_of_t xs) in
    List.map (fun x -> indent ^ x) all

let string_of_ts ts = String.concat "\n" (List.concat (List.map lines_of_t ts))

(* generate a fresh id *)
let fresh_id =
  let counter = ref 0 in
  fun () ->
    incr counter;
    "tmp_" ^ (string_of_int !counter)

(** [typecheck ty v] returns a python fragment which checks 
    	[v] has type [ty] *)
let rec typecheck : type a.a Types.typ -> string -> t list = fun ty v ->
  let open Types in
  let open Printf in
  let raise_type_error =
    Line (sprintf "raise (TypeError(\"%s\", repr(%s)))" ((*Types.ocaml_of_t ty*)"") v) in
  let handle_basic b =
    let python_of_basic : type a. a Types.basic -> string = function
      | Int64   -> "0L"
      | Int32   -> "0"
      | Int     -> "0"
      | String  -> "\"string\""
      | Float  -> "1.1"
      | Bool -> "True"
      | Char -> "'c'"
    in
    [ Line (sprintf "if type(%s) <> type(%s):" v (python_of_basic b));
      Block [ raise_type_error ] ]
  in
  match ty with
  | Basic Int64 ->
    [ Line (sprintf "if not(is_long(%s)):" v);
      Block [ raise_type_error ] ]
  | Basic String ->
    [ Line (sprintf "if type(%s) <> type(\"\") and type(%s) <> type(u\"\"):" v v);
      Block [ raise_type_error ] ]
  | Basic Int32 -> handle_basic Int32
  | Basic Int -> handle_basic Int
  | Basic Bool -> handle_basic Bool
  | Basic Float -> handle_basic Float
  | Basic Char -> handle_basic Char
  | DateTime -> handle_basic String
  | Struct { fields } ->
    let check boxedfield =
      let BoxedField f = boxedfield in
      typecheck f.field (sprintf "%s['%s']" v f.fname) in
    List.concat (List.map check fields)
  | Variant { variants } ->
    let check first boxed_tag =
      let BoxedTag t = boxed_tag in
      match t.vcontents with
      | Unit ->
        [ Line (sprintf "%sif %s == '%s':" (if first then "" else "el") v t.vname) ]
      | ty ->
        [ Line (sprintf "%sif %s[0] == '%s':" (if first then "" else "el") v t.vname);
          Block (typecheck ty (sprintf "%s[1:]" v))
        ] in
    List.fold_left (fun acc x -> List.concat [(check false x);acc]) (check true (List.hd variants)) (List.tl variants) 
  | Array t ->
    let id = fresh_id () in
    [
      Line (sprintf "if type(%s) <> type([]):" v);
      Block [ raise_type_error ];
      Line (sprintf "for %s in %s:" id v);
      Block (typecheck t id)
    ]
  | List t ->
    let id = fresh_id () in
    [
      Line (sprintf "if type(%s) <> type([]):" v);
      Block [ raise_type_error ];
      Line (sprintf "for %s in %s:" id v);
      Block (typecheck t id)
    ]
  | Dict (key, va) ->
    let id = fresh_id () in
    [
      Line (sprintf "if type(%s) <> type({}):" v);
      Block [ raise_type_error ];
      Line (sprintf "for %s in %s.keys():" id v);
      Block (typecheck (Basic key) id);
      Line (sprintf "for %s in %s.values():" id v);
      Block (typecheck va id)
    ]
  | Unit ->
    [
      Line (sprintf "if type(%s) <> type(None):" v);
      Block [ raise_type_error ]
    ]
  | Option t ->
    [
      Line (sprintf "if %s <> None:" v);
      Block (typecheck t v)
    ]
  | Tuple (a, b) ->
    [
      Line "# Not sure how to typecheck pairs"
    ]

let rec value_of : type a. a Types.typ -> string =
  let open Types in
  let open Printf in function
    | Basic Int64 -> "0L"
    | Basic Int -> "0L"
    | Basic Int32 -> "0"
    | Basic Char -> "'c'"
    | Basic String -> "\"string\""
    | Basic Float -> "1.1"
    | Basic Bool -> "True"
    | DateTime -> "\"19700101T00:00:00Z\""
    | Struct { fields } ->
      let member boxed_field =
        let BoxedField f = boxed_field in
        sprintf "\"%s\": %s" f.fname (value_of f.field) in
      sprintf "{ %s }" (String.concat ", " (List.map member fields))
    | Variant { variants } ->
      "None"
    | Array t ->
      sprintf "[ %s, %s ]" (value_of t) (value_of t)
    | List t ->
      sprintf "[ %s, %s ]" (value_of t) (value_of t)
    | Dict (key, va) ->
      sprintf "{ %s: %s }" (value_of (Basic key)) (value_of va)
    | Unit ->
      "None"
    | Option t ->
      "None"
    | Tuple (a, b) ->
      "[]"

(*
let exn_decl env e =
  let open Printf in
  let rec unpair = function
    | Type.Pair(a, b) -> unpair a @ (unpair b)
    | Type.Name x -> unpair((List.assoc x env).Ident.ty)
    | t -> [ t ] in
  let args = unpair e.TyDecl.ty in
  let names = List.fold_left (fun (i, acc) _ -> (i + 1, sprintf "arg_%d" i :: acc)) (0, []) args |> snd |> List.rev in
  [
    Line (sprintf "class %s(Rpc_light_failure):" e.TyDecl.name);
    Block ([
        Line (sprintf "def __init__(self%s):" (String.concat "" (List.map (fun x -> ", " ^ x) names)));
        Block (
          [ Line (sprintf "Rpc_light_failure.__init__(self, \"%s\", [ %s ])" e.TyDecl.name (String.concat ", " names))
          ] @ (List.concat (List.map (fun (ty, v) -> typecheck env ty v) (List.combine args names))
              ) @ (List.map (fun v -> Line (sprintf "self.%s = %s" v v)) names)
        )
      ])
  ]
*)

let skeleton_method unimplemented i (BoxedFunction m) =
  let inputs = find_inputs m.Method.ty in
  let output = find_output m.Method.ty in

  let open Printf in
  [
    Line (sprintf "def %s(self%s):" m.Method.name (String.concat "" (List.map (fun x -> ", " ^ x) (List.map (fun (Idl.Param.Boxed x) -> x.Idl.Param.name) inputs))));
    Block ([
        Line (sprintf "\"\"\"%s\"\"\"" i.Interface.details.Idl.Interface.description);
      ] @ (
          if unimplemented
          then [ Line (sprintf "raise Unimplemented(\"%s.%s\")" i.Interface.details.Idl.Interface.name m.Method.name) ]
          else ([
              Line "result = {}";
            ] @ (
                List.map (fun (Idl.Param.Boxed a) -> Line (sprintf "result[\"%s\"] = %s" a.Idl.Param.name (value_of a.Idl.Param.typedef.Types.ty))) [output]
              ) @ [
                Line "return result"
              ])
        ))
  ]

let example_stub_user i m =
  let open Printf in
  [
    Line "";
    Line "import xmlrpclib";
    Line "import xapi";
    Line "from storage import *";
    Line "";
    Line "if __name__ == \"__main__\":";
    Block [
      Line "c = xapi.connect()";
      Line (Printf.sprintf "results = c.%s.%s({ %s })" i.Interface.details.Idl.Interface.name m.Method.name
              (String.concat ", " (List.map (fun (Idl.Param.Boxed a) -> sprintf "%s: %s" a.Idl.Param.name (value_of a.Idl.Param.typedef.Types.ty)) (find_inputs m.Method.ty))));
      Line "print (repr(results))"
    ]
  ]

let example_skeleton_user i m =
  let open Printf in
  [
    Line "";
    Line "import xmlrpclib";
    Line "import xapi";
    Line "from storage import *";
    Line "";
    Line (sprintf "class %s_myimplementation(%s_skeleton):" i.Interface.details.Idl.Interface.name i.Interface.details.Idl.Interface.name);
    Block ([
        Line "# by default each method will return a Not_implemented error";
        Line "# ..."
      ] @ (skeleton_method false i m
          ) @ [
          Line "# ..."
        ]);
  ]

let rec skeleton_of_interface unimplemented suffix i =
  let open Printf in
  [
    Line (sprintf "class %s_%s:" i.Interface.details.Idl.Interface.name suffix);
    Block ([
        Line (sprintf "\"\"\"%s\"\"\"" i.Interface.details.Idl.Interface.description);
        Line "def __init__(self):";
        Block [
          Line "pass";
        ];
      ] @ (
          List.concat (List.map (skeleton_method unimplemented i) i.Interface.methods)
        ))
  ]

let test_impl_of_interface = skeleton_of_interface false "test"
let skeleton_of_interface = skeleton_of_interface true "skeleton"

let server_of_interface i =
  let open Printf in
  let typecheck_method_wrapper (BoxedFunction m) =
    let inputs = find_inputs m.Method.ty in
    let output = find_output m.Method.ty in
    let extract_input (Idl.Param.Boxed arg) =
      [ Line (sprintf "if not(args.has_key('%s')):" arg.Idl.Param.name);
        Block [ Line (sprintf "raise UnmarshalException('argument missing', '%s', '')" arg.Idl.Param.name) ];
        Line (sprintf "%s = args[\"%s\"]" arg.Idl.Param.name arg.Idl.Param.name) ]
      @ (typecheck arg.Idl.Param.typedef.Types.ty arg.Idl.Param.name) in
    let check_output (Idl.Param.Boxed arg) =
      (* The ocaml rpc-light doesn't actually support named results, instead we
         			   have single anonymous results only. *)
      typecheck arg.Idl.Param.typedef.Types.ty "results" in
    [
      Line (sprintf "def %s(self, args):" m.Method.name);
      Block ([
          Line "\"\"\"type-check inputs, call implementation, type-check outputs and return\"\"\"";
          Line "if type(args) <> type({}):";
          Block [
            Line "raise (UnmarshalException('arguments', 'dict', repr(args)))"
          ]
        ] @ (
            List.concat (List.map extract_input inputs)
          ) @ [
            Line (sprintf "results = self._impl.%s(%s)" m.Method.name (String.concat ", " (List.map (fun (Idl.Param.Boxed x) -> x.Idl.Param.name) inputs)))
          ] @ (
            List.concat (List.map check_output [output])
          ) @ [
            Line "return results"
          ])
    ] in    
  let dispatch_method first (BoxedFunction m) =
    [ Line (sprintf "%sif method == \"%s.%s\":" (if first then "" else "el") i.Interface.details.Idl.Interface.name m.Method.name);
      Block [ Line (sprintf "return success(self.%s(args))" m.Method.name) ]
    ] in
  let first_is_special f xs = match xs with
    | [] -> []
    | x :: xs -> f true x :: (List.map (f false) xs) in
  [
    Line (sprintf "class %s_server_dispatcher:" i.Interface.details.Idl.Interface.name);
    Block ([
        Line (sprintf "\"\"\"%s\"\"\"" i.Interface.details.Idl.Interface.description);
        Line "def __init__(self, impl):";
        Block [
          Line "\"\"\"impl is a proxy object whose methods contain the implementation\"\"\"";
          Line "self._impl = impl";
        ];
      ] @ (List.concat (List.map typecheck_method_wrapper i.Interface.methods)
          ) @ [
          Line "def _dispatch(self, method, params):";
          Block ([
              Line "\"\"\"type check inputs, call implementation, type check outputs and return\"\"\"";
              Line "args = params[0]";
            ] @ (List.concat (first_is_special dispatch_method i.Interface.methods)))
        ])
  ]

let test_impl_of_interfaces i =
  let open Printf in
  [
    Line (sprintf "class %s_server_test(%s_server_dispatcher):" i.Interfaces.name i.Interfaces.name);
    Block [
      Line "\"\"\"Create a server which will respond to all calls, returning arbitrary values. This is intended as a marshal/unmarshal test.\"\"\"";
      Line "def __init__(self):";
      Block [
        Line (sprintf "%s_server_dispatcher.__init__(self%s)" i.Interfaces.name (String.concat "" (List.map (fun i -> ", " ^ i.Interface.details.Idl.Interface.name ^ "_server_dispatcher(" ^ i.Interface.details.Idl.Interface.name ^ "_test())") i.Interfaces.interfaces)))
      ]
    ]
  ]

let commandline_parse i (BoxedFunction m) =
  let open Printf in
  let inputs = find_inputs m.Method.ty in
  let output = find_output m.Method.ty in
  [
    Line (sprintf "def _parse_%s(self):" m.Method.name);
    Block ([
        Line (sprintf "\"\"\"%s\"\"\"" m.Method.description);
      ] @ [
        Line "# in --json mode we don't have any other arguments";
        Line "if ('--json' in sys.argv or '-j' in sys.argv):";
        Block [
            Line "jsondict = json.loads(sys.stdin.readline(),)";
            Line "jsondict['json'] = True";
            Line "return jsondict";
        ];
        Line (sprintf "parser = argparse.ArgumentParser(description='%s')" m.Method.description);
        Line "parser.add_argument('-j', '--json', action='store_const', const=True, default=False, help='Read json from stdin, print json to stdout', required=False)";
      ] @ (
        List.map (fun (Idl.Param.Boxed a) -> match a.Idl.Param.typedef.Types.ty with
        | Types.Dict(_, _) ->
          Line (sprintf "parser.add_argument('--%s', default = {}, nargs=2, action=xapi.ListAction, help='%s')" a.Idl.Param.name a.Idl.Param.description)
        | _ ->
          Line (sprintf "parser.add_argument('%s', action='store', help='%s')" a.Idl.Param.name a.Idl.Param.description)
        ) inputs
      ) @ [
        Line "return vars(parser.parse_args())";
      ])
  ]

let commandline_run i (BoxedFunction m) =
  let open Printf in
  [
    Line (sprintf "def %s(self):" m.Method.name);
    Block [
      Line "use_json = False";
      Line "try:";
      Block [
        Line (sprintf "request = self._parse_%s()" m.Method.name);
        Line "use_json = 'json' in request and request['json']";
        Line (sprintf "results = self.dispatcher.%s(request)" m.Method.name);
        Line "print json.dumps(results)";
      ];
      Line "except Exception, e:";
      Block [
        Line "if use_json:";
        Block [Line "xapi.handle_exception(e)"];
        Line "else:";
        Block [
          Line "traceback.print_exc()";
          Line "raise e"
        ];
      ]
    ]
  ]

let commandline_of_interface i =
  let open Printf in
  [
    Line "import argparse, traceback";
    Line "import xapi";
    Line (sprintf "class %s_commandline():" i.Interface.details.Idl.Interface.name);
    Block ([
      Line "\"\"\"Parse command-line arguments and call an implementation.\"\"\"";
      Line "def __init__(self, impl):";
      Block [
        Line "self.impl = impl";
        Line (sprintf "self.dispatcher = %s_server_dispatcher(self.impl)" i.Interface.details.Idl.Interface.name);
      ];
   ] @ (List.concat (List.map (commandline_parse i) i.Interface.methods)) @ (
        List.concat (List.map (commandline_run i) i.Interface.methods))
   )
  ]

let of_interfaces i =
  let open Printf in
  [
    Line "from xapi import *";
    Line "import traceback";
  ] (*@ (
    List.concat (List.map (exn_decl env) i.Interfaces.exn_decls)
      ) *) @ (
    List.fold_left (fun acc i -> acc @
                                 (server_of_interface i) @ (skeleton_of_interface i) @ (test_impl_of_interface i) @ (commandline_of_interface i)
                   ) [] i.Interfaces.interfaces
  ) @ [
    Line (sprintf "class %s_server_dispatcher:" i.Interfaces.name);
    Block ([
        Line "\"\"\"Demux calls to individual interface server_dispatchers\"\"\"";
        Line (sprintf "def __init__(self%s):" (String.concat "" (List.map (fun x -> ", " ^ x ^ " = None") (List.map (fun i -> i.Interface.details.Idl.Interface.name) i.Interfaces.interfaces))));
        Block (List.map (fun i -> Line (sprintf "self.%s = %s" i.Interface.details.Idl.Interface.name i.Interface.details.Idl.Interface.name)) i.Interfaces.interfaces);
        Line "def _dispatch(self, method, params):";
        Block [
          Line "try:";
          Block ([
              Line "log(\"method = %s params = %s\" % (method, repr(params)))";
            ] @ (
                List.fold_left (fun (first, acc) i -> false, acc @ [
                    Line (sprintf "%sif method.startswith(\"%s\") and self.%s:" (if first then "" else "el") i.Interface.details.Idl.Interface.name i.Interface.details.Idl.Interface.name);
                    Block [ Line (sprintf "return self.%s._dispatch(method, params)" i.Interface.details.Idl.Interface.name) ];
                  ]) (true, []) i.Interfaces.interfaces |> snd
              ) @ [
                Line "raise UnknownMethod(method)"
              ]
            );
          Line "except Exception, e:";
          Block [
            Line "log(\"caught %s\" % e)";
            Line "traceback.print_exc()";
            Line "try:";
            Block [
              Line "# A declared (expected) failure will have a .failure() method";
              Line "log(\"returning %s\" % (repr(e.failure())))";
              Line "return e.failure()"
            ];
            Line "except:";
            Block [
              Line "# An undeclared (unexpected) failure is wrapped as InternalError";
              Line "return (InternalError(str(e)).failure())"
            ]
          ]
        ]
      ])
  ] @ (test_impl_of_interfaces i)
