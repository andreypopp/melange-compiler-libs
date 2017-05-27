/**************************************************************************/
/*                                                                        */
/*                                 OCaml                                  */
/*                                                                        */
/*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           */
/*                                                                        */
/*   Copyright 1996 Institut National de Recherche en Informatique et     */
/*     en Automatique.                                                    */
/*                                                                        */
/*   All rights reserved.  This file is distributed under the terms of    */
/*   the GNU Lesser General Public License version 2.1, with the          */
/*   special exception on linking described in the file LICENSE.          */
/*                                                                        */
/**************************************************************************/

/* The parser definition */

%{
open Location
open Asttypes
open Longident
open Parsetree
open Ast_helper
open Docstrings

let mktyp d = Typ.mk ~loc:(symbol_rloc()) d
let mkpat d = Pat.mk ~loc:(symbol_rloc()) d
let mkexp d = Exp.mk ~loc:(symbol_rloc()) d
let mkmty ?attrs d = Mty.mk ~loc:(symbol_rloc()) ?attrs d
let mksig d = Sig.mk ~loc:(symbol_rloc()) d
let mkmod ?attrs d = Mod.mk ~loc:(symbol_rloc()) ?attrs d
let mkstr d = Str.mk ~loc:(symbol_rloc()) d
let mkclass ?attrs d = Cl.mk ~loc:(symbol_rloc()) ?attrs d
let mkcty ?attrs d = Cty.mk ~loc:(symbol_rloc()) ?attrs d
let mkctf ?attrs ?docs d =
  Ctf.mk ~loc:(symbol_rloc()) ?attrs ?docs d
let mkcf ?attrs ?docs d =
  Cf.mk ~loc:(symbol_rloc()) ?attrs ?docs d

let mkrhs rhs pos = mkloc rhs (rhs_loc pos)

let mkrhs2 rhs pos1 pos2 =
  let loc_start = Parsing.rhs_start_pos pos1 in
  let loc_end = Parsing.rhs_end_pos pos2 in
  mkloc rhs { loc_start; loc_end; loc_ghost = false }

let reloc_pat x = { x with ppat_loc = symbol_rloc () };;
let reloc_exp x = { x with pexp_loc = symbol_rloc () };;
let reloc_typ x = { x with ptyp_loc = symbol_rloc () };;

let mkoperator name pos =
  let loc = rhs_loc pos in
  Exp.mk ~loc (Pexp_ident(mkloc (Lident name) loc))

let mkpatvar name pos =
  Pat.mk ~loc:(rhs_loc pos) (Ppat_var (mkrhs name pos))

(*
  Ghost expressions and patterns:
  expressions and patterns that do not appear explicitly in the
  source file they have the loc_ghost flag set to true.
  Then the profiler will not try to instrument them and the
  -annot option will not try to display their type.

  Every grammar rule that generates an element with a location must
  make at most one non-ghost element, the topmost one.

  How to tell whether your location must be ghost:
  A location corresponds to a range of characters in the source file.
  If the location contains a piece of code that is syntactically
  valid (according to the documentation), and corresponds to the
  AST node, then the location must be real; in all other cases,
  it must be ghost.
*)
let ghost = function
  | None -> symbol_gloc ()
  | Some l -> { l with loc_ghost = true }

let ghexp ?loc d = Exp.mk ~loc:(ghost loc) d
let ghpat ?loc d = Pat.mk ~loc:(ghost loc) d
let ghtyp ?loc d = Typ.mk ~loc:(ghost loc) d

let ghloc d = { txt = d; loc = symbol_gloc () }
let ghstr d = Str.mk ~loc:(symbol_gloc()) d
let ghsig d = Sig.mk ~loc:(symbol_gloc()) d

let mkinfix arg1 name arg2 =
  mkexp(Pexp_apply(mkoperator name 2, [Nolabel, arg1; Nolabel, arg2]))

let neg_string f =
  if String.length f > 0 && f.[0] = '-'
  then String.sub f 1 (String.length f - 1)
  else "-" ^ f

let mkuminus name arg =
  match name, arg.pexp_desc with
  | "-", Pexp_constant(Pconst_integer (n,m)) ->
      mkexp(Pexp_constant(Pconst_integer(neg_string n,m)))
  | ("-" | "-."), Pexp_constant(Pconst_float (f, m)) ->
      mkexp(Pexp_constant(Pconst_float(neg_string f, m)))
  | _ ->
      mkexp(Pexp_apply(mkoperator ("~" ^ name) 1, [Nolabel, arg]))

let mkuplus name arg =
  let desc = arg.pexp_desc in
  match name, desc with
  | "+", Pexp_constant(Pconst_integer _)
  | ("+" | "+."), Pexp_constant(Pconst_float _) -> mkexp desc
  | _ ->
      mkexp(Pexp_apply(mkoperator ("~" ^ name) 1, [Nolabel, arg]))

let mkexp_cons consloc args loc =
  Exp.mk ~loc (Pexp_construct(mkloc (Lident "::") consloc, Some args))

let mkpat_cons consloc args loc =
  Pat.mk ~loc (Ppat_construct(mkloc (Lident "::") consloc, Some args))

let rec mktailexp nilloc = function
    [] ->
      let loc = { nilloc with loc_ghost = true } in
      let nil = { txt = Lident "[]"; loc = loc } in
      Exp.mk ~loc (Pexp_construct (nil, None))
  | e1 :: el ->
      let exp_el = mktailexp nilloc el in
      let loc = {loc_start = e1.pexp_loc.loc_start;
               loc_end = exp_el.pexp_loc.loc_end;
               loc_ghost = true}
      in
      let arg = Exp.mk ~loc (Pexp_tuple [e1; exp_el]) in
      mkexp_cons {loc with loc_ghost = true} arg loc

let rec mktailpat nilloc = function
    [] ->
      let loc = { nilloc with loc_ghost = true } in
      let nil = { txt = Lident "[]"; loc = loc } in
      Pat.mk ~loc (Ppat_construct (nil, None))
  | p1 :: pl ->
      let pat_pl = mktailpat nilloc pl in
      let loc = {loc_start = p1.ppat_loc.loc_start;
               loc_end = pat_pl.ppat_loc.loc_end;
               loc_ghost = true}
      in
      let arg = Pat.mk ~loc (Ppat_tuple [p1; pat_pl]) in
      mkpat_cons {loc with loc_ghost = true} arg loc

let mkstrexp e attrs =
  { pstr_desc = Pstr_eval (e, attrs); pstr_loc = e.pexp_loc }

let mkexp_constraint e (t1, t2) =
  match t1, t2 with
  | Some t, None -> ghexp(Pexp_constraint(e, t))
  | _, Some t -> ghexp(Pexp_coerce(e, t1, t))
  | None, None -> assert false

let mkexp_opt_constraint e = function
  | None -> e
  | Some constraint_ -> mkexp_constraint e constraint_

let mkpat_opt_constraint p = function
  | None -> p
  | Some typ -> mkpat (Ppat_constraint(p, typ))

let array_function str name =
  ghloc (Ldot(Lident str, (if !Clflags.unsafe then "unsafe_" ^ name else name)))

let syntax_error () =
  raise Syntaxerr.Escape_error

let unclosed opening_name opening_num closing_name closing_num =
  raise(Syntaxerr.Error(Syntaxerr.Unclosed(rhs_loc opening_num, opening_name,
                                           rhs_loc closing_num, closing_name)))

let expecting pos nonterm =
    raise Syntaxerr.(Error(Expecting(rhs_loc pos, nonterm)))

let not_expecting pos nonterm =
    raise Syntaxerr.(Error(Not_expecting(rhs_loc pos, nonterm)))

let bigarray_function str name =
  ghloc (Ldot(Ldot(Lident "Bigarray", str), name))

let bigarray_untuplify = function
    { pexp_desc = Pexp_tuple explist; pexp_loc = _ } -> explist
  | exp -> [exp]

let bigarray_get arr arg =
  let get = if !Clflags.unsafe then "unsafe_get" else "get" in
  match bigarray_untuplify arg with
    [c1] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array1" get)),
                       [Nolabel, arr; Nolabel, c1]))
  | [c1;c2] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array2" get)),
                       [Nolabel, arr; Nolabel, c1; Nolabel, c2]))
  | [c1;c2;c3] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array3" get)),
                       [Nolabel, arr; Nolabel, c1; Nolabel, c2; Nolabel, c3]))
  | coords ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Genarray" "get")),
                       [Nolabel, arr; Nolabel, ghexp(Pexp_array coords)]))

let bigarray_set arr arg newval =
  let set = if !Clflags.unsafe then "unsafe_set" else "set" in
  match bigarray_untuplify arg with
    [c1] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array1" set)),
                       [Nolabel, arr; Nolabel, c1; Nolabel, newval]))
  | [c1;c2] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array2" set)),
                       [Nolabel, arr; Nolabel, c1;
                        Nolabel, c2; Nolabel, newval]))
  | [c1;c2;c3] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array3" set)),
                       [Nolabel, arr; Nolabel, c1;
                        Nolabel, c2; Nolabel, c3; Nolabel, newval]))
  | coords ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Genarray" "set")),
                       [Nolabel, arr;
                        Nolabel, ghexp(Pexp_array coords);
                        Nolabel, newval]))

let lapply p1 p2 =
  if !Clflags.applicative_functors
  then Lapply(p1, p2)
  else raise (Syntaxerr.Error(Syntaxerr.Applicative_path (symbol_rloc())))

let exp_of_label lbl pos =
  mkexp (Pexp_ident(mkrhs (Lident(Longident.last lbl)) pos))

let pat_of_label lbl pos =
  mkpat (Ppat_var (mkrhs (Longident.last lbl) pos))

let mk_newtypes newtypes exp =
  List.fold_right (fun newtype exp -> mkexp (Pexp_newtype (newtype, exp)))
    newtypes exp

let wrap_type_annotation newtypes core_type body =
  let exp = mkexp(Pexp_constraint(body,core_type)) in
  let exp = mk_newtypes newtypes exp in
  (exp, ghtyp(Ptyp_poly(newtypes, Typ.varify_constructors newtypes core_type)))

let wrap_exp_attrs body (ext, attrs) =
  let body = {body with pexp_attributes = attrs @ body.pexp_attributes} in
  match ext with
  | None -> body
  | Some id -> ghexp(Pexp_extension (id, PStr [mkstrexp body []]))

let mkexp_attrs d attrs =
  wrap_exp_attrs (mkexp d) attrs

let wrap_typ_attrs typ (ext, attrs) =
  let typ = {typ with ptyp_attributes = attrs @ typ.ptyp_attributes} in
  match ext with
  | None -> typ
  | Some id -> ghtyp(Ptyp_extension (id, PTyp typ))

let wrap_pat_attrs pat (ext, attrs) =
  let pat = {pat with ppat_attributes = attrs @ pat.ppat_attributes} in
  match ext with
  | None -> pat
  | Some id -> ghpat(Ppat_extension (id, PPat (pat, None)))

let mkpat_attrs d attrs =
  wrap_pat_attrs (mkpat d) attrs

let wrap_class_attrs body attrs =
  {body with pcl_attributes = attrs @ body.pcl_attributes}
let wrap_class_type_attrs body attrs =
  {body with pcty_attributes = attrs @ body.pcty_attributes}
let wrap_mod_attrs body attrs =
  {body with pmod_attributes = attrs @ body.pmod_attributes}
let wrap_mty_attrs body attrs =
  {body with pmty_attributes = attrs @ body.pmty_attributes}

let wrap_str_ext body ext =
  match ext with
  | None -> body
  | Some id -> ghstr(Pstr_extension ((id, PStr [body]), []))

let mkstr_ext d ext =
  wrap_str_ext (mkstr d) ext

let wrap_sig_ext body ext =
  match ext with
  | None -> body
  | Some id -> ghsig(Psig_extension ((id, PSig [body]), []))

let mksig_ext d ext =
  wrap_sig_ext (mksig d) ext

let text_str pos = Str.text (rhs_text pos)
let text_sig pos = Sig.text (rhs_text pos)
let text_cstr pos = Cf.text (rhs_text pos)
let text_csig pos = Ctf.text (rhs_text pos)
let text_def pos = [Ptop_def (Str.text (rhs_text pos))]

let extra_text text pos items =
  match items with
  | [] ->
      let post = rhs_post_text pos in
      let post_extras = rhs_post_extra_text pos in
      text post @ text post_extras
  | _ :: _ ->
      let pre_extras = rhs_pre_extra_text pos in
      let post_extras = rhs_post_extra_text pos in
        text pre_extras @ items @ text post_extras

let extra_str pos items = extra_text Str.text pos items
let extra_sig pos items = extra_text Sig.text pos items
let extra_cstr pos items = extra_text Cf.text pos items
let extra_csig pos items = extra_text Ctf.text pos items
let extra_def pos items =
  extra_text (fun txt -> [Ptop_def (Str.text txt)]) pos items

let extra_rhs_core_type ct ~pos =
  let docs = rhs_info pos in
  { ct with ptyp_attributes = add_info_attrs docs ct.ptyp_attributes }

type let_binding =
  { lb_pattern: pattern;
    lb_expression: expression;
    lb_attributes: attributes;
    lb_docs: docs Lazy.t;
    lb_text: text Lazy.t;
    lb_loc: Location.t; }

type let_bindings =
  { lbs_bindings: let_binding list;
    lbs_rec: rec_flag;
    lbs_extension: string Asttypes.loc option;
    lbs_loc: Location.t }

let mklb first (p, e) attrs =
  { lb_pattern = p;
    lb_expression = e;
    lb_attributes = attrs;
    lb_docs = symbol_docs_lazy ();
    lb_text = if first then empty_text_lazy
              else symbol_text_lazy ();
    lb_loc = symbol_rloc (); }

let mklbs ext rf lb =
  { lbs_bindings = [lb];
    lbs_rec = rf;
    lbs_extension = ext ;
    lbs_loc = symbol_rloc (); }

let addlb lbs lb =
  { lbs with lbs_bindings = lb :: lbs.lbs_bindings }

let val_of_let_bindings lbs =
  let bindings =
    List.map
      (fun lb ->
         Vb.mk ~loc:lb.lb_loc ~attrs:lb.lb_attributes
           ~docs:(Lazy.force lb.lb_docs)
           ~text:(Lazy.force lb.lb_text)
           lb.lb_pattern lb.lb_expression)
      lbs.lbs_bindings
  in
  let str = mkstr(Pstr_value(lbs.lbs_rec, List.rev bindings)) in
  match lbs.lbs_extension with
  | None -> str
  | Some id -> ghstr (Pstr_extension((id, PStr [str]), []))

