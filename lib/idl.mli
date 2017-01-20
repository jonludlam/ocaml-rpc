(** The Idl module is for declaring the types and documentation for RPC calls *)

(** The Param module is associated with parameters to RPCs. RPCs are defined in terms of
    'a Param.t values. *)
module Param : sig

  (** A Param.t has a name, description and a typedef. We may also want to add in here
      default values, example values and so on *)
  type 'a t = {
    name : string;
    description : string list;
    typedef : 'a Rpc.Types.def;
    version : Rpc.Version.t option;
  }

  (** We box parameters to put them into lists *)
  type boxed = Boxed : 'a t -> boxed

  (** [mk ~name ~description typ] creates a Param.t out of a type definition
      from the Types module. If the name or description are omitted, the name
      or description from the type definition will be inherited *)
  val mk : ?name:string -> ?description:string list -> ?version:Rpc.Version.t -> 'a Rpc.Types.def -> 'a t
end

(* An error that might be raised by an RPC *)
module Error : sig
  type 'a t = {
    def : 'a Rpc.Types.def;
    raiser : 'a -> exn;
    matcher : exn -> 'a option;
  }

  module Make(T : sig type t val t : t Rpc.Types.def end) : sig
    val error : T.t t
  end
end

(** An interface is a collection of RPC declarations. *)
module Interface : sig
  type description = {
    name : string;
    namespace : string option;
    description : string list;
    version : Rpc.Version.t;
  }
end

(** The RPC module type is the standard module signature that the various
    specialization modules must conform to. *)
module type RPC = sig

  (** The implementation is dependent on the module. *)
  type implementation
  val implement : Interface.description -> implementation

  (** 'a res is the result type of declaring a function. For example,
      the Client module, given an (int -> int -> int) fn, will return
      a function of type 'a - in this case, (int -> int -> int) *)
  type 'a res

  (** This is for inserting a type in between the function application
      and its result. For example, this could be an Lwt.t, meaning that
      the result of a function application is a thread *)
  type ('a,'b) comp

  (** The GADT specifying the type of the RPC *)
  type _ fn

  (** This infix operator is for constructing function types *)
  val (@->) : 'a Param.t -> 'b fn -> ('a -> 'b) fn

  (** This defines the return type of an RPC *)
  val returning : 'a Param.t -> 'b Error.t -> ('a, 'b) comp fn

  (** [declare name description typ] is how an RPC is declared to the
      module implementing the functionality. The return type is dependent
      upon the module being used *)
  val declare : string -> string list -> 'a fn -> 'a res
end

type client_implementation = unit

(** This module generates Client modules from RPC declarations *)
module GenClient () : sig
  type implementation = client_implementation
  val implement : Interface.description -> implementation

  (** The result of declaring a function of type 'a (where for example
             'a might be (int -> string -> bool)), is a function that takes
             an rpc function, which might send the RPC across the network,
             and returns a function of type 'a, in this case (int -> string
             -> bool). *)
  type rpcfn = Rpc.call -> Rpc.response
  type 'a res = rpcfn -> 'a

  (** Our functions return a Result.result type, which either contains
       -      the result of the Rpc, or an error message indicating a problem
       -      happening at the transport level *)
  type ('a,'b) comp = ('a,'b) Result.result
  type _ fn
  val (@->) : 'a Param.t -> 'b fn -> ('a -> 'b) fn
  val returning : 'a Param.t -> 'b Error.t -> ('a, 'b) comp fn
  val declare : string -> string list -> 'a fn -> rpcfn -> 'a
end


(** This module generates exception-raising Client modules from RPC
    declarations *)
module GenClientExn () : sig
  type implementation = client_implementation
  val implement : Interface.description -> implementation

  (** The result of declaring a function of type 'a (where for example
             'a might be (int -> string -> bool)), is a function that takes
             an rpc function, which might send the RPC across the network,
             and returns a function of type 'a, in this case (int -> string
             -> bool). *)
  type rpcfn = Rpc.call -> Rpc.response
  type 'a res = rpcfn -> 'a

  (** Our functions return a Result.result type, which either contains
       -      the result of the Rpc, or an error message indicating a problem
       -      happening at the transport level *)
  type ('a,'b) comp = 'a
  type _ fn
  val (@->) : 'a Param.t -> 'b fn -> ('a -> 'b) fn
  val returning : 'a Param.t -> 'b Error.t -> ('a, 'b) comp fn
  val declare : string -> string list -> 'a fn -> rpcfn -> 'a
end

module GenServer () : sig
  type implementation = Rpc.call -> Rpc.response
  val implement : Interface.description -> implementation

  (** 'funcs' is a Hashtbl type that is used to hold the implementations of
             the RPCs *)
  type rpcfn = Rpc.call -> Rpc.response

  type 'a res = 'a -> unit
  (** No error handling done server side yet *)
  type ('a,'b) comp = ('a,'b) Result.result

  type _ fn

  val (@->) : 'a Param.t -> 'b fn -> ('a -> 'b) fn
  val returning : 'a Param.t -> 'b Error.t -> ('a, 'b) comp fn
  val declare : string -> string list -> 'a fn -> 'a res
end

module GenServerExn () : sig
  type implementation = Rpc.call -> Rpc.response
  val implement : Interface.description -> implementation

  (** 'funcs' is a Hashtbl type that is used to hold the implementations of
             the RPCs *)
  type rpcfn = Rpc.call -> Rpc.response

  type 'a res = 'a -> unit
  (** No error handling done server side yet *)
  type ('a,'b) comp = 'a

  type _ fn

  val (@->) : 'a Param.t -> 'b fn -> ('a -> 'b) fn
  val returning : 'a Param.t -> 'b Error.t -> ('a, 'b) comp fn
  val declare : string -> string list -> 'a fn -> 'a res
end

module DefaultError : sig
  type t = InternalError of string
  exception InternalErrorExn of string

  val internalerror : (string, t) Rpc.Types.tag
  val t : t Rpc.Types.variant
  val def : t Rpc.Types.def
  val err : t Error.t
end
