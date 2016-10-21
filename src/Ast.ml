(** The internal, typed AST that we perform all transformations on.
 * TODO: factor out the many nodes into something more atomic (e.g. EPrimitive).
 * Since the buffer functions are polymorphic, they would still have to be
 * special-cased in [Checker], or we would have to switch to unification. *)

module K = Constant

type program =
  decl list

and file =
  string * program

and decl =
  | DFunction of CallingConvention.t option * flag list * typ * lident * binder list * expr
  | DGlobal of flag list * lident * typ * expr
  | DExternal of CallingConvention.t option * lident * typ
  | DType of lident * type_def

and type_def =
  | Abbrev of int * typ
  | Flat of fields_t
  | Variant of branches_t
  | Enum of lident list
  | Union of (ident option * typ) list

and fields_t =
  (ident * (typ * bool)) list

and branches_t =
  (ident * fields_t) list

and flag =
  | Private

and expr' =
  | EBound of var
  | EOpen of ident * Atom.t
    (** [ident] for debugging purposes only *)
  | EQualified of lident
  | EConstant of K.t
  | EUnit
  | EApp of expr * expr list
  | ELet of binder * expr * expr
  | EIfThenElse of expr * expr * expr
  | ESequence of expr list
  | EAssign of expr * expr
    (** left expression can only be a EBound or EOpen *)
  | EBufCreate of expr * expr
    (** initial value, length *)
  | EBufRead of expr * expr
    (** e1[e2] *)
  | EBufWrite of expr * expr * expr
    (** e1[e2] <- e3 *)
  | EBufSub of expr * expr
    (** e1 + e2 *)
  | EBufBlit of expr * expr * expr * expr * expr
    (** e1, index; e2, index; len *)
  | EMatch of expr * branches
  | EOp of K.op * K.width
  | ECast of expr * typ
  | EPushFrame
  | EPopFrame
  | EBool of bool
  | EAny
    (** to indicate that the initial value of a mutable let-binding does not
     * matter *)
  | EAbort
    (** exits the program prematurely *)
  | EReturn of expr
  | EFlat of (ident * expr) list
  | EField of expr * ident
  | EWhile of expr * expr
  | EBufCreateL of expr list
  | ECons of ident * expr list
  | ETuple of expr list
  | EEnum of lident
  | ESwitch of expr * (lident * expr) list

and expr =
  expr' with_type

and 'a with_type = {
  node: 'a;
  mutable typ: typ
    (** Filled in by [Checker] *)
}

and branches =
  branch list

and branch =
  pattern * expr

and pattern' =
  | PUnit
  | PBool of bool
  | PVar of binder
  | PCons of ident * pattern list
  | PEnum of lident
  | PTuple of pattern list
  | PRecord of (ident * pattern) list

and pattern =
  pattern' with_type

and var =
  int (** a De Bruijn index *)

and binder' = {
  name: ident;
  mut: bool;
  mark: int ref;
  meta: meta option;
  atom: Atom.t;
    (** Only makes sense when opened! *)
}

and binder =
  binder' with_type

and meta =
  | MetaSequence

and ident =
  string (** for pretty-printing *)

and lident =
  ident list * ident

and typ =
  | TInt of K.width
  | TBool
  | TUnit
  | TAny
      (** appears because of casts introduced by erasure... eventually, should
       * not appear! *)
  | TBuf of typ
      (** a buffer in the Low* sense *)
  | TQualified of lident
      (** a reference to a type that has been introduced via a DType *)
  | TArrow of typ * typ
      (** t1 -> t2 *)
  | TApp of lident * typ list
      (** disappears after monomorphization *)
  | TBound of int
      (** appears in type definitions... also disappears after monorphization *)
  | TTuple of typ list
      (** disappears after tuple removal *)
  | TAnonymous of type_def
      (** appears after data type translation to tagged enums *)
  | TZ
      (** unused *)