let expr_of_let_bindings lbs body =
  let bindings =
    List.map
      (fun lb ->
         Vb.mk ~loc:lb.lb_loc ~attrs:lb.lb_attributes
           lb.lb_pattern lb.lb_expression)
      lbs.lbs_bindings
  in
    mkexp_attrs (Pexp_let(lbs.lbs_rec, List.rev bindings, body))
      (lbs.lbs_extension, [])

let class_of_let_bindings lbs body =
  let bindings =
    List.map
      (fun lb ->
         Vb.mk ~loc:lb.lb_loc ~attrs:lb.lb_attributes
           lb.lb_pattern lb.lb_expression)
      lbs.lbs_bindings
  in
    if lbs.lbs_extension <> None then
      raise Syntaxerr.(Error(Not_expecting(lbs.lbs_loc, "extension")));
    mkclass(Pcl_let (lbs.lbs_rec, List.rev bindings, body))


(* Alternatively, we could keep the generic module type in the Parsetree
   and extract the package type during type-checking. In that case,
   the assertions below should be turned into explicit checks. *)
let package_type_of_module_type pmty =
  let err loc s =
    raise (Syntaxerr.Error (Syntaxerr.Invalid_package_type (loc, s)))
  in
  let map_cstr = function
    | Pwith_type (lid, ptyp) ->
        let loc = ptyp.ptype_loc in
        if ptyp.ptype_params <> [] then
          err loc "parametrized types are not supported";
        if ptyp.ptype_cstrs <> [] then
          err loc "constrained types are not supported";
        if ptyp.ptype_private <> Public then
          err loc "private types are not supported";

        (* restrictions below are checked by the 'with_constraint' rule *)
        assert (ptyp.ptype_kind = Ptype_abstract);
        assert (ptyp.ptype_attributes = []);
        let ty =
          match ptyp.ptype_manifest with
          | Some ty -> ty
          | None -> assert false
        in
        (lid, ty)
    | _ ->
        err pmty.pmty_loc "only 'with type t =' constraints are supported"
  in
  match pmty with
  | {pmty_desc = Pmty_ident lid} -> (lid, [])
  | {pmty_desc = Pmty_with({pmty_desc = Pmty_ident lid}, cstrs)} ->
      (lid, List.map map_cstr cstrs)
  | _ ->
      err pmty.pmty_loc
        "only module type identifier and 'with type' constraints are supported"

let mk_directive_arg k =
  { pdira_desc = k;
    pdira_loc = symbol_rloc ()
  }

let mk_directive name arg =
  Ptop_dir {
      pdir_name = name;
      pdir_arg = arg;
      pdir_loc = symbol_rloc ()
    }

(* these '_'-prefixed, currified versions form a
   compatibility layer with the Menhir grammar port
   which uses  cpp macros for location handling. *)
let _symbol_rloc() = symbol_rloc ()
let _symbol_docs() = symbol_docs ()
let _symbol_info() = symbol_info ()
let _symbol_text() = symbol_text ()
let _symbol_text_lazy() = symbol_text_lazy ()
let _rhs_loc(p) = rhs_loc p
let _rhs_interval(p1, p2) = rhs_interval p1 p2
let _rhs_info(p) = rhs_info p
let _rhs_text(p) = rhs_text p
let _rhs_text_lazy(p) = rhs_text_lazy(p)
let _symbol_pre_extra_text() = symbol_pre_extra_text ()
let _rhs_pre_extra_text(p) = rhs_pre_extra_text (p)
let _rhs_post_extra_text(p) = rhs_post_extra_text (p)

let _extra_rhs_core_type (a, p) = extra_rhs_core_type a ~pos:p

let _mark_symbol_docs() = mark_symbol_docs ()
let _mark_rhs_docs(a, b) = mark_rhs_docs a b

let _mkrhs(a, p) = mkrhs a p
let _mkrhs2(a, p1, p2) = mkrhs2 a p1 p2

let _mktyp = mktyp
let _mkpat = mkpat
let _mkexp = mkexp
let _mkmty = mkmty
let _mksig = mksig
let _mkmod = mkmod
let _mkstr = mkstr
let _mkcty = mkcty
let _mkctf = mkctf
let _mkcf = mkcf
let _mklb = mklb
let _mklbs = mklbs
let _mkclass = mkclass

let _mkexp_attrs = mkexp_attrs
let _mkpat_attrs = mkpat_attrs
let _mkexp_constraint = mkexp_constraint
let _mkoperator(s, p) = mkoperator s p
let _mkuplus = mkuplus
let _mkuminus = mkuminus
let _mkinfix = mkinfix

let _array_function = array_function
let _bigarray_function = bigarray_function
let _bigarray_get = bigarray_get
let _bigarray_set = bigarray_set

let _ghexp = ghexp
let _ghpat = ghpat
let _ghtyp = ghtyp
let _ghloc = ghloc
let _ghstr = ghstr

let _mk_newtypes = mk_newtypes
let _val_of_let_bindings = val_of_let_bindings
let _expr_of_let_bindings = expr_of_let_bindings
let _class_of_let_bindings = class_of_let_bindings

let _reloc_typ = reloc_typ
let _reloc_exp = reloc_exp
let _reloc_pat = reloc_pat

let _wrap_exp_attrs = wrap_exp_attrs
let _wrap_typ_attrs = wrap_typ_attrs
let _wrap_mod_attrs = wrap_mod_attrs
let _wrap_mty_attrs = wrap_mty_attrs
let _wrap_class_attrs = wrap_class_attrs
let _wrap_class_type_attrs = wrap_class_type_attrs
let _wrap_type_annotation = wrap_type_annotation

let _mkstr_ext = mkstr_ext
let _wrap_str_ext = wrap_str_ext
let _mksig_ext = mksig_ext
let _wrap_sig_ext = wrap_sig_ext

let _mkpatvar(s, p) = mkpatvar s p
let _pat_of_label(s, p) = pat_of_label s p
let _exp_of_label(s, p) = exp_of_label s p

let _mkpat_opt_constraint = mkpat_opt_constraint
let _mkexp_opt_constraint = mkexp_opt_constraint

let _mk_directive_arg = mk_directive_arg
let _mk_directive = mk_directive

let _unclosed(s1, p1, s2, p2) = unclosed s1 p1 s2 p2
let _expecting(p, s) = expecting p s
let _not_expecting(p, s) = not_expecting p s

let _text_str(p) = text_str p
let _text_sig(p) = text_sig p
let _text_cstr(p) = text_cstr p
let _text_csig(p) = text_csig p
let _text_def(p) = text_def p

let _extra_text(p) = extra_text p
let _extra_str(p) = extra_str p
let _extra_sig(p) = extra_sig p
let _extra_cstr(p) = extra_cstr p
let _extra_csig(p) = extra_csig p
let _extra_def(p) = extra_def p

%}

/* Tokens */

%token AMPERAMPER
%token AMPERSAND
%token AND
%token AS
%token ASSERT
%token BACKQUOTE
%token BANG
%token BAR
%token BARBAR
%token BARRBRACKET
%token BEGIN
%token <char> CHAR
%token CLASS
%token COLON
%token COLONCOLON
%token COLONEQUAL
%token COLONGREATER
%token COMMA
%token CONSTRAINT
%token DO
%token DONE
%token DOT
%token DOTDOT
%token DOWNTO
%token ELSE
%token END
%token EOF
%token EQUAL
%token EXCEPTION
%token EXTERNAL
%token FALSE
%token <string * char option> FLOAT
%token FOR
%token FUN
%token FUNCTION
%token FUNCTOR
%token GREATER
%token GREATERRBRACE
%token GREATERRBRACKET
%token IF
%token IN
%token INCLUDE
%token <string> INFIXOP0
%token <string> INFIXOP1
%token <string> INFIXOP2
%token <string> INFIXOP3
%token <string> INFIXOP4
%token <string> DOTOP
%token INHERIT
%token INITIALIZER
%token <string * char option> INT
%token <string> LABEL
%token LAZY
%token LBRACE
%token LBRACELESS
%token LBRACKET
%token LBRACKETBAR
%token LBRACKETLESS
%token LBRACKETGREATER
%token LBRACKETPERCENT
%token LBRACKETPERCENTPERCENT
%token LESS
%token LESSMINUS
%token LET
%token <string> LIDENT
%token LPAREN
%token LBRACKETAT
%token LBRACKETATAT
%token LBRACKETATATAT
%token MATCH
%token METHOD
%token MINUS
%token MINUSDOT
%token MINUSGREATER
%token MODULE
%token MUTABLE
%token NEW
%token NONREC
%token OBJECT
%token OF
%token OPEN
%token <string> OPTLABEL
%token OR
/* %token PARSER */
%token PERCENT
%token PLUS
%token PLUSDOT
%token PLUSEQ
%token <string> PREFIXOP
%token PRIVATE
%token QUESTION
%token QUOTE
%token RBRACE
%token RBRACKET
%token REC
%token RPAREN
%token SEMI
%token SEMISEMI
%token HASH
%token <string> HASHOP
%token SIG
%token STAR
%token <string * string option> STRING
%token STRUCT
%token THEN
%token TILDE
%token TO
%token TRUE
%token TRY
%token TYPE
%token <string> UIDENT
%token UNDERSCORE
%token VAL
%token VIRTUAL
%token WHEN
%token WHILE
%token WITH
%token <string * Location.t> COMMENT
%token <Docstrings.docstring> DOCSTRING

%token EOL

/* Precedences and associativities.

Tokens and rules have precedences.  A reduce/reduce conflict is resolved
in favor of the first rule (in source file order).  A shift/reduce conflict
is resolved by comparing the precedence and associativity of the token to
be shifted with those of the rule to be reduced.

By default, a rule has the precedence of its rightmost terminal (if any).

When there is a shift/reduce conflict between a rule and a token that
have the same precedence, it is resolved using the associativity:
if the token is left-associative, the parser will reduce; if
right-associative, the parser will shift; if non-associative,
the parser will declare a syntax error.

We will only use associativities with operators of the kind  x * x -> x
for example, in the rules of the form    expr: expr BINOP expr
in all other cases, we define two precedences if needed to resolve
conflicts.

The precedences must be listed from low to high.
*/

%nonassoc IN
%nonassoc below_SEMI
%nonassoc SEMI                          /* below EQUAL ({lbl=...; lbl=...}) */
%nonassoc LET                           /* above SEMI ( ...; let ... in ...) */
%nonassoc below_WITH
%nonassoc FUNCTION WITH                 /* below BAR  (match ... with ...) */
%nonassoc AND             /* above WITH (module rec A: SIG with ... and ...) */
%nonassoc THEN                          /* below ELSE (if ... then ...) */
%nonassoc ELSE                          /* (if ... then ... else ...) */
%nonassoc LESSMINUS                     /* below COLONEQUAL (lbl <- x := e) */
%right    COLONEQUAL                    /* expr (e := e := e) */
%nonassoc AS
%left     BAR                           /* pattern (p|p|p) */
%nonassoc below_COMMA
%left     COMMA                         /* expr/expr_comma_list (e,e,e) */
%right    MINUSGREATER                  /* core_type2 (t -> t -> t) */
%right    OR BARBAR                     /* expr (e || e || e) */
%right    AMPERSAND AMPERAMPER          /* expr (e && e && e) */
%nonassoc below_EQUAL
%left     INFIXOP0 EQUAL LESS GREATER   /* expr (e OP e OP e) */
%right    INFIXOP1                      /* expr (e OP e OP e) */
%nonassoc below_LBRACKETAT
%nonassoc LBRACKETAT
%nonassoc LBRACKETATAT
%right    COLONCOLON                    /* expr (e :: e :: e) */
%left     INFIXOP2 PLUS PLUSDOT MINUS MINUSDOT PLUSEQ /* expr (e OP e OP e) */
%left     PERCENT INFIXOP3 STAR                 /* expr (e OP e OP e) */
%right    INFIXOP4                      /* expr (e OP e OP e) */
%nonassoc prec_unary_minus prec_unary_plus /* unary - */
%nonassoc prec_constant_constructor     /* cf. simple_expr (C versus C x) */
%nonassoc prec_constr_appl              /* above AS BAR COLONCOLON COMMA */
%nonassoc below_HASH
%nonassoc HASH                         /* simple_expr/toplevel_directive */
%left     HASHOP
%nonassoc below_DOT
%nonassoc DOT DOTOP
/* Finally, the first tokens of simple_expr are above everything else. */
%nonassoc BACKQUOTE BANG BEGIN CHAR FALSE FLOAT INT
          LBRACE LBRACELESS LBRACKET LBRACKETBAR LIDENT LPAREN
          NEW PREFIXOP STRING TRUE UIDENT
          LBRACKETPERCENT LBRACKETPERCENTPERCENT


/* Entry points */

%start implementation                   /* for implementation files */
%type <Parsetree.structure> implementation
%start interface                        /* for interface files */
%type <Parsetree.signature> interface
%start toplevel_phrase                  /* for interactive use */
%type <Parsetree.toplevel_phrase> toplevel_phrase
%start use_file                         /* for the #use directive */
%type <Parsetree.toplevel_phrase list> use_file
%start parse_core_type
%type <Parsetree.core_type> parse_core_type
%start parse_expression
%type <Parsetree.expression> parse_expression
%start parse_pattern
%type <Parsetree.pattern> parse_pattern
%%

/* Entry points */

implementation:
    structure EOF                        { _extra_str(1) $1 }
;
interface:
    signature EOF                        { _extra_sig(1) $1 }
;
toplevel_phrase:
    top_structure SEMISEMI               { Ptop_def (_extra_str(1) $1) }
  | toplevel_directive SEMISEMI          { $1 }
  | EOF                                  { raise End_of_file }
;
top_structure:
    seq_expr post_item_attributes
      { _text_str(1) @ [mkstrexp $1 $2] }
  | top_structure_tail
      { $1 }
;
top_structure_tail:
    /* empty */                          { [] }
  | structure_item top_structure_tail    { _text_str(1) @ $1 :: $2 }
;
use_file:
    use_file_body EOF                    { _extra_def(1) $1 }
;
use_file_body:
    use_file_tail                        { $1 }
  | seq_expr post_item_attributes use_file_tail
      { _text_def(1) @ Ptop_def[mkstrexp $1 $2] :: $3 }
;
use_file_tail:
    /* empty */
      { [] }
  | SEMISEMI use_file_body
      { $2 }
  | structure_item use_file_tail
      { _text_def(1) @ Ptop_def[$1] :: $2 }
  | toplevel_directive use_file_tail
      { _mark_rhs_docs(1, 1);
        _text_def(1) @ $1 :: $2 }
;
parse_core_type:
    core_type EOF { $1 }
;
parse_expression:
    seq_expr EOF { $1 }
;
parse_pattern:
    pattern EOF { $1 }
;

/* Module expressions */

functor_arg:
    LPAREN RPAREN
      { _mkrhs2("*", 1, 2), None }
  | LPAREN functor_arg_name COLON module_type RPAREN
      { _mkrhs($2, 2), Some $4 }
;

functor_arg_name:
    UIDENT     { $1 }
  | UNDERSCORE { "_" }
;

functor_args:
    functor_args functor_arg
      { $2 :: $1 }
  | functor_arg
      { [ $1 ] }
;

module_expr:
    mod_longident
      { _mkmod(Pmod_ident (_mkrhs($1, 1))) }
  | STRUCT attributes structure END
      { _mkmod ~attrs:$2 (Pmod_structure(_extra_str(3) $3)) }
  | STRUCT attributes structure error
      { _unclosed("struct", 1, "end", 4) }
  | FUNCTOR attributes functor_args MINUSGREATER module_expr
      { let modexp =
          List.fold_left
            (fun acc (n, t) -> _mkmod(Pmod_functor(n, t, acc)))
            $5 $3
        in _wrap_mod_attrs modexp $2 }
  | module_expr paren_module_expr
      { _mkmod(Pmod_apply($1, $2)) }
  | module_expr LPAREN RPAREN
      { _mkmod(Pmod_apply($1, _mkmod(Pmod_structure []))) }
  | paren_module_expr
      { $1 }
  | module_expr attribute
      { Mod.attr $1 $2 }
  | extension
      { _mkmod(Pmod_extension $1) }
;

paren_module_expr:
    LPAREN module_expr COLON module_type RPAREN
      { _mkmod(Pmod_constraint($2, $4)) }
  | LPAREN module_expr COLON module_type error
      { _unclosed("(", 1, ")", 5) }
  | LPAREN module_expr RPAREN
      { $2 }
  | LPAREN module_expr error
      { _unclosed("(", 1, ")", 3) }
  | LPAREN VAL attributes expr RPAREN
      { _mkmod ~attrs:$3 (Pmod_unpack $4)}
  | LPAREN VAL attributes expr COLON package_type RPAREN
      { let constr_loc = _rhs_interval(4, 6) in
        _mkmod ~attrs:$3
          (Pmod_unpack(
               ghexp ~loc:constr_loc (Pexp_constraint($4, $6)))) }
  | LPAREN VAL attributes expr COLON package_type COLONGREATER package_type
    RPAREN
      { let constr_loc = _rhs_interval(4, 8) in
        _mkmod ~attrs:$3
          (Pmod_unpack(
               ghexp ~loc:constr_loc (Pexp_coerce($4, Some $6, $8)))) }
  | LPAREN VAL attributes expr COLONGREATER package_type RPAREN
      { let constr_loc = _rhs_interval(4, 6) in
        _mkmod ~attrs:$3
          (Pmod_unpack(
               ghexp ~loc:constr_loc (Pexp_coerce($4, None, $6)))) }
  | LPAREN VAL attributes expr COLON error
      { _unclosed("(", 1, ")", 6) }
  | LPAREN VAL attributes expr COLONGREATER error
      { _unclosed("(", 1, ")", 6) }
  | LPAREN VAL attributes expr error
      { _unclosed("(", 1, ")", 5) }
;

structure:
    seq_expr post_item_attributes structure_tail
      { _mark_rhs_docs(1, 2);
        _text_str(1) @ mkstrexp $1 $2 :: $3 }
  | structure_tail { $1 }
;
structure_tail:
    /* empty */          { [] }
  | SEMISEMI structure   { _text_str(1) @ $2 }
  | structure_item structure_tail { _text_str(1) @ $1 :: $2 }
;
structure_item:
    let_bindings
      { _val_of_let_bindings $1 }
  | primitive_declaration
      { let (body, ext) = $1 in _mkstr_ext (Pstr_primitive body) ext }
  | value_description
      { let (body, ext) = $1 in _mkstr_ext (Pstr_primitive body) ext }
  | type_declarations
      { let (nr, l, ext ) = $1 in _mkstr_ext (Pstr_type (nr, List.rev l)) ext }
  | str_type_extension
      { let (l, ext) = $1 in _mkstr_ext (Pstr_typext l) ext }
  | str_exception_declaration
      { let (l, ext) = $1 in _mkstr_ext (Pstr_exception l) ext }
  | module_binding
      { let (body, ext) = $1 in _mkstr_ext (Pstr_module body) ext }
  | rec_module_bindings
      { let (l, ext) = $1 in _mkstr_ext (Pstr_recmodule(List.rev l)) ext }
  | module_type_declaration
      { let (body, ext) = $1 in _mkstr_ext (Pstr_modtype body) ext }
  | open_statement
      { let (body, ext) = $1 in _mkstr_ext (Pstr_open body) ext }
  | class_declarations
      { let (l, ext) = $1 in _mkstr_ext (Pstr_class (List.rev l)) ext }
  | class_type_declarations
      { let (l, ext) = $1 in _mkstr_ext (Pstr_class_type (List.rev l)) ext }
  | str_include_statement
      { let (body, ext) = $1 in _mkstr_ext (Pstr_include body) ext }
  | item_extension post_item_attributes
      { _mkstr(Pstr_extension ($1, (add_docs_attrs (_symbol_docs()) $2))) }
  | floating_attribute
      { _mkstr(Pstr_attribute $1) }
;
str_include_statement:
    INCLUDE ext_attributes module_expr post_item_attributes
      { let (ext, attrs) = $2 in
        Incl.mk $3 ~attrs:(attrs@$4)
            ~loc:(_symbol_rloc()) ~docs:(_symbol_docs())
      , ext }
;
module_binding_body:
    EQUAL module_expr
      { $2 }
  | COLON module_type EQUAL module_expr
      { _mkmod(Pmod_constraint($4, $2)) }
  | functor_arg module_binding_body
      { _mkmod(Pmod_functor(fst $1, snd $1, $2)) }
;
module_binding:
    MODULE ext_attributes UIDENT module_binding_body post_item_attributes
      { let (ext, attrs) = $2 in
        Mb.mk (_mkrhs($3, 3)) $4 ~attrs:(attrs@$5)
            ~loc:(_symbol_rloc()) ~docs:(_symbol_docs())
      , ext }
;
rec_module_bindings:
    rec_module_binding                     { let (b, ext) = $1 in ([b], ext) }
  | rec_module_bindings and_module_binding
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
rec_module_binding:
    MODULE ext_attributes REC UIDENT module_binding_body post_item_attributes
      { let (ext, attrs) = $2 in
        Mb.mk (_mkrhs($4, 4)) $5 ~attrs:(attrs@$6)
            ~loc:(_symbol_rloc()) ~docs:(_symbol_docs())
      , ext }
;
and_module_binding:
    AND attributes UIDENT module_binding_body post_item_attributes
      { Mb.mk (_mkrhs($3, 3)) $4 ~attrs:($2@$5) ~loc:(_symbol_rloc())
               ~text:(_symbol_text()) ~docs:(_symbol_docs()) }
;

/* Module types */

module_type:
    mty_longident
      { _mkmty(Pmty_ident (_mkrhs($1, 1))) }
  | SIG attributes signature END
      { _mkmty ~attrs:$2 (Pmty_signature (_extra_sig(3) $3)) }
  | SIG attributes signature error
      { _unclosed("sig", 1, "end", 4) }
  | FUNCTOR attributes functor_args MINUSGREATER module_type
      %prec below_WITH
      { let mty =
          List.fold_left
            (fun acc (n, t) -> _mkmty(Pmty_functor(n, t, acc)))
            $5 $3
        in _wrap_mty_attrs mty $2 }
  | module_type MINUSGREATER module_type
      %prec below_WITH
      { _mkmty(Pmty_functor(mknoloc "_", Some $1, $3)) }
  | module_type WITH with_constraints
      { _mkmty(Pmty_with($1, List.rev $3)) }
  | MODULE TYPE OF attributes module_expr %prec below_LBRACKETAT
      { _mkmty ~attrs:$4 (Pmty_typeof $5) }
/*  | LPAREN MODULE mod_longident RPAREN
      { _mkmty (Pmty_alias (_mkrhs($3, 3))) } */
  | LPAREN module_type RPAREN
      { $2 }
  | LPAREN module_type error
      { _unclosed("(", 1, ")", 3) }
  | extension
      { _mkmty(Pmty_extension $1) }
  | module_type attribute
      { Mty.attr $1 $2 }
;
signature:
    /* empty */          { [] }
  | SEMISEMI signature   { _text_sig(1) @ $2 }
  | signature_item signature { _text_sig(1) @ $1 :: $2 }
;
signature_item:
    value_description
      { let (body, ext) = $1 in _mksig_ext (Psig_value body) ext }
  | primitive_declaration
      { let (body, ext) = $1 in _mksig_ext (Psig_value body) ext}
  | type_declarations
      { let (nr, l, ext) = $1 in _mksig_ext (Psig_type (nr, List.rev l)) ext }
  | sig_type_extension
      { let (l, ext) = $1 in _mksig_ext (Psig_typext l) ext }
  | sig_exception_declaration
      { let (l, ext) = $1 in _mksig_ext (Psig_exception l) ext }
  | module_declaration
      { let (body, ext) = $1 in _mksig_ext (Psig_module body) ext }
  | module_alias
      { let (body, ext) = $1 in _mksig_ext (Psig_module body) ext }
  | rec_module_declarations
      { let (l, ext) = $1 in _mksig_ext (Psig_recmodule (List.rev l)) ext }
  | module_type_declaration
      { let (body, ext) = $1 in _mksig_ext (Psig_modtype body) ext }
  | open_statement
      { let (body, ext) = $1 in _mksig_ext (Psig_open body) ext }
  | sig_include_statement
      { let (body, ext) = $1 in _mksig_ext (Psig_include body) ext }
  | class_descriptions
      { let (l, ext) = $1 in _mksig_ext (Psig_class (List.rev l)) ext }
  | class_type_declarations
      { let (l, ext) = $1 in _mksig_ext (Psig_class_type (List.rev l)) ext }
  | item_extension post_item_attributes
      { _mksig(Psig_extension ($1, (add_docs_attrs (_symbol_docs ()) $2))) }
  | floating_attribute
      { _mksig(Psig_attribute $1) }
;
open_statement:
  | OPEN override_flag ext_attributes mod_longident post_item_attributes
      { let (ext, attrs) = $3 in
        Opn.mk (_mkrhs($4, 4)) ~override:$2 ~attrs:(attrs@$5)
          ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ())
      , ext}
;
sig_include_statement:
    INCLUDE ext_attributes module_type post_item_attributes %prec below_WITH
      { let (ext, attrs) = $2 in
        Incl.mk $3 ~attrs:(attrs@$4)
            ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ())
      , ext}
;
module_declaration_body:
    COLON module_type
      { $2 }
  | functor_arg module_declaration_body
      { let (name,typ) = $1 in
        _mkmty(Pmty_functor(name, typ, $2)) }
;
module_declaration:
    MODULE ext_attributes UIDENT module_declaration_body post_item_attributes
      { let (ext, attrs) = $2 in
        Md.mk (_mkrhs($3, 3)) $4 ~attrs:(attrs@$5)
          ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ())
      , ext }
;
module_alias:
    MODULE ext_attributes UIDENT EQUAL mod_longident post_item_attributes
      { let (ext, attrs) = $2 in
        Md.mk (_mkrhs($3, 3))
          (Mty.alias ~loc:(_rhs_loc(5)) (_mkrhs($5, 5))) ~attrs:(attrs@$6)
             ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ())
      , ext }
;
rec_module_declarations:
    rec_module_declaration
      { let (body, ext) = $1 in ([body], ext) }
  | rec_module_declarations and_module_declaration
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
rec_module_declaration:
    MODULE ext_attributes REC UIDENT COLON module_type post_item_attributes
      { let (ext, attrs) = $2 in
        Md.mk (_mkrhs($4, 4)) $6 ~attrs:(attrs@$7)
            ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ())
      , ext}
;
and_module_declaration:
    AND attributes UIDENT COLON module_type post_item_attributes
      { Md.mk (_mkrhs($3, 3)) $5 ~attrs:($2@$6) ~loc:(_symbol_rloc())
              ~text:(_symbol_text()) ~docs:(_symbol_docs()) }
;
module_type_declaration_body:
    /* empty */               { None }
  | EQUAL module_type         { Some $2 }
;
module_type_declaration:
    MODULE TYPE ext_attributes ident module_type_declaration_body
    post_item_attributes
      { let (ext, attrs) = $3 in
        Mtd.mk (_mkrhs($4, 4)) ?typ:$5 ~attrs:(attrs@$6)
          ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ())
      , ext }
;
/* Class expressions */

class_declarations:
    class_declaration
      { let (body, ext) = $1 in ([body], ext) }
  | class_declarations and_class_declaration
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
class_declaration:
    CLASS ext_attributes virtual_flag class_type_parameters LIDENT
    class_fun_binding post_item_attributes
      { let (ext, attrs) = $2 in
        Ci.mk (_mkrhs($5, 5)) $6 ~virt:$3 ~params:$4 ~attrs:(attrs@$7)
            ~loc:(_symbol_rloc ()) ~docs:(_symbol_docs ())
      , ext }
;
and_class_declaration:
    AND attributes virtual_flag class_type_parameters LIDENT class_fun_binding
    post_item_attributes
      { Ci.mk (_mkrhs($5, 5)) $6 ~virt:$3 ~params:$4
         ~attrs:($2@$7) ~loc:(_symbol_rloc ())
         ~text:(_symbol_text ()) ~docs:(_symbol_docs ()) }
;
class_fun_binding:
    EQUAL class_expr
      { $2 }
  | COLON class_type EQUAL class_expr
      { _mkclass(Pcl_constraint($4, $2)) }
  | labeled_simple_pattern class_fun_binding
      { let (l,o,p) = $1 in _mkclass(Pcl_fun(l, o, p, $2)) }
;
class_type_parameters:
    /*empty*/                                   { [] }
  | LBRACKET type_parameter_list RBRACKET       { List.rev $2 }
;
class_fun_def:
    labeled_simple_pattern MINUSGREATER class_expr
      { let (l,o,p) = $1 in _mkclass(Pcl_fun(l, o, p, $3)) }
  | labeled_simple_pattern class_fun_def
      { let (l,o,p) = $1 in _mkclass(Pcl_fun(l, o, p, $2)) }