let with_type typ node =
  { typ; node }

let flatten_arrow =
  let rec flatten_arrow acc = function
    | TArrow (t1, t2) -> flatten_arrow (t1 :: acc) t2
    | t -> t, List.rev acc
  in
  flatten_arrow []

let fresh_binder ?(mut=false) name typ =
  with_type typ { name; mut; mark = ref 0; meta = None; atom = Atom.fresh () }


(** Some visitors for our AST of expressions *)

let rec binders_of_pat p =
  match p.node with
  | PVar b ->
      [ b ]
  | PTuple ps
  | PCons (_, ps) ->
      KList.map_flatten binders_of_pat ps
  | PRecord fields ->
      KList.map_flatten binders_of_pat (snd (List.split fields))
  | PUnit
  | PEnum _
  | PBool _ ->
      []

class virtual ['env] map = object (self)

  (* Extend the environment; these methods are meant to be overridden. *)
  method extend (env: 'env) (_: binder): 'env =
    env

  method extend_many env binders =
    List.fold_left self#extend env binders

  method extend_t (env: 'env): 'env =
    env

  (* Toplevel visitor. *)
  method visit_file (env: 'env) (file: file) =
    let name, decls = file in
    name, List.map (self#visit_d env) decls

  (* Expression visitors. *)
  method visit_e (env: 'env) (e: expr') (typ: 'extra): 'result =
    match e with
    | EBound var ->
        self#ebound env typ var
    | EOpen (name, atom) ->
        self#eopen env typ name atom
    | EQualified lident ->
        self#equalified env typ lident
    | EConstant c ->
        self#econstant env typ c
    | EUnit ->
        self#eunit env typ
    | EApp (e, es) ->
        self#eapp env typ e es
    | ELet (b, e1, e2) ->
        self#elet env typ b e1 e2
    | EIfThenElse (e1, e2, e3) ->
        self#eifthenelse env typ e1 e2 e3
    | ESequence es ->
        self#esequence env typ es
    | EAssign (e1, e2) ->
        self#eassign env typ e1 e2
    | EBufCreate (e1, e2) ->
        self#ebufcreate env typ e1 e2
    | EBufRead (e1, e2) ->
        self#ebufread env typ e1 e2
    | EBufWrite (e1, e2, e3) ->
        self#ebufwrite env typ e1 e2 e3
    | EBufBlit (e1, e2, e3, e4, e5) ->
        self#ebufblit env typ e1 e2 e3 e4 e5
    | EBufSub (e1, e2) ->
        self#ebufsub env typ e1 e2
    | EMatch (e, branches) ->
        self#ematch env typ e branches
    | EOp (op, w) ->
        self#eop env typ op w
    | ECast (e, t) ->
        self#ecast env typ e t
    | EPushFrame ->
        self#epushframe env typ
    | EPopFrame ->
        self#epopframe env typ
    | EBool b ->
        self#ebool env typ b
    | EAny ->
        self#eany env typ
    | EAbort ->
        self#eabort env typ
    | EReturn e ->
        self#ereturn env typ e
    | EFlat fields ->
        self#eflat env typ fields
    | EField (e, field) ->
        self#efield env typ e field
    | EWhile (e1, e2) ->
        self#ewhile env typ e1 e2
    | EBufCreateL es ->
        self#ebufcreatel env typ es
    | ECons (cons, es) ->
        self#econs env typ cons es
    | ETuple es ->
        self#etuple env typ es
    | EEnum lid ->
        self#eenum env typ lid
    | ESwitch (e, branches) ->
        self#eswitch env typ e branches

  method ebound _env _typ var =
    EBound var

  method eopen _env _typ name atom =
    EOpen (name, atom)

  method equalified _env _typ lident =
    EQualified lident

  method econstant _env _typ constant =
    EConstant constant

  method eabort _env _typ =
    EAbort

  method eany _env _typ =
    EAny

  method eunit _env _typ =
    EUnit

  method eapp env _typ e es =
    EApp (self#visit env e, List.map (self#visit env) es)

  method elet env _typ b e1 e2 =
    let b = { b with typ = self#visit_t env b.typ } in
    ELet (b, self#visit env e1, self#visit (self#extend env b) e2)

  method eifthenelse env _typ e1 e2 e3 =
    EIfThenElse (self#visit env e1, self#visit env e2, self#visit env e3)

  method esequence env _typ es =
    ESequence (List.map (self#visit env) es)

  method eassign env _typ e1 e2 =
    EAssign (self#visit env e1, self#visit env e2)

  method ebufcreate env _typ e1 e2 =
    EBufCreate (self#visit env e1, self#visit env e2)

  method ebufread env _typ e1 e2 =
    EBufRead (self#visit env e1, self#visit env e2)

  method ebufwrite env _typ e1 e2 e3 =
    EBufWrite (self#visit env e1, self#visit env e2, self#visit env e3)

  method ebufblit env _typ e1 e2 e3 e4 e5 =
    EBufBlit (self#visit env e1, self#visit env e2, self#visit env e3, self#visit env e4, self#visit env e5)

  method ebufsub env _typ e1 e2 =
    EBufSub (self#visit env e1, self#visit env e2)

  method ematch env _typ e branches =
    EMatch (self#visit env e, self#branches env branches)

  method eop _env _typ o w =
    EOp (o, w)

  method ecast env _typ e t =
    ECast (self#visit env e, self#visit_t env t)

  method epopframe _env _typ =
    EPopFrame

  method epushframe _env _typ =
    EPushFrame

  method ebool _env _typ b =
    EBool b

  method ereturn env _typ e =
    EReturn (self#visit env e)

  method eflat env _typ fields =
    EFlat (self#fields env fields)

  method efield env _typ e field =
    EField (self#visit env e, field)

  method ewhile env _typ e1 e2 =
    EWhile (self#visit env e1, self#visit env e2)

  method ebufcreatel env _typ es =
    EBufCreateL (List.map (self#visit env) es)

  method econs env _typ ident es =
    ECons (ident, List.map (self#visit env) es)

  method etuple env _typ es =
    ETuple (List.map (self#visit env) es)

  method eenum _env _typ lid =
    EEnum lid

  method eswitch env _ e branches =
    ESwitch (self#visit env e, List.map (fun (lid, e) ->
      lid, self#visit env e
    ) branches)

  (* Some helpers *)

  method fields env fields =
    List.map (fun (ident, expr) -> ident, self#visit env expr) fields

  method branches env branches =
    List.map (fun (pat, expr) ->
      let binders = binders_of_pat pat in
      let env = List.fold_left self#extend env binders in
      self#visit_pattern env pat, self#visit env expr
    ) branches

  (* Patterns *)

  method visit_p env pat t =
    match pat with
    | PUnit ->
        self#punit env
    | PBool b ->
        self#pbool env b
    | PVar b ->
        self#pvar env t b
    | PCons (ident, fields) ->
        self#pcons env t ident fields
    | PTuple ps ->
        self#ptuple env t ps
    | PRecord fields ->
        self#precord env t fields
    | PEnum lid ->
        self#penum env t lid

  method punit _env =
    PUnit

  method pbool _env b =
    PBool b

  method pvar _env _t b =
    PVar b

  method pcons env _t ident pats =
    PCons (ident, List.map (self#visit_pattern env) pats)

  method ptuple env _t pats =
    PTuple (List.map (self#visit_pattern env) pats)

  method precord env _t fields =
    PRecord (List.map (fun (f, p) -> f, self#visit_pattern env p) fields)

  method penum _env _t lid =
    PEnum lid

  (* Types *)

  method visit_t (env: 'env) (t: typ): 'tresult =
    match t with
    | TInt w ->
        self#tint env w
    | TBuf t ->
        self#tbuf env t
    | TUnit ->
        self#tunit env
    | TQualified lid ->
        self#tqualified env lid
    | TBool ->
        self#tbool env
    | TAny ->
        self#tany env
    | TArrow (t1, t2) ->
        self#tarrow env t1 t2
    | TZ ->
        self#tz env
    | TBound i ->
        self#tbound env i
    | TApp (name, args) ->
        self#tapp env name (List.map (self#visit_t env) args)
    | TTuple ts ->
        self#ttuple env (List.map (self#visit_t env) ts)
    | TAnonymous t ->
        self#tanonymous env t

  method tint _env w =
    TInt w

  method tbuf env t =
    TBuf (self#visit_t env t)

  method tunit _env =
    TUnit

  method tqualified _env lid =
    TQualified lid

  method tbool _env =
    TBool

  method tany _env =
    TAny

  method tarrow env t1 t2 =
    TArrow (self#visit_t env t1, self#visit_t env t2)

  method tz _env =
    TZ

  method tbound _env i =
    TBound i

  method tapp env lid ts =
    TApp (lid, List.map (self#visit_t env) ts)

  method ttuple env ts =
    TTuple (List.map (self#visit_t env) ts)

  method tanonymous env d =
    TAnonymous (self#type_def env None d)

  (* Once types and expressions can be visited, a more generic method that
   * handles the type. *)

  method visit_pattern env p: pattern =
    let typ = self#visit_t env p.typ in
    let node = self#visit_p env p.node typ in
    { node; typ }

  method visit env e: expr =
    let typ = self#visit_t env e.typ in
    let node = self#visit_e env e.node typ in
    { node; typ }


  (* Declarations *)

  method visit_d (env: 'env) (d: decl): 'dresult =
    match d with
    | DFunction (cc, flags, ret, name, binders, expr) ->
        self#dfunction env cc flags ret name binders expr
    | DGlobal (flags, name, typ, expr) ->
        self#dglobal env flags name typ expr
    | DExternal (cc, name, t) ->
        self#dexternal env cc name t
    | DType (name, d) ->
        self#dtype env name d

  method dtype env name d =
    DType (name, self#type_def env (Some name) d)

  method type_def (env: 'env) (name: lident option) (d: type_def) =
    match d with
    | Flat fields ->
        self#dtypeflat env fields
    | Abbrev (n, t) ->
        self#dtypealias env n t
    | Variant branches ->
        self#dtypevariant env (Option.must name) branches
    | Enum tags ->
        self#dtypeenum env tags
    | Union ts ->
        self#dtypeunion env ts

  method binders env binders =
    List.map (fun binder -> { binder with typ = self#visit_t env binder.typ }) binders

  method dfunction env cc flags ret name binders expr =
    let binders = self#binders env binders in
    let env = self#extend_many env binders in
    DFunction (cc, flags, self#visit_t env ret, name, binders, self#visit env expr)

  method dglobal env flags name typ expr =
    DGlobal (flags, name, self#visit_t env typ, self#visit env expr)

  method dexternal env cc name t =
    DExternal (cc, name, self#visit_t env t)

  method dtypealias env n t =
    let rec extend e n =
      if n = 0 then
        e
      else
        extend (self#extend_t e) (n - 1)
    in
    let env = extend env n in
    Abbrev (n, self#visit_t env t)

  method fields_t env fields =
    List.map (fun (name, (t, mut)) -> name, (self#visit_t env t, mut)) fields

  method dtypeflat env fields =
    let fields = self#fields_t env fields in
    Flat fields

  method dtypevariant env _lid branches =
    Variant (self#branches_t env branches)

  method dtypeenum _env tags =
    Enum tags

  method dtypeunion env ts =
    Union (List.map (fun (name, t) -> name, self#visit_t env t) ts)

  method branches_t env branches =
    List.map (fun (ident, fields) -> ident, self#fields_t env fields) branches
end