;
class_expr:
    class_simple_expr
      { $1 }
  | FUN attributes class_fun_def
      { _wrap_class_attrs $3 $2 }
  | class_simple_expr simple_labeled_expr_list
      { _mkclass(Pcl_apply($1, List.rev $2)) }
  | let_bindings IN class_expr
      { _class_of_let_bindings $1 $3 }
  | LET OPEN override_flag attributes mod_longident IN class_expr
      { _wrap_class_attrs (_mkclass(Pcl_open($3, _mkrhs($5, 5), $7))) $4 }
  | class_expr attribute
      { Cl.attr $1 $2 }
  | extension
      { _mkclass(Pcl_extension $1) }
;
class_simple_expr:
    LBRACKET core_type_comma_list RBRACKET class_longident
      { _mkclass(Pcl_constr(_mkrhs($4, 4), List.rev $2)) }
  | class_longident
      { _mkclass(Pcl_constr(_mkrhs($1, 1), [])) }
  | OBJECT attributes class_structure END
      { _mkclass ~attrs:$2 (Pcl_structure $3) }
  | OBJECT attributes class_structure error
      { _unclosed("object", 1, "end", 4) }
  | LPAREN class_expr COLON class_type RPAREN
      { _mkclass(Pcl_constraint($2, $4)) }
  | LPAREN class_expr COLON class_type error
      { _unclosed("(", 1, ")", 5) }
  | LPAREN class_expr RPAREN
      { $2 }
  | LPAREN class_expr error
      { _unclosed("(", 1, ")", 3) }
;
class_structure:
  |  class_self_pattern class_fields
       { Cstr.mk $1 (_extra_cstr(2) (List.rev $2)) }
;
class_self_pattern:
    LPAREN pattern RPAREN
      { _reloc_pat $2 }
  | LPAREN pattern COLON core_type RPAREN
      { _mkpat(Ppat_constraint($2, $4)) }
  | /* empty */
      { _ghpat(Ppat_any) }
;
class_fields:
    /* empty */
      { [] }
  | class_fields class_field
      { $2 :: (List.rev (_text_cstr(2))) @ $1 }
;
class_field:
  | INHERIT override_flag attributes class_expr parent_binder
    post_item_attributes
      { _mkcf (Pcf_inherit ($2, $4, $5)) ~attrs:($3@$6) ~docs:(_symbol_docs ()) }
  | VAL value post_item_attributes
      { let v, attrs = $2 in
        _mkcf (Pcf_val v) ~attrs:(attrs@$3) ~docs:(_symbol_docs ()) }
  | METHOD method_ post_item_attributes
      { let meth, attrs = $2 in
        _mkcf (Pcf_method meth) ~attrs:(attrs@$3) ~docs:(_symbol_docs ()) }
  | CONSTRAINT attributes constrain_field post_item_attributes
      { _mkcf (Pcf_constraint $3) ~attrs:($2@$4) ~docs:(_symbol_docs ()) }
  | INITIALIZER attributes seq_expr post_item_attributes
      { _mkcf (Pcf_initializer $3) ~attrs:($2@$4) ~docs:(_symbol_docs ()) }
  | item_extension post_item_attributes
      { _mkcf (Pcf_extension $1) ~attrs:$2 ~docs:(_symbol_docs ()) }
  | floating_attribute
      { _mkcf (Pcf_attribute $1) }
;
parent_binder:
    AS LIDENT
          { Some (_mkrhs($2, 2)) }
  | /* empty */
          { None }
;
value:
/* TODO: factorize these rules (also with method): */
    override_flag attributes MUTABLE VIRTUAL label COLON core_type
      { if $1 = Override then syntax_error ();
        (_mkrhs($5, 5), Mutable, Cfk_virtual $7), $2 }
  | override_flag attributes VIRTUAL mutable_flag label COLON core_type
      { if $1 = Override then syntax_error ();
        (_mkrhs($5, 5), $4, Cfk_virtual $7), $2 }
  | override_flag attributes mutable_flag label EQUAL seq_expr
      { (_mkrhs($4, 4), $3, Cfk_concrete ($1, $6)), $2 }
  | override_flag attributes mutable_flag label type_constraint EQUAL seq_expr
      {
       let e = _mkexp_constraint $7 $5 in
       (_mkrhs($4, 4), $3, Cfk_concrete ($1, e)), $2
      }
;
method_:
/* TODO: factorize those rules... */
    override_flag attributes PRIVATE VIRTUAL label COLON poly_type
      { if $1 = Override then syntax_error ();
        (_mkrhs($5, 5), Private, Cfk_virtual $7), $2 }
  | override_flag attributes VIRTUAL private_flag label COLON poly_type
      { if $1 = Override then syntax_error ();
        (_mkrhs($5, 5), $4, Cfk_virtual $7), $2 }
  | override_flag attributes private_flag label strict_binding
      { let e = $5 in
        (_mkrhs($4, 4), $3,
        Cfk_concrete ($1, ghexp ~loc:e.pexp_loc (Pexp_poly (e, None)))), $2 }
  | override_flag attributes private_flag label COLON poly_type EQUAL seq_expr
      { let loc = _rhs_interval(6, 8) in
        (_mkrhs($4, 4), $3,
        Cfk_concrete ($1, ghexp ~loc (Pexp_poly($8, Some $6)))), $2 }
  | override_flag attributes private_flag label COLON TYPE lident_list
    DOT core_type EQUAL seq_expr
      { let exp, poly = _wrap_type_annotation $7 $9 $11 in
        let loc = _rhs_interval(7, 11) in
        (_mkrhs($4, 4), $3,
        Cfk_concrete ($1, ghexp ~loc (Pexp_poly(exp, Some poly)))), $2 }
;

/* Class types */

class_type:
    class_signature
      { $1 }
  | QUESTION LIDENT COLON simple_core_type_or_tuple MINUSGREATER
    class_type
      { _mkcty(Pcty_arrow(Optional $2 , $4, $6)) }
  | OPTLABEL simple_core_type_or_tuple MINUSGREATER class_type
      { _mkcty(Pcty_arrow(Optional $1, $2, $4)) }
  | LIDENT COLON simple_core_type_or_tuple MINUSGREATER class_type
      { _mkcty(Pcty_arrow(Labelled $1, $3, $5)) }
  | simple_core_type_or_tuple MINUSGREATER class_type
      { _mkcty(Pcty_arrow(Nolabel, $1, $3)) }
 ;
class_signature:
    LBRACKET core_type_comma_list RBRACKET clty_longident
      { _mkcty(Pcty_constr (_mkrhs($4, 4), List.rev $2)) }
  | clty_longident
      { _mkcty(Pcty_constr (_mkrhs($1, 1), [])) }
  | OBJECT attributes class_sig_body END
      { _mkcty ~attrs:$2 (Pcty_signature $3) }
  | OBJECT attributes class_sig_body error
      { _unclosed("object", 1, "end", 4) }
  | class_signature attribute
      { Cty.attr $1 $2 }
  | extension
      { _mkcty(Pcty_extension $1) }
  | LET OPEN override_flag attributes mod_longident IN class_signature
      { _wrap_class_type_attrs (_mkcty(Pcty_open($3, _mkrhs($5, 5), $7))) $4 }
;
class_sig_body:
    class_self_type class_sig_fields
      { Csig.mk $1 (_extra_csig(2) (List.rev $2)) }
;
class_self_type:
    LPAREN core_type RPAREN
      { $2 }
  | /* empty */
      { _mktyp(Ptyp_any) }
;
class_sig_fields:
    /* empty */                     { [] }
| class_sig_fields class_sig_field  { $2 :: (List.rev (_text_csig(2))) @ $1 }
;
class_sig_field:
    INHERIT attributes class_signature post_item_attributes
      { _mkctf (Pctf_inherit $3) ~attrs:($2@$4) ~docs:(_symbol_docs ()) }
  | VAL attributes value_type post_item_attributes
      { _mkctf (Pctf_val $3) ~attrs:($2@$4) ~docs:(_symbol_docs ()) }
  | METHOD attributes private_virtual_flags label COLON poly_type
    post_item_attributes
      {
       let (p, v) = $3 in
       _mkctf (Pctf_method (_mkrhs($4, 4), p, v, $6))
             ~attrs:($2@$7) ~docs:(_symbol_docs ())
      }
  | CONSTRAINT attributes constrain_field post_item_attributes
      { _mkctf (Pctf_constraint $3) ~attrs:($2@$4) ~docs:(_symbol_docs ()) }
  | item_extension post_item_attributes
      { _mkctf (Pctf_extension $1) ~attrs:$2 ~docs:(_symbol_docs ()) }
  | floating_attribute
      { _mkctf(Pctf_attribute $1) }
;
value_type:
    VIRTUAL mutable_flag label COLON core_type
      { _mkrhs($3, 3), $2, Virtual, $5 }
  | MUTABLE virtual_flag label COLON core_type
      { _mkrhs($3, 3), Mutable, $2, $5 }
  | label COLON core_type
      { _mkrhs($1, 1), Immutable, Concrete, $3 }
;
constrain:
        core_type EQUAL core_type          { $1, $3, _symbol_rloc() }
;
constrain_field:
        core_type EQUAL core_type          { $1, $3 }
;
class_descriptions:
    class_description
      { let (body, ext) = $1 in ([body],ext) }
  | class_descriptions and_class_description
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
class_description:
    CLASS ext_attributes virtual_flag class_type_parameters LIDENT COLON
    class_type post_item_attributes
      { let (ext, attrs) = $2 in
        Ci.mk (_mkrhs($5, 5)) $7 ~virt:$3 ~params:$4 ~attrs:(attrs @ $8)
            ~loc:(_symbol_rloc ()) ~docs:(_symbol_docs ())
      , ext }
;
and_class_description:
    AND attributes virtual_flag class_type_parameters LIDENT COLON class_type
    post_item_attributes
      { Ci.mk (_mkrhs($5, 5)) $7 ~virt:$3 ~params:$4
              ~attrs:($2@$8) ~loc:(_symbol_rloc ())
              ~text:(_symbol_text ()) ~docs:(_symbol_docs ()) }
;
class_type_declarations:
    class_type_declaration
      { let (body, ext) = $1 in ([body],ext) }
  | class_type_declarations and_class_type_declaration
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
class_type_declaration:
    CLASS TYPE ext_attributes virtual_flag class_type_parameters LIDENT EQUAL
    class_signature post_item_attributes
      { let (ext, attrs) = $3 in
        Ci.mk (_mkrhs($6, 6)) $8 ~virt:$4 ~params:$5 ~attrs:(attrs@$9)
            ~loc:(_symbol_rloc ()) ~docs:(_symbol_docs ())
      , ext}
;
and_class_type_declaration:
    AND attributes virtual_flag class_type_parameters LIDENT EQUAL
    class_signature post_item_attributes
      { Ci.mk (_mkrhs($5, 5)) $7 ~virt:$3 ~params:$4
         ~attrs:($2@$8) ~loc:(_symbol_rloc ())
         ~text:(_symbol_text ()) ~docs:(_symbol_docs ()) }
;

/* Core expressions */

seq_expr:
  | expr        %prec below_SEMI  { $1 }
  | expr SEMI                     { $1 }
  | expr SEMI seq_expr            { _mkexp(Pexp_sequence($1, $3)) }
  | expr SEMI PERCENT attr_id seq_expr
      { let seq = _mkexp(Pexp_sequence ($1, $5)) in
        let payload = PStr [mkstrexp seq []] in
        _mkexp (Pexp_extension ($4, payload)) }
;
labeled_simple_pattern:
    QUESTION LPAREN label_let_pattern opt_default RPAREN
      { (Optional (fst $3), $4, snd $3) }
  | QUESTION label_var
      { (Optional (fst $2), None, snd $2) }
  | OPTLABEL LPAREN let_pattern opt_default RPAREN
      { (Optional $1, $4, $3) }
  | OPTLABEL pattern_var
      { (Optional $1, None, $2) }
  | TILDE LPAREN label_let_pattern RPAREN
      { (Labelled (fst $3), None, snd $3) }
  | TILDE label_var
      { (Labelled (fst $2), None, snd $2) }
  | LABEL simple_pattern
      { (Labelled $1, None, $2) }
  | simple_pattern
      { (Nolabel, None, $1) }
;
pattern_var:
    LIDENT            { _mkpat(Ppat_var (_mkrhs($1, 1))) }
  | UNDERSCORE        { _mkpat Ppat_any }
;
opt_default:
    /* empty */                         { None }
  | EQUAL seq_expr                      { Some $2 }
;
label_let_pattern:
    label_var
      { $1 }
  | label_var COLON core_type
      { let (lab, pat) = $1 in (lab, _mkpat(Ppat_constraint(pat, $3))) }
;
label_var:
    LIDENT    { ($1, _mkpat(Ppat_var (_mkrhs($1, 1)))) }
;
let_pattern:
    pattern
      { $1 }
  | pattern COLON core_type
      { _mkpat(Ppat_constraint($1, $3)) }
;
expr:
    simple_expr %prec below_HASH
      { $1 }
  | simple_expr simple_labeled_expr_list
      { _mkexp(Pexp_apply($1, List.rev $2)) }
  | let_bindings IN seq_expr
      { _expr_of_let_bindings $1 $3 }
  | LET MODULE ext_attributes UIDENT module_binding_body IN seq_expr
      { _mkexp_attrs (Pexp_letmodule(_mkrhs($4, 4), $5, $7)) $3 }
  | LET EXCEPTION ext_attributes let_exception_declaration IN seq_expr
      { _mkexp_attrs (Pexp_letexception($4, $6)) $3 }
  | LET OPEN override_flag ext_attributes mod_longident IN seq_expr
      { _mkexp_attrs (Pexp_open($3, _mkrhs($5, 5), $7)) $4 }
  | FUNCTION ext_attributes opt_bar match_cases
      { _mkexp_attrs (Pexp_function(List.rev $4)) $2 }
  | FUN ext_attributes labeled_simple_pattern fun_def
      { let (l,o,p) = $3 in
        _mkexp_attrs (Pexp_fun(l, o, p, $4)) $2 }
  | FUN ext_attributes LPAREN TYPE lident_list RPAREN fun_def
      { _mkexp_attrs (_mk_newtypes $5 $7).pexp_desc $2 }
  | MATCH ext_attributes seq_expr WITH opt_bar match_cases
      { _mkexp_attrs (Pexp_match($3, List.rev $6)) $2 }
  | TRY ext_attributes seq_expr WITH opt_bar match_cases
      { _mkexp_attrs (Pexp_try($3, List.rev $6)) $2 }
  | TRY ext_attributes seq_expr WITH error
      { syntax_error() }
  | expr_comma_list %prec below_COMMA
      { _mkexp(Pexp_tuple(List.rev $1)) }
  | constr_longident simple_expr %prec below_HASH
      { _mkexp(Pexp_construct(_mkrhs($1, 1), Some $2)) }
  | name_tag simple_expr %prec below_HASH
      { _mkexp(Pexp_variant($1, Some $2)) }
  | IF ext_attributes seq_expr THEN expr ELSE expr
      { _mkexp_attrs(Pexp_ifthenelse($3, $5, Some $7)) $2 }
  | IF ext_attributes seq_expr THEN expr
      { _mkexp_attrs (Pexp_ifthenelse($3, $5, None)) $2 }
  | WHILE ext_attributes seq_expr DO seq_expr DONE
      { _mkexp_attrs (Pexp_while($3, $5)) $2 }
  | FOR ext_attributes pattern EQUAL seq_expr direction_flag seq_expr DO
    seq_expr DONE
      { _mkexp_attrs(Pexp_for($3, $5, $7, $6, $9)) $2 }
  | expr COLONCOLON expr
      { mkexp_cons (_rhs_loc(2)) (_ghexp(Pexp_tuple[$1;$3])) (_symbol_rloc()) }
  | expr INFIXOP0 expr
      { _mkinfix $1 $2 $3 }
  | expr INFIXOP1 expr
      { _mkinfix $1 $2 $3 }
  | expr INFIXOP2 expr
      { _mkinfix $1 $2 $3 }
  | expr INFIXOP3 expr
      { _mkinfix $1 $2 $3 }
  | expr INFIXOP4 expr
      { _mkinfix $1 $2 $3 }
  | expr PLUS expr
      { _mkinfix $1 "+" $3 }
  | expr PLUSDOT expr
      { _mkinfix $1 "+." $3 }
  | expr PLUSEQ expr
      { _mkinfix $1 "+=" $3 }
  | expr MINUS expr
      { _mkinfix $1 "-" $3 }
  | expr MINUSDOT expr
      { _mkinfix $1 "-." $3 }
  | expr STAR expr
      { _mkinfix $1 "*" $3 }
  | expr PERCENT expr
      { _mkinfix $1 "%" $3 }
  | expr EQUAL expr
      { _mkinfix $1 "=" $3 }
  | expr LESS expr
    { _mkinfix $1 "<" $3 }
  | expr GREATER expr
      { _mkinfix $1 ">" $3 }
  | expr OR expr
      { _mkinfix $1 "or" $3 }
  | expr BARBAR expr
      { _mkinfix $1 "||" $3 }
  | expr AMPERSAND expr
      { _mkinfix $1 "&" $3 }
  | expr AMPERAMPER expr
      { _mkinfix $1 "&&" $3 }
  | expr COLONEQUAL expr
      { _mkinfix $1 ":=" $3 }
  | subtractive expr %prec prec_unary_minus
      { _mkuminus $1 $2 }
  | additive expr %prec prec_unary_plus
      { _mkuplus $1 $2 }
  | simple_expr DOT label_longident LESSMINUS expr
      { _mkexp(Pexp_setfield($1, _mkrhs($3, 3), $5)) }
  | simple_expr DOT LPAREN seq_expr RPAREN LESSMINUS expr
      { _mkexp(Pexp_apply(_ghexp(Pexp_ident(_array_function "Array" "set")),
                         [Nolabel,$1; Nolabel,$4; Nolabel,$7])) }
  | simple_expr DOT LBRACKET seq_expr RBRACKET LESSMINUS expr
      { _mkexp(Pexp_apply(_ghexp(Pexp_ident(_array_function "String" "set")),
                         [Nolabel,$1; Nolabel,$4; Nolabel,$7])) }
  | simple_expr DOT LBRACE expr RBRACE LESSMINUS expr
      { _bigarray_set $1 $4 $7 }
  | simple_expr DOTOP LBRACKET expr RBRACKET LESSMINUS expr
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Lident ("." ^ $2 ^ "[]<-")) in
        _mkexp @@ Pexp_apply(id , [Nolabel, $1; Nolabel, $4; Nolabel, $7]) }
  | simple_expr DOTOP LPAREN expr RPAREN LESSMINUS expr
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Lident ("." ^ $2 ^ "()<-")) in
        _mkexp @@ Pexp_apply(id , [Nolabel, $1; Nolabel, $4; Nolabel, $7]) }
  | simple_expr DOTOP LBRACE expr RBRACE LESSMINUS expr
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Lident ("." ^ $2 ^ "{}<-")) in
        _mkexp @@ Pexp_apply(id , [Nolabel, $1; Nolabel, $4; Nolabel, $7]) }
  | simple_expr DOT mod_longident DOTOP LBRACKET expr RBRACKET LESSMINUS expr
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Ldot($3,"." ^ $4 ^ "[]<-")) in
        _mkexp @@ Pexp_apply(id , [Nolabel, $1; Nolabel, $6; Nolabel, $9]) }
  | simple_expr DOT mod_longident DOTOP LPAREN expr RPAREN LESSMINUS expr
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Ldot($3, "." ^ $4 ^ "()<-")) in
        _mkexp @@ Pexp_apply(id , [Nolabel, $1; Nolabel, $6; Nolabel, $9]) }
  | simple_expr DOT mod_longident DOTOP LBRACE expr RBRACE LESSMINUS expr
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Ldot($3, "." ^ $4 ^ "{}<-")) in
        _mkexp @@ Pexp_apply(id , [Nolabel, $1; Nolabel, $6; Nolabel, $9]) }
  | label LESSMINUS expr
      { _mkexp(Pexp_setinstvar(_mkrhs($1, 1), $3)) }
  | ASSERT ext_attributes simple_expr %prec below_HASH
      { _mkexp_attrs (Pexp_assert $3) $2 }
  | LAZY ext_attributes simple_expr %prec below_HASH
      { _mkexp_attrs (Pexp_lazy $3) $2 }
  | OBJECT ext_attributes class_structure END
      { _mkexp_attrs (Pexp_object $3) $2 }
  | OBJECT ext_attributes class_structure error
      { _unclosed("object", 1, "end", 4) }
  | expr attribute
      { Exp.attr $1 $2 }
  | UNDERSCORE
     { _not_expecting(1, "wildcard \"_\"") }
;
simple_expr:
    val_longident
      { _mkexp(Pexp_ident (_mkrhs($1, 1))) }
  | constant
      { _mkexp(Pexp_constant $1) }
  | constr_longident %prec prec_constant_constructor
      { _mkexp(Pexp_construct(_mkrhs($1, 1), None)) }
  | name_tag %prec prec_constant_constructor
      { _mkexp(Pexp_variant($1, None)) }
  | LPAREN seq_expr RPAREN
      { _reloc_exp $2 }
  | LPAREN seq_expr error
      { _unclosed("(", 1, ")", 3) }
  | BEGIN ext_attributes seq_expr END
      { _wrap_exp_attrs (_reloc_exp $3) $2 (* check location *) }
  | BEGIN ext_attributes END
      { _mkexp_attrs (Pexp_construct (mkloc (Lident "()") (_symbol_rloc()),
                               None)) $2 }
  | BEGIN ext_attributes seq_expr error
      { _unclosed("begin", 1, "end", 4) }
  | LPAREN seq_expr type_constraint RPAREN
      { _mkexp_constraint $2 $3 }
  | simple_expr DOT label_longident
      { _mkexp(Pexp_field($1, _mkrhs($3, 3))) }
  | mod_longident DOT LPAREN seq_expr RPAREN
      { _mkexp(Pexp_open(Fresh, _mkrhs($1, 1), $4)) }
  | mod_longident DOT LPAREN RPAREN
      { _mkexp(Pexp_open(Fresh, _mkrhs($1, 1),
                        _mkexp(Pexp_construct(_mkrhs2((Lident "()"), 3, 4),
                                              None)))) }
  | mod_longident DOT LPAREN seq_expr error
      { _unclosed("(", 3, ")", 5) }
  | simple_expr DOT LPAREN seq_expr RPAREN
      { _mkexp(Pexp_apply(_ghexp(Pexp_ident(_array_function "Array" "get")),
                         [Nolabel,$1; Nolabel,$4])) }
  | simple_expr DOT LPAREN seq_expr error
      { _unclosed("(", 3, ")", 5) }
  | simple_expr DOT LBRACKET seq_expr RBRACKET
      { _mkexp(Pexp_apply(_ghexp(Pexp_ident(_array_function "String" "get")),
                         [Nolabel,$1; Nolabel,$4])) }
  | simple_expr DOT LBRACKET seq_expr error
      { _unclosed("[", 3, "]", 5) }
  | simple_expr DOTOP LBRACKET expr RBRACKET
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Lident ("." ^ $2 ^ "[]")) in
        _mkexp @@ Pexp_apply(id, [Nolabel, $1; Nolabel, $4]) }
  | simple_expr DOTOP LBRACKET expr error
      { _unclosed("[", 3, "]", 5) }
  | simple_expr DOTOP LPAREN expr RPAREN
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Lident ("." ^ $2 ^ "()")) in
        _mkexp @@ Pexp_apply(id, [Nolabel, $1; Nolabel, $4]) }
  | simple_expr DOTOP LPAREN expr error
      { _unclosed("(", 3, ")", 5) }
  | simple_expr DOTOP LBRACE expr RBRACE
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Lident ("." ^ $2 ^ "{}")) in
        _mkexp @@ Pexp_apply(id, [Nolabel, $1; Nolabel, $4]) }
  | simple_expr DOTOP LBRACE expr error
      { _unclosed("{", 3, "}", 5) }
  | simple_expr DOT mod_longident DOTOP LBRACKET expr RBRACKET
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Ldot($3, "." ^ $4 ^ "[]")) in
        _mkexp @@ Pexp_apply(id, [Nolabel, $1; Nolabel, $6]) }
  | simple_expr DOT mod_longident DOTOP LBRACKET expr error
      { _unclosed("[", 5, "]", 7) }
  | simple_expr DOT mod_longident DOTOP LPAREN expr RPAREN
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Ldot($3, "." ^ $4 ^ "()")) in
        _mkexp @@ Pexp_apply(id, [Nolabel, $1; Nolabel, $6]) }
  | simple_expr DOT mod_longident DOTOP LPAREN expr error
      { _unclosed("(", 5, ")", 7) }
  | simple_expr DOT mod_longident DOTOP LBRACE expr RBRACE
      { let id = _mkexp @@ Pexp_ident(_ghloc @@ Ldot($3, "." ^ $4 ^ "{}")) in
        _mkexp @@ Pexp_apply(id, [Nolabel, $1; Nolabel, $6]) }
  | simple_expr DOT mod_longident DOTOP LBRACE expr error
      { _unclosed("{", 5, "}", 7) }
  | simple_expr DOT LBRACE expr RBRACE
      { _bigarray_get $1 $4 }
  | simple_expr DOT LBRACE expr_comma_list error
      { _unclosed("{", 3, "}", 5) }
  | LBRACE record_expr RBRACE
      { let (exten, fields) = $2 in _mkexp (Pexp_record(fields, exten)) }
  | LBRACE record_expr error
      { _unclosed("{", 1, "}", 3) }
  | mod_longident DOT LBRACE record_expr RBRACE
      { let (exten, fields) = $4 in
        let rec_exp = _mkexp(Pexp_record(fields, exten)) in
        _mkexp(Pexp_open(Fresh, _mkrhs($1, 1), rec_exp)) }
  | mod_longident DOT LBRACE record_expr error
      { _unclosed("{", 3, "}", 5) }
  | LBRACKETBAR expr_semi_list opt_semi BARRBRACKET
      { _mkexp (Pexp_array(List.rev $2)) }
  | LBRACKETBAR expr_semi_list opt_semi error
      { _unclosed("[|", 1, "|]", 4) }
  | LBRACKETBAR BARRBRACKET
      { _mkexp (Pexp_array []) }
  | mod_longident DOT LBRACKETBAR expr_semi_list opt_semi BARRBRACKET
      { _mkexp(Pexp_open(Fresh, _mkrhs($1, 1), _mkexp(Pexp_array(List.rev $4)))) }
 | mod_longident DOT LBRACKETBAR BARRBRACKET
      { _mkexp(Pexp_open(Fresh, _mkrhs($1, 1), _mkexp(Pexp_array []))) }
  | mod_longident DOT LBRACKETBAR expr_semi_list opt_semi error
      { _unclosed("[|", 3, "|]", 6) }
  | LBRACKET expr_semi_list opt_semi RBRACKET
      { _reloc_exp (mktailexp (_rhs_loc(4)) (List.rev $2)) }
  | LBRACKET expr_semi_list opt_semi error
      { _unclosed("[", 1, "]", 4) }
  | mod_longident DOT LBRACKET expr_semi_list opt_semi RBRACKET
      { let list_exp = _reloc_exp (mktailexp (_rhs_loc(6)) (List.rev $4)) in
        _mkexp(Pexp_open(Fresh, _mkrhs($1, 1), list_exp)) }
  | mod_longident DOT LBRACKET RBRACKET
      { _mkexp(Pexp_open(Fresh, _mkrhs($1, 1),
                        _mkexp(Pexp_construct(_mkrhs2((Lident "[]"), 3, 4),
                                              None)))) }
  | mod_longident DOT LBRACKET expr_semi_list opt_semi error
      { _unclosed("[", 3, "]", 6) }
  | PREFIXOP simple_expr
      { _mkexp(Pexp_apply(_mkoperator($1, 1), [Nolabel,$2])) }
  | BANG simple_expr
      { _mkexp(Pexp_apply(_mkoperator("!", 1), [Nolabel,$2])) }
  | NEW ext_attributes class_longident
      { _mkexp_attrs (Pexp_new(_mkrhs($3, 3))) $2 }
  | LBRACELESS field_expr_list GREATERRBRACE
      { _mkexp (Pexp_override $2) }
  | LBRACELESS field_expr_list error
      { _unclosed("{<", 1, ">}", 3) }
  | LBRACELESS GREATERRBRACE
      { _mkexp (Pexp_override [])}
  | mod_longident DOT LBRACELESS field_expr_list GREATERRBRACE
      { _mkexp(Pexp_open(Fresh, _mkrhs($1, 1), _mkexp (Pexp_override $4)))}
  | mod_longident DOT LBRACELESS field_expr_list error
      { _unclosed("{<", 3, ">}", 5) }
  | simple_expr HASH label
      { _mkexp(Pexp_send($1, _mkrhs($3, 3))) }
  | simple_expr HASHOP simple_expr
      { _mkinfix $1 $2 $3 }
  | LPAREN MODULE ext_attributes module_expr RPAREN
      { _mkexp_attrs (Pexp_pack $4) $3 }
  | LPAREN MODULE ext_attributes module_expr COLON package_type RPAREN
      { _mkexp_attrs (Pexp_constraint (_ghexp (Pexp_pack $4), $6))
                    $3 }
  | LPAREN MODULE ext_attributes module_expr COLON error
      { _unclosed("(", 1, ")", 6) }
  | mod_longident DOT LPAREN MODULE ext_attributes module_expr COLON
    package_type RPAREN
      { _mkexp(Pexp_open(Fresh, _mkrhs($1, 1),
        _mkexp_attrs(Pexp_constraint (_ghexp(Pexp_pack $6), $8))
                    $5 )) }
  | mod_longident DOT LPAREN MODULE ext_attributes module_expr COLON error
      { _unclosed("(", 3, ")", 8) }
  | extension
      { _mkexp (Pexp_extension $1) }
;
simple_labeled_expr_list:
    labeled_simple_expr
      { [$1] }
  | simple_labeled_expr_list labeled_simple_expr
      { $2 :: $1 }
;
labeled_simple_expr:
    simple_expr %prec below_HASH
      { (Nolabel, $1) }
  | label_expr
      { $1 }
;
label_expr:
    LABEL simple_expr %prec below_HASH
      { (Labelled $1, $2) }
  | TILDE label_ident
      { (Labelled (fst $2), snd $2) }
  | QUESTION label_ident
      { (Optional (fst $2), snd $2) }
  | OPTLABEL simple_expr %prec below_HASH
      { (Optional $1, $2) }
;
label_ident:
    LIDENT   { ($1, _mkexp(Pexp_ident(_mkrhs((Lident $1), 1)))) }
;
lident_list:
    LIDENT                            { [_mkrhs($1, 1)] }
  | LIDENT lident_list                { _mkrhs($1, 1) :: $2 }
;
let_binding_body:
    val_ident strict_binding
      { (_mkpatvar($1, 1), $2) }
  | val_ident type_constraint EQUAL seq_expr
      { let v = _mkpatvar($1, 1) in (* PR#7344 *)
        let t =
          match $2 with
            Some t, None -> t
          | _, Some t -> t
          | _ -> assert false
        in
        let typ = ghtyp ~loc:t.ptyp_loc (Ptyp_poly([],t)) in
        let patloc = _rhs_interval(1, 2) in
        (ghpat ~loc:patloc (Ppat_constraint(v, typ)),
         _mkexp_constraint $4 $2) }
  | val_ident COLON typevar_list DOT core_type EQUAL seq_expr
      { let typloc = _rhs_interval(3, 5) in
        let patloc = _rhs_interval(1, 5) in
        (ghpat ~loc:patloc
           (Ppat_constraint(_mkpatvar($1, 1),
                            ghtyp ~loc:typloc (Ptyp_poly(List.rev $3,$5)))),
         $7) }
  | val_ident COLON TYPE lident_list DOT core_type EQUAL seq_expr
      { let exp, poly = _wrap_type_annotation $4 $6 $8 in
        let loc = _rhs_interval(1, 6) in
        (ghpat ~loc (Ppat_constraint(_mkpatvar($1, 1), poly)), exp) }
  | pattern_no_exn EQUAL seq_expr
      { ($1, $3) }
  | simple_pattern_not_ident COLON core_type EQUAL seq_expr
      { let loc = _rhs_interval(1, 3) in
        (ghpat ~loc (Ppat_constraint($1, $3)), $5) }
;
let_bindings:
    let_binding                                 { $1 }
  | let_bindings and_let_binding                { addlb $1 $2 }
;
let_binding:
    LET ext_attributes rec_flag let_binding_body post_item_attributes
      { let (ext, attr) = $2 in
        _mklbs ext $3 (_mklb true $4 (attr@$5)) }
;
and_let_binding:
    AND attributes let_binding_body post_item_attributes
      { _mklb false $3 ($2@$4) }
;
fun_binding:
    strict_binding
      { $1 }
  | type_constraint EQUAL seq_expr
      { _mkexp_constraint $3 $1 }
;
strict_binding:
    EQUAL seq_expr
      { $2 }
  | labeled_simple_pattern fun_binding
      { let (l, o, p) = $1 in _ghexp(Pexp_fun(l, o, p, $2)) }
  | LPAREN TYPE lident_list RPAREN fun_binding
      { _mk_newtypes $3 $5 }
;
match_cases:
    match_case { [$1] }
  | match_cases BAR match_case { $3 :: $1 }
;
match_case:
    pattern MINUSGREATER seq_expr
      { Exp.case $1 $3 }
  | pattern WHEN seq_expr MINUSGREATER seq_expr
      { Exp.case $1 ~guard:$3 $5 }
  | pattern MINUSGREATER DOT
      { Exp.case $1 (Exp.unreachable ~loc:(_rhs_loc(3)) ())}
;
fun_def:
    MINUSGREATER seq_expr
      { $2 }
  | COLON simple_core_type MINUSGREATER seq_expr
      { _mkexp (Pexp_constraint ($4, $2)) }
/* Cf #5939: we used to accept (fun p when e0 -> e) */
  | labeled_simple_pattern fun_def
      {
       let (l,o,p) = $1 in
       _ghexp(Pexp_fun(l, o, p, $2))
      }
  | LPAREN TYPE lident_list RPAREN fun_def
      { _mk_newtypes $3 $5 }
;
expr_comma_list:
    expr_comma_list COMMA expr                  { $3 :: $1 }
  | expr COMMA expr                             { [$3; $1] }
;
record_expr:
    simple_expr WITH lbl_expr_list              { (Some $1, $3) }
  | lbl_expr_list                               { (None, $1) }
;
lbl_expr_list:
     lbl_expr { [$1] }
  |  lbl_expr SEMI lbl_expr_list { $1 :: $3 }
  |  lbl_expr SEMI { [$1] }
;
lbl_expr:
    label_longident opt_type_constraint EQUAL expr
      { (_mkrhs($1, 1), _mkexp_opt_constraint $4 $2) }
  | label_longident opt_type_constraint
      { (_mkrhs($1, 1), _mkexp_opt_constraint (_exp_of_label($1, 1)) $2) }
;
field_expr_list:
    field_expr opt_semi { [$1] }
  | field_expr SEMI field_expr_list { $1 :: $3 }
;
field_expr:
    label EQUAL expr
      { (_mkrhs($1, 1), $3) }
  | label
      { (_mkrhs($1, 1), _exp_of_label((Lident $1), 1)) }
;
expr_semi_list:
    expr                                        { [$1] }
  | expr_semi_list SEMI expr                    { $3 :: $1 }
;
type_constraint:
    COLON core_type                             { (Some $2, None) }
  | COLON core_type COLONGREATER core_type      { (Some $2, Some $4) }
  | COLONGREATER core_type                      { (None, Some $2) }
  | COLON error                                 { syntax_error() }
  | COLONGREATER error                          { syntax_error() }
;
opt_type_constraint:
    type_constraint { Some $1 }
  | /* empty */ { None }
;

/* Patterns */

pattern:
  | pattern AS val_ident
      { _mkpat(Ppat_alias($1, _mkrhs($3, 3))) }
  | pattern AS error
      { _expecting(3, "identifier") }
  | pattern_comma_list  %prec below_COMMA
      { _mkpat(Ppat_tuple(List.rev $1)) }
  | pattern COLONCOLON pattern
      { mkpat_cons (_rhs_loc(2)) (_ghpat(Ppat_tuple[$1;$3])) (_symbol_rloc()) }
  | pattern COLONCOLON error
      { _expecting(3, "pattern") }
  | pattern BAR pattern
      { _mkpat(Ppat_or($1, $3)) }
  | pattern BAR error
      { _expecting(3, "pattern") }
  | EXCEPTION ext_attributes pattern %prec prec_constr_appl
      { _mkpat_attrs (Ppat_exception $3) $2}
  | pattern attribute
      { Pat.attr $1 $2 }
  | pattern_gen { $1 }
;
pattern_no_exn:
  | pattern_no_exn AS val_ident
      { _mkpat(Ppat_alias($1, _mkrhs($3, 3))) }
  | pattern_no_exn AS error
      { _expecting(3, "identifier") }
  | pattern_no_exn_comma_list  %prec below_COMMA
      { _mkpat(Ppat_tuple(List.rev $1)) }
  | pattern_no_exn COLONCOLON pattern
      { mkpat_cons (_rhs_loc(2)) (_ghpat(Ppat_tuple[$1;$3])) (_symbol_rloc()) }
  | pattern_no_exn COLONCOLON error
      { _expecting(3, "pattern") }
  | pattern_no_exn BAR pattern
      { _mkpat(Ppat_or($1, $3)) }
  | pattern_no_exn BAR error
      { _expecting(3, "pattern") }
  | pattern_no_exn attribute
      { Pat.attr $1 $2 }
  | pattern_gen { $1 }
;
pattern_gen:
    simple_pattern
      { $1 }
  | constr_longident pattern %prec prec_constr_appl
      { _mkpat(Ppat_construct(_mkrhs($1, 1), Some $2)) }
  | name_tag pattern %prec prec_constr_appl
      { _mkpat(Ppat_variant($1, Some $2)) }
  | LAZY ext_attributes simple_pattern
      { _mkpat_attrs (Ppat_lazy $3) $2}
;
simple_pattern:
    val_ident %prec below_EQUAL
      { _mkpat(Ppat_var (_mkrhs($1, 1))) }
  | simple_pattern_not_ident { $1 }
;
simple_pattern_not_ident:
  | UNDERSCORE
      { _mkpat(Ppat_any) }
  | signed_constant
      { _mkpat(Ppat_constant $1) }
  | signed_constant DOTDOT signed_constant
      { _mkpat(Ppat_interval ($1, $3)) }
  | constr_longident
      { _mkpat(Ppat_construct(_mkrhs($1, 1), None)) }
  | name_tag
      { _mkpat(Ppat_variant($1, None)) }
  | HASH type_longident
      { _mkpat(Ppat_type (_mkrhs($2, 2))) }
  | simple_delimited_pattern
      { $1 }
  | mod_longident DOT simple_delimited_pattern
      { _mkpat @@ Ppat_open(_mkrhs($1, 1), $3) }
  | mod_longident DOT LBRACKET RBRACKET
    { _mkpat @@ Ppat_open(_mkrhs($1, 1), _mkpat @@
               Ppat_construct ( _mkrhs2((Lident "[]"), 3, 4), None)) }
  | mod_longident DOT LPAREN RPAREN
      { _mkpat @@ Ppat_open( _mkrhs($1, 1), _mkpat @@
                 Ppat_construct ( _mkrhs2((Lident "()"), 3, 4), None) ) }
  | mod_longident DOT LPAREN pattern RPAREN
      { _mkpat @@ Ppat_open (_mkrhs($1, 1), $4) }
  | mod_longident DOT LPAREN pattern error
      { _unclosed("(", 3, ")", 5)  }
  | mod_longident DOT LPAREN error
      { _expecting(4, "pattern") }
  | LPAREN pattern RPAREN
      { _reloc_pat $2 }
  | LPAREN pattern error
      { _unclosed("(", 1, ")", 3) }
  | LPAREN pattern COLON core_type RPAREN
      { _mkpat(Ppat_constraint($2, $4)) }
  | LPAREN pattern COLON core_type error
      { _unclosed("(", 1, ")", 5) }
  | LPAREN pattern COLON error
      { _expecting(4, "type") }
  | LPAREN MODULE ext_attributes UIDENT RPAREN
      { _mkpat_attrs (Ppat_unpack (_mkrhs($4, 4))) $3 }
  | LPAREN MODULE ext_attributes UIDENT COLON package_type RPAREN
      { _mkpat_attrs
          (Ppat_constraint(_mkpat(Ppat_unpack (_mkrhs($4, 4))), $6))
          $3 }
  | LPAREN MODULE ext_attributes UIDENT COLON package_type error
      { _unclosed("(", 1, ")", 7) }
  | extension
      { _mkpat(Ppat_extension $1) }
;

simple_delimited_pattern:
  | LBRACE lbl_pattern_list RBRACE
    { let (fields, closed) = $2 in _mkpat(Ppat_record(fields, closed)) }
  | LBRACE lbl_pattern_list error
    { _unclosed("{", 1, "}", 3) }
  | LBRACKET pattern_semi_list opt_semi RBRACKET
    { _reloc_pat (mktailpat (_rhs_loc(4)) (List.rev $2)) }
  | LBRACKET pattern_semi_list opt_semi error
    { _unclosed("[", 1, "]", 4) }
  | LBRACKETBAR pattern_semi_list opt_semi BARRBRACKET
    { _mkpat(Ppat_array(List.rev $2)) }
  | LBRACKETBAR BARRBRACKET
    { _mkpat(Ppat_array []) }
  | LBRACKETBAR pattern_semi_list opt_semi error
    { _unclosed("[|", 1, "|]", 4) }

pattern_comma_list:
    pattern_comma_list COMMA pattern            { $3 :: $1 }
  | pattern COMMA pattern                       { [$3; $1] }
  | pattern COMMA error                         { _expecting(3, "pattern") }
;
pattern_no_exn_comma_list:
    pattern_no_exn_comma_list COMMA pattern     { $3 :: $1 }
  | pattern_no_exn COMMA pattern                { [$3; $1] }
  | pattern_no_exn COMMA error                  { _expecting(3, "pattern") }
;
pattern_semi_list:
    pattern                                     { [$1] }
  | pattern_semi_list SEMI pattern              { $3 :: $1 }
;
lbl_pattern_list:
    lbl_pattern { [$1], Closed }
  | lbl_pattern SEMI { [$1], Closed }
  | lbl_pattern SEMI UNDERSCORE opt_semi { [$1], Open }
  | lbl_pattern SEMI lbl_pattern_list
      { let (fields, closed) = $3 in $1 :: fields, closed }
;
lbl_pattern:
    label_longident opt_pattern_type_constraint EQUAL pattern
     { (_mkrhs($1, 1), _mkpat_opt_constraint $4 $2) }
  | label_longident opt_pattern_type_constraint
     { (_mkrhs($1, 1), _mkpat_opt_constraint (_pat_of_label($1, 1)) $2) }
;
opt_pattern_type_constraint:
    COLON core_type { Some $2 }
  | /* empty */ { None }
;

/* Value descriptions */

value_description:
    VAL ext_attributes val_ident COLON core_type post_item_attributes
      { let (ext, attrs) = $2 in
        Val.mk (_mkrhs($3, 3)) $5 ~attrs:(attrs@$6)
              ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ())
      , ext }
;

/* Primitive declarations */

primitive_declaration_body:
    STRING                                      { [fst $1] }
  | STRING primitive_declaration_body           { fst $1 :: $2 }
;
primitive_declaration:
    EXTERNAL ext_attributes val_ident COLON core_type EQUAL
    primitive_declaration_body post_item_attributes
      { let (ext, attrs) = $2 in
        Val.mk (_mkrhs($3, 3)) $5 ~prim:$7 ~attrs:(attrs@$8)
              ~loc:(_symbol_rloc ()) ~docs:(_symbol_docs ())
      , ext }
;

/* Type declarations */

type_declarations:
    type_declaration
      { let (nonrec_flag, ty, ext) = $1 in (nonrec_flag, [ty], ext) }
  | type_declarations and_type_declaration
      { let (nonrec_flag, tys, ext) = $1 in (nonrec_flag, $2 :: tys, ext) }
;

type_declaration:
    TYPE ext_attributes nonrec_flag optional_type_parameters LIDENT
    type_kind constraints post_item_attributes
      { let (kind, priv, manifest) = $6 in
        let (ext, attrs) = $2 in
        let ty =
          Type.mk (_mkrhs($5, 5)) ~params:$4 ~cstrs:(List.rev $7) ~kind
            ~priv ?manifest ~attrs:(attrs@$8)
            ~loc:(_symbol_rloc ()) ~docs:(_symbol_docs ())
        in
          ($3, ty, ext) }
;
and_type_declaration:
    AND attributes optional_type_parameters LIDENT type_kind constraints
    post_item_attributes
      { let (kind, priv, manifest) = $5 in
          Type.mk (_mkrhs($4, 4)) ~params:$3 ~cstrs:(List.rev $6)
            ~kind ~priv ?manifest ~attrs:($2@$7) ~loc:(_symbol_rloc ())
            ~text:(_symbol_text ()) ~docs:(_symbol_docs ()) }
;
constraints:
        constraints CONSTRAINT constrain        { $3 :: $1 }
      | /* empty */                             { [] }
;
type_kind:
    /*empty*/
      { (Ptype_abstract, Public, None) }
  | EQUAL core_type
      { (Ptype_abstract, Public, Some $2) }
  | EQUAL PRIVATE core_type
      { (Ptype_abstract, Private, Some $3) }
  | EQUAL constructor_declarations
      { (Ptype_variant(List.rev $2), Public, None) }
  | EQUAL PRIVATE constructor_declarations
      { (Ptype_variant(List.rev $3), Private, None) }
  | EQUAL DOTDOT
      { (Ptype_open, Public, None) }
  | EQUAL PRIVATE DOTDOT
      { (Ptype_open, Private, None) }
  | EQUAL private_flag LBRACE label_declarations RBRACE
      { (Ptype_record $4, $2, None) }
  | EQUAL core_type EQUAL private_flag constructor_declarations
      { (Ptype_variant(List.rev $5), $4, Some $2) }
  | EQUAL core_type EQUAL private_flag DOTDOT
      { (Ptype_open, $4, Some $2) }
  | EQUAL core_type EQUAL private_flag LBRACE label_declarations RBRACE
      { (Ptype_record $6, $4, Some $2) }
;
optional_type_parameters:
    /*empty*/                                   { [] }
  | optional_type_parameter                     { [$1] }
  | LPAREN optional_type_parameter_list RPAREN  { List.rev $2 }
;
optional_type_parameter:
    type_variance optional_type_variable        { $2, $1 }
;
optional_type_parameter_list:
    optional_type_parameter                              { [$1] }
  | optional_type_parameter_list COMMA optional_type_parameter    { $3 :: $1 }
;
optional_type_variable:
    QUOTE ident                                 { _mktyp(Ptyp_var $2) }
  | UNDERSCORE                                  { _mktyp(Ptyp_any) }
;


type_parameter:
    type_variance type_variable                   { $2, $1 }
;
type_variance:
    /* empty */                                 { Invariant }
  | PLUS                                        { Covariant }
  | MINUS                                       { Contravariant }
;
type_variable:
    QUOTE ident                                 { _mktyp(Ptyp_var $2) }
;
type_parameter_list:
    type_parameter                              { [$1] }
  | type_parameter_list COMMA type_parameter    { $3 :: $1 }
;
constructor_declarations:
  | BAR                                                  { [  ] }
  | constructor_declaration                              { [$1] }
  | bar_constructor_declaration                          { [$1] }
  | constructor_declarations bar_constructor_declaration { $2 :: $1 }
;
constructor_declaration:
  | constr_ident generalized_constructor_arguments attributes
      {
       let args,res = $2 in
       Type.constructor (_mkrhs($1, 1)) ~args ?res ~attrs:$3
         ~loc:(_symbol_rloc()) ~info:(_symbol_info ())
      }
;
bar_constructor_declaration:
  | BAR constr_ident generalized_constructor_arguments attributes
      {
       let args,res = $3 in
       Type.constructor (_mkrhs($2, 2)) ~args ?res ~attrs:$4
         ~loc:(_symbol_rloc()) ~info:(_symbol_info ())
      }
;
str_exception_declaration:
  | sig_exception_declaration                    { $1 }
  | EXCEPTION ext_attributes constr_ident EQUAL constr_longident attributes
    post_item_attributes
    { let (ext,attrs) = $2 in
      Te.mk_exception ~attrs:$7
        (Te.rebind (_mkrhs($3, 3)) (_mkrhs($5, 5)) ~attrs:(attrs @ $6)
           ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ()))
    , ext }
;
sig_exception_declaration:
  | EXCEPTION ext_attributes constr_ident generalized_constructor_arguments
    attributes post_item_attributes
      { let args, res = $4 in
        let (ext,attrs) = $2 in
        Te.mk_exception ~attrs:$6
          (Te.decl (_mkrhs($3, 3)) ~args ?res ~attrs:(attrs @ $5)
             ~loc:(_symbol_rloc()) ~docs:(_symbol_docs ()))
        , ext }
;
let_exception_declaration:
    constr_ident generalized_constructor_arguments attributes
      { let args, res = $2 in
        Te.decl (_mkrhs($1, 1)) ~args ?res ~attrs:$3 ~loc:(_symbol_rloc()) }
;
generalized_constructor_arguments:
    /*empty*/                     { (Pcstr_tuple [],None) }
  | OF constructor_arguments      { ($2,None) }
  | COLON constructor_arguments MINUSGREATER simple_core_type
                                  { ($2,Some $4) }
  | COLON simple_core_type
                                  { (Pcstr_tuple [],Some $2) }
;

constructor_arguments:
  | core_type_list                   { Pcstr_tuple (List.rev $1) }
  | LBRACE label_declarations RBRACE { Pcstr_record $2 }
;
label_declarations:
    label_declaration                           { [$1] }
  | label_declaration_semi                      { [$1] }
  | label_declaration_semi label_declarations   { $1 :: $2 }
;
label_declaration:
    mutable_flag label COLON poly_type_no_attr attributes
      {
       Type.field (_mkrhs($2, 2)) $4 ~mut:$1 ~attrs:$5
         ~loc:(_symbol_rloc()) ~info:(_symbol_info ())
      }
;
label_declaration_semi:
    mutable_flag label COLON poly_type_no_attr attributes SEMI attributes
      {
       let info =
         match _rhs_info(5) with
         | Some _ as info_before_semi -> info_before_semi
         | None -> _symbol_info()
       in
       Type.field (_mkrhs($2, 2)) $4 ~mut:$1 ~attrs:($5 @ $7)
         ~loc:(_symbol_rloc()) ~info
      }
;

/* Type Extensions */

str_type_extension:
  TYPE ext_attributes nonrec_flag optional_type_parameters type_longident
  PLUSEQ private_flag str_extension_constructors post_item_attributes
      { let (ext, attrs) = $2 in
        if $3 <> Recursive then _not_expecting(3, "nonrec flag");
        Te.mk (_mkrhs($5, 5)) (List.rev $8) ~params:$4 ~priv:$7
          ~attrs:(attrs@$9) ~docs:(_symbol_docs ())
        , ext }
;
sig_type_extension:
  TYPE ext_attributes nonrec_flag optional_type_parameters type_longident
  PLUSEQ private_flag sig_extension_constructors post_item_attributes
      { let (ext, attrs) = $2 in
        if $3 <> Recursive then _not_expecting(3, "nonrec flag");
        Te.mk (_mkrhs($5, 5)) (List.rev $8) ~params:$4 ~priv:$7
          ~attrs:(attrs @ $9) ~docs:(_symbol_docs ())
        , ext }
;
str_extension_constructors:
    extension_constructor_declaration                     { [$1] }
  | bar_extension_constructor_declaration                 { [$1] }
  | extension_constructor_rebind                          { [$1] }
  | bar_extension_constructor_rebind                      { [$1] }
  | str_extension_constructors bar_extension_constructor_declaration
      { $2 :: $1 }
  | str_extension_constructors bar_extension_constructor_rebind
      { $2 :: $1 }
;
sig_extension_constructors:
    extension_constructor_declaration                     { [$1] }
  | bar_extension_constructor_declaration                 { [$1] }
  | sig_extension_constructors bar_extension_constructor_declaration
      { $2 :: $1 }
;
extension_constructor_declaration:
  | constr_ident generalized_constructor_arguments attributes
      { let args, res = $2 in
        Te.decl (_mkrhs($1, 1)) ~args ?res ~attrs:$3
          ~loc:(_symbol_rloc()) ~info:(_symbol_info ()) }
;
bar_extension_constructor_declaration:
  | BAR constr_ident generalized_constructor_arguments attributes
      { let args, res = $3 in
        Te.decl (_mkrhs($2, 2)) ~args ?res ~attrs:$4
           ~loc:(_symbol_rloc()) ~info:(_symbol_info ()) }
;
extension_constructor_rebind:
  | constr_ident EQUAL constr_longident attributes
      { Te.rebind (_mkrhs($1, 1)) (_mkrhs($3, 3)) ~attrs:$4
          ~loc:(_symbol_rloc()) ~info:(_symbol_info ()) }
;
bar_extension_constructor_rebind:
  | BAR constr_ident EQUAL constr_longident attributes
      { Te.rebind (_mkrhs($2, 2)) (_mkrhs($4, 4)) ~attrs:$5
          ~loc:(_symbol_rloc()) ~info:(_symbol_info ()) }
;

/* "with" constraints (additional type equations over signature components) */

with_constraints:
    with_constraint                             { [$1] }
  | with_constraints AND with_constraint        { $3 :: $1 }
;
with_constraint:
    TYPE optional_type_parameters label_longident with_type_binder
    core_type_no_attr constraints
      { Pwith_type
          (_mkrhs($3, 3),
           (Type.mk (_mkrhs((Longident.last $3), 3))
              ~params:$2
              ~cstrs:(List.rev $6)
              ~manifest:$5
              ~priv:$4
              ~loc:(_symbol_rloc()))) }
    /* used label_longident instead of type_longident to disallow
       functor applications in type path */
  | TYPE optional_type_parameters label_longident COLONEQUAL core_type_no_attr
      { Pwith_typesubst
         (_mkrhs($3, 3),
           (Type.mk (_mkrhs(Longident.last $3, 3))
             ~params:$2
             ~manifest:$5
             ~loc:(_symbol_rloc()))) }
  | MODULE mod_longident EQUAL mod_ext_longident
      { Pwith_module (_mkrhs($2, 2), _mkrhs($4, 4)) }
  | MODULE mod_longident COLONEQUAL mod_ext_longident
      { Pwith_modsubst (_mkrhs($2, 2), _mkrhs($4, 4)) }
;
with_type_binder:
    EQUAL          { Public }
  | EQUAL PRIVATE  { Private }
;

/* Polymorphic types */

typevar_list:
        QUOTE ident                             { [_mkrhs($2, 2)] }
      | typevar_list QUOTE ident                { _mkrhs($3, 3) :: $1 }
;
poly_type:
        core_type
          { $1 }
      | typevar_list DOT core_type
          { _mktyp(Ptyp_poly(List.rev $1, $3)) }
;
poly_type_no_attr:
        core_type_no_attr
          { $1 }
      | typevar_list DOT core_type_no_attr
          { _mktyp(Ptyp_poly(List.rev $1, $3)) }
;

/* Core types */

core_type:
    core_type_no_attr
      { $1 }
  | core_type attribute
      { Typ.attr $1 $2 }
;
core_type_no_attr:
    core_type2 %prec MINUSGREATER
      { $1 }
  | core_type2 AS QUOTE ident
      { _mktyp(Ptyp_alias($1, $4)) }
;
core_type2:
    simple_core_type_or_tuple
      { $1 }
  | QUESTION LIDENT COLON core_type2 MINUSGREATER core_type2
      { let param = _extra_rhs_core_type($4, 4) in
        _mktyp (Ptyp_arrow(Optional $2 , param, $6)) }
  | OPTLABEL core_type2 MINUSGREATER core_type2
      { let param = _extra_rhs_core_type ($2, 2) in
        _mktyp(Ptyp_arrow(Optional $1 , param, $4))
      }
  | LIDENT COLON core_type2 MINUSGREATER core_type2
      { let param = _extra_rhs_core_type($3, 3) in
        _mktyp(Ptyp_arrow(Labelled $1, param, $5)) }
  | core_type2 MINUSGREATER core_type2
      { let param = _extra_rhs_core_type($1, 1) in
        _mktyp(Ptyp_arrow(Nolabel, param, $3)) }
;

simple_core_type:
    simple_core_type2  %prec below_HASH
      { $1 }
  | LPAREN core_type_comma_list RPAREN %prec below_HASH
      { match $2 with [sty] -> sty | _ -> raise Parsing.Parse_error }
;

simple_core_type2:
    QUOTE ident
      { _mktyp(Ptyp_var $2) }
  | UNDERSCORE
      { _mktyp(Ptyp_any) }
  | type_longident
      { _mktyp(Ptyp_constr(_mkrhs($1, 1), [])) }
  | simple_core_type2 type_longident
      { _mktyp(Ptyp_constr(_mkrhs($2, 2), [$1])) }
  | LPAREN core_type_comma_list RPAREN type_longident
      { _mktyp(Ptyp_constr(_mkrhs($4, 4), List.rev $2)) }
  | LESS meth_list GREATER
      { let (f, c) = $2 in _mktyp(Ptyp_object (f, c)) }
  | LESS GREATER
      { _mktyp(Ptyp_object ([], Closed)) }
  | HASH class_longident
      { _mktyp(Ptyp_class(_mkrhs($2, 2), [])) }
  | simple_core_type2 HASH class_longident
      { _mktyp(Ptyp_class(_mkrhs($3, 3), [$1])) }
  | LPAREN core_type_comma_list RPAREN HASH class_longident
      { _mktyp(Ptyp_class(_mkrhs($5, 5), List.rev $2)) }
  | LBRACKET tag_field RBRACKET
      { _mktyp(Ptyp_variant([$2], Closed, None)) }
/* PR#3835: this is not LR(1), would need lookahead=2
  | LBRACKET simple_core_type RBRACKET
      { _mktyp(Ptyp_variant([$2], Closed, None)) }
*/
  | LBRACKET BAR row_field_list RBRACKET
      { _mktyp(Ptyp_variant(List.rev $3, Closed, None)) }
  | LBRACKET row_field BAR row_field_list RBRACKET
      { _mktyp(Ptyp_variant($2 :: List.rev $4, Closed, None)) }
  | LBRACKETGREATER opt_bar row_field_list RBRACKET
      { _mktyp(Ptyp_variant(List.rev $3, Open, None)) }
  | LBRACKETGREATER RBRACKET
      { _mktyp(Ptyp_variant([], Open, None)) }
  | LBRACKETLESS opt_bar row_field_list RBRACKET
      { _mktyp(Ptyp_variant(List.rev $3, Closed, Some [])) }
  | LBRACKETLESS opt_bar row_field_list GREATER name_tag_list RBRACKET
      { _mktyp(Ptyp_variant(List.rev $3, Closed, Some (List.rev $5))) }
  | LPAREN MODULE ext_attributes package_type RPAREN
      { _wrap_typ_attrs (_reloc_typ $4) $3 }
  | extension
      { _mktyp (Ptyp_extension $1) }
;
package_type:
    module_type { _mktyp (Ptyp_package (package_type_of_module_type $1)) }
;
row_field_list:
    row_field                                   { [$1] }
  | row_field_list BAR row_field                { $3 :: $1 }
;
row_field:
    tag_field                          { $1 }
  | simple_core_type                   { Rf.inherit_ ~loc:(_symbol_rloc ()) $1 }
;
tag_field:
    name_tag OF opt_ampersand amper_type_list attributes
      { let loc = _symbol_rloc () in
        let attrs = add_info_attrs (_symbol_info ()) $5 in
        Rf.tag ~loc ~attrs (_mkrhs($1, 1)) $3 (List.rev $4) }
  | name_tag attributes
      { let loc = _symbol_rloc () in
        let attrs = add_info_attrs (_symbol_info ()) $2 in
        Rf.tag ~loc ~attrs (_mkrhs($1, 1)) true [] }
;
opt_ampersand:
    AMPERSAND                                   { true }
  | /* empty */                                 { false }
;
amper_type_list:
    core_type_no_attr                           { [$1] }
  | amper_type_list AMPERSAND core_type_no_attr { $3 :: $1 }
;
name_tag_list:
    name_tag                                    { [$1] }
  | name_tag_list name_tag                      { $2 :: $1 }
;
simple_core_type_or_tuple:
    simple_core_type { $1 }
  | simple_core_type STAR core_type_list
      { _mktyp(Ptyp_tuple($1 :: List.rev $3)) }
;
core_type_comma_list:
    core_type                              { [$1] }
  | core_type_comma_list COMMA core_type   { $3 :: $1 }
;
core_type_list:
    simple_core_type                       { [$1] }
  | core_type_list STAR simple_core_type   { $3 :: $1 }
;
meth_list:
    field_semi meth_list
      { let (f, c) = $2 in ($1 :: f, c) }
  | inherit_field_semi meth_list
      { let (f, c) = $2 in ($1 :: f, c) }
  | field_semi                             { [$1], Closed }
  | field                                  { [$1], Closed }
  | inherit_field_semi                     { [$1], Closed }
  | simple_core_type                       {
        let loc = _symbol_rloc () in          [Of.inherit_ ~loc $1], Closed }
  | DOTDOT                                 { [], Open }
;
field:
  label COLON poly_type_no_attr attributes
    { let loc = _symbol_rloc () in
      let attrs = add_info_attrs (_symbol_info ()) $4 in
      Of.tag ~loc ~attrs (_mkrhs($1, 1)) $3 }
;

field_semi:
  label COLON poly_type_no_attr attributes SEMI attributes
    { let loc = _symbol_rloc () in
      let info =
        match _rhs_info(4) with
        | Some _ as info_before_semi -> info_before_semi
        | None -> _symbol_info()
      in
      let attrs = add_info_attrs info ($4 @ $6) in
      Of.tag ~loc ~attrs (_mkrhs($1, 1)) $3 }
;

inherit_field_semi:
  simple_core_type SEMI { Of.inherit_ ~loc:(_symbol_rloc ()) $1 }

label:
    LIDENT                                      { $1 }
;

/* Constants */

constant:
  | INT          { let (n, m) = $1 in Pconst_integer (n, m) }
  | CHAR         { Pconst_char $1 }
  | STRING       { let (s, d) = $1 in Pconst_string (s, d) }
  | FLOAT        { let (f, m) = $1 in Pconst_float (f, m) }
;
signed_constant:
    constant     { $1 }
  | MINUS INT    { let (n, m) = $2 in Pconst_integer("-" ^ n, m) }
  | MINUS FLOAT  { let (f, m) = $2 in Pconst_float("-" ^ f, m) }
  | PLUS INT     { let (n, m) = $2 in Pconst_integer (n, m) }
  | PLUS FLOAT   { let (f, m) = $2 in Pconst_float(f, m) }
;

/* Identifiers and long identifiers */

ident:
    UIDENT                                      { $1 }
  | LIDENT                                      { $1 }
;
val_ident:
    LIDENT                                      { $1 }
  | LPAREN operator RPAREN                      { $2 }
  | LPAREN operator error                       { _unclosed("(", 1, ")", 3) }
  | LPAREN error                                { _expecting(2, "operator") }
  | LPAREN MODULE error                         { _expecting(3, "module-expr") }
;
operator:
    PREFIXOP                                    { $1 }
  | INFIXOP0                                    { $1 }
  | INFIXOP1                                    { $1 }
  | INFIXOP2                                    { $1 }
  | INFIXOP3                                    { $1 }
  | INFIXOP4                                    { $1 }
  | DOTOP LPAREN RPAREN                         { "."^ $1 ^"()" }
  | DOTOP LPAREN RPAREN LESSMINUS               { "."^ $1 ^ "()<-" }
  | DOTOP LBRACKET RBRACKET                     { "."^ $1 ^"[]" }
  | DOTOP LBRACKET RBRACKET LESSMINUS           { "."^ $1 ^ "[]<-" }
  | DOTOP LBRACE RBRACE                         { "."^ $1 ^"{}" }
  | DOTOP LBRACE RBRACE LESSMINUS               { "."^ $1 ^ "{}<-" }
  | HASHOP                                      { $1 }
  | BANG                                        { "!" }
  | PLUS                                        { "+" }
  | PLUSDOT                                     { "+." }
  | MINUS                                       { "-" }
  | MINUSDOT                                    { "-." }
  | STAR                                        { "*" }
  | EQUAL                                       { "=" }
  | LESS                                        { "<" }
  | GREATER                                     { ">" }
  | OR                                          { "or" }
  | BARBAR                                      { "||" }
  | AMPERSAND                                   { "&" }
  | AMPERAMPER                                  { "&&" }
  | COLONEQUAL                                  { ":=" }
  | PLUSEQ                                      { "+=" }
  | PERCENT                                     { "%" }
;
constr_ident:
    UIDENT                                      { $1 }
  | LBRACKET RBRACKET                           { "[]" }
  | LPAREN RPAREN                               { "()" }
  | LPAREN COLONCOLON RPAREN                    { "::" }
  | FALSE                                       { "false" }
  | TRUE                                        { "true" }
;

val_longident:
    val_ident                                   { Lident $1 }
  | mod_longident DOT val_ident                 { Ldot($1, $3) }
;
constr_longident:
    mod_longident       %prec below_DOT         { $1 }
  | mod_longident DOT LPAREN COLONCOLON RPAREN  { Ldot($1,"::") }
  | LBRACKET RBRACKET                           { Lident "[]" }
  | LPAREN RPAREN                               { Lident "()" }
  | LPAREN COLONCOLON RPAREN                    { Lident "::" }
  | FALSE                                       { Lident "false" }
  | TRUE                                        { Lident "true" }
;
label_longident:
    LIDENT                                      { Lident $1 }
  | mod_longident DOT LIDENT                    { Ldot($1, $3) }
;
type_longident:
    LIDENT                                      { Lident $1 }
  | mod_ext_longident DOT LIDENT                { Ldot($1, $3) }
;
mod_longident:
    UIDENT                                      { Lident $1 }
  | mod_longident DOT UIDENT                    { Ldot($1, $3) }
;
mod_ext_longident:
    UIDENT                                      { Lident $1 }
  | mod_ext_longident DOT UIDENT                { Ldot($1, $3) }
  | mod_ext_longident LPAREN mod_ext_longident RPAREN { lapply $1 $3 }
;
mty_longident:
    ident                                       { Lident $1 }
  | mod_ext_longident DOT ident                 { Ldot($1, $3) }
;
clty_longident:
    LIDENT                                      { Lident $1 }
  | mod_ext_longident DOT LIDENT                { Ldot($1, $3) }
;
class_longident:
    LIDENT                                      { Lident $1 }
  | mod_longident DOT LIDENT                    { Ldot($1, $3) }
;

/* Toplevel directives */

toplevel_directive:
    HASH ident
    { _mk_directive (_mkrhs($2, 2)) None }
  | HASH ident toplevel_directive_argument
    { _mk_directive (_mkrhs($2, 2)) (Some $3) }
;

toplevel_directive_argument:
  | STRING        { let (s, _) = $1 in
                    _mk_directive_arg (Pdir_string s) }
  | INT           { let (n, m) = $1 in
                    _mk_directive_arg (Pdir_int (n ,m)) }
  | val_longident { _mk_directive_arg (Pdir_ident $1) }
  | mod_longident { _mk_directive_arg (Pdir_ident $1) }
  | FALSE         { _mk_directive_arg (Pdir_bool false) }
  | TRUE          { _mk_directive_arg (Pdir_bool true) }
;

/* Miscellaneous */

name_tag:
    BACKQUOTE ident                             { $2 }
;
rec_flag:
    /* empty */                                 { Nonrecursive }
  | REC                                         { Recursive }
;
nonrec_flag:
    /* empty */                                 { Recursive }
  | NONREC                                      { Nonrecursive }
;
direction_flag:
    TO                                          { Upto }
  | DOWNTO                                      { Downto }
;
private_flag:
    /* empty */                                 { Public }
  | PRIVATE                                     { Private }
;
mutable_flag:
    /* empty */                                 { Immutable }
  | MUTABLE                                     { Mutable }
;
virtual_flag:
    /* empty */                                 { Concrete }
  | VIRTUAL                                     { Virtual }
;
private_virtual_flags:
    /* empty */  { Public, Concrete }
  | PRIVATE { Private, Concrete }
  | VIRTUAL { Public, Virtual }
  | PRIVATE VIRTUAL { Private, Virtual }
  | VIRTUAL PRIVATE { Private, Virtual }
;
override_flag:
    /* empty */                                 { Fresh }
  | BANG                                        { Override }
;
opt_bar:
    /* empty */                                 { () }
  | BAR                                         { () }
;
opt_semi:
  | /* empty */                                 { () }
  | SEMI                                        { () }
;
subtractive:
  | MINUS                                       { "-" }
  | MINUSDOT                                    { "-." }
;
additive:
  | PLUS                                        { "+" }
  | PLUSDOT                                     { "+." }
;

/* Attributes and extensions */

single_attr_id:
    LIDENT { $1 }
  | UIDENT { $1 }
  | AND { "and" }
  | AS { "as" }
  | ASSERT { "assert" }
  | BEGIN { "begin" }
  | CLASS { "class" }
  | CONSTRAINT { "constraint" }
  | DO { "do" }
  | DONE { "done" }
  | DOWNTO { "downto" }
  | ELSE { "else" }
  | END { "end" }
  | EXCEPTION { "exception" }
  | EXTERNAL { "external" }
  | FALSE { "false" }
  | FOR { "for" }
  | FUN { "fun" }
  | FUNCTION { "function" }
  | FUNCTOR { "functor" }
  | IF { "if" }
  | IN { "in" }
  | INCLUDE { "include" }
  | INHERIT { "inherit" }
  | INITIALIZER { "initializer" }
  | LAZY { "lazy" }
  | LET { "let" }
  | MATCH { "match" }
  | METHOD { "method" }
  | MODULE { "module" }
  | MUTABLE { "mutable" }
  | NEW { "new" }
  | NONREC { "nonrec" }
  | OBJECT { "object" }
  | OF { "of" }
  | OPEN { "open" }
  | OR { "or" }
  | PRIVATE { "private" }
  | REC { "rec" }
  | SIG { "sig" }
  | STRUCT { "struct" }
  | THEN { "then" }
  | TO { "to" }
  | TRUE { "true" }
  | TRY { "try" }
  | TYPE { "type" }
  | VAL { "val" }
  | VIRTUAL { "virtual" }
  | WHEN { "when" }
  | WHILE { "while" }
  | WITH { "with" }
/* mod/land/lor/lxor/lsl/lsr/asr are not supported for now */
;

attr_id:
    single_attr_id { mkloc $1 (_symbol_rloc()) }
  | single_attr_id DOT attr_id { mkloc ($1 ^ "." ^ $3.txt) (_symbol_rloc())}
;
attribute:
  LBRACKETAT attr_id payload RBRACKET { Attr.mk ~loc:(_symbol_rloc()) $2 $3 }
;
post_item_attribute:
  LBRACKETATAT attr_id payload RBRACKET { Attr.mk ~loc:(_symbol_rloc()) $2 $3 }
;
floating_attribute:
  LBRACKETATATAT attr_id payload RBRACKET
      { _mark_symbol_docs ();
        Attr.mk ~loc:(_symbol_rloc()) $2 $3 }
;
post_item_attributes:
    /* empty */  { [] }
  | post_item_attribute post_item_attributes { $1 :: $2 }
;
attributes:
    /* empty */{ [] }
  | attribute attributes { $1 :: $2 }
;
ext_attributes:
    /* empty */  { None, [] }
  | attribute attributes { None, $1 :: $2 }
  | PERCENT attr_id attributes { Some $2, $3 }
;
extension:
  LBRACKETPERCENT attr_id payload RBRACKET { ($2, $3) }
;
item_extension:
  LBRACKETPERCENTPERCENT attr_id payload RBRACKET { ($2, $3) }
;
payload:
    structure { PStr $1 }
  | COLON signature { PSig $2 }
  | COLON core_type { PTyp $2 }
  | QUESTION pattern { PPat ($2, None) }
  | QUESTION pattern WHEN seq_expr { PPat ($2, Some $4) }
;
%%
