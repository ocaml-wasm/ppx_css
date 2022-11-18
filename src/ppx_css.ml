open! Core
open! Ppxlib
open Css_jane
module Options = Options

let disable_warning_32 ~loc =
  let open (val Ast_builder.make loc) in
  attribute
    ~name:(Located.mk "ocaml.warning")
    ~payload:(PStr [ pstr_eval (estring "-32") [] ])
;;

let loc_ghoster =
  object
    inherit Ast_traverse.map as super
    method! location location = super#location { location with loc_ghost = true }
  end
;;

let var_builder_signature ~loc ~variables : signature_item option =
  let open (val Ast_builder.make loc) in
  match List.is_empty variables with
  | true -> None
  | false ->
    let variables = List.sort variables ~compare:String.compare in
    let set_function_type =
      List.fold_right
        variables
        ~init:[%type: unit -> Virtual_dom.Vdom.Attr.t]
        ~f:(fun variable_name acc ->
          ptyp_arrow (Optional variable_name) [%type: string] acc)
    in
    let set =
      psig_value
        (value_description ~name:(Located.mk "set") ~prim:[] ~type_:set_function_type)
    in
    let type_ = pmty_signature [ set ] in
    let out =
      psig_module (module_declaration ~name:(Located.mk (Some "Variables")) ~type_)
    in
    Some out
;;

let module_type_of_identifiers
      ~loc
      ~(identifiers : (string * [ `Both | `Only_class | `Only_id ]) list)
      ~variables
  =
  let open (val Ast_builder.make loc) in
  let var_builder = var_builder_signature ~loc ~variables in
  let identifier_keys = identifiers |> List.map ~f:Tuple2.get1 in
  let string_module =
    let signature_items =
      identifier_keys @ variables
      |> List.dedup_and_sort ~compare:String.compare
      |> List.map ~f:(fun ident ->
        let type_ = [%type: string] in
        let name = Located.mk ident in
        psig_value (value_description ~name ~type_ ~prim:[]))
    in
    let type_ = pmty_signature signature_items in
    psig_module (module_declaration ~name:(Located.mk (Some "For_referencing")) ~type_)
  in
  let identifier_signature_items =
    identifiers
    (* The [dedup_and_sort] below only really cares about the [dedup] behaviour. We need
       to dedup the list so that we don't end up with duplicate declarations in the
       signature. The sorting is a nice bonus for output stability. *)
    |> List.dedup_and_sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
    |> List.concat_map ~f:(fun (ident, case) ->
      let type_ = [%type: Virtual_dom.Vdom.Attr.t] in
      let name = Located.mk ident in
      match case with
      | `Only_class | `Only_id ->
        [ psig_value (value_description ~name ~type_ ~prim:[]) ]
      | `Both ->
        let id_name = Located.mk [%string "%{ident}_id"] in
        let class_name = Located.mk [%string "%{ident}_class"] in
        let error_attribute =
          let error_message =
            pexp_constant
              (Pconst_string
                 ( sprintf
                     "An id and a class both share the name \"%s\" which is \
                      ambiguous. Please use \"%s_id\" or \"%s_class\" instead."
                     ident
                     ident
                     ident
                 , loc
                 , None ))
          in
          let payload = PStr [ pstr_eval [%expr unsafe [%e error_message]] [] ] in
          attribute ~name:(Located.mk "alert") ~payload
        in
        [ psig_value
            { (value_description ~name ~type_ ~prim:[]) with
              pval_attributes = [ error_attribute ]
            }
        ; psig_value (value_description ~name:id_name ~type_ ~prim:[])
        ; psig_value (value_description ~name:class_name ~type_ ~prim:[])
        ])
  in
  let base = string_module :: identifier_signature_items in
  Option.value_map var_builder ~f:(fun var_builder -> var_builder :: base) ~default:base
  |> List.map ~f:loc_ghoster#signature_item
;;

let css_string_to_expression ~loc ~css_string ~(reference_order : expression list) =
  let open (val Ast_builder.make loc) in
  (* The [Some ""] means that the string will use the multiline string literal
     syntax, but with no termination identifier. *)
  let string_constant l = pexp_constant (Pconst_string (l, loc, Some "")) in
  match List.is_empty reference_order with
  | true -> string_constant css_string
  | false ->
    let args =
      List.map (string_constant css_string :: reference_order) ~f:(fun arg ->
        Nolabel, arg)
    in
    pexp_apply [%expr Base.Printf.sprintf] args
;;

let create_type_info_function ~loc ~stylesheet_location =
  let open (val Ast_builder.make loc) in
  let name =
    (* We give ppat_var the same exact location as the css string so that
       MerlinTypeOf thinks the string is of the the type with all of the
       that ppx_css can take. *)
    let open (val Ast_builder.make stylesheet_location) in
    ppat_var (Located.mk "__type_info_for_ppx_css")
  in
  pstr_value
    Nonrecursive
    [ value_binding
        ~pat:
          [%pat?
                 ([%p name] :
                    ?rewrite:(string * string) list
                  -> ?dont_hash:string list
                  -> ?dont_hash_prefixes:string list
                  -> string
                  -> unit)]
        ~expr:[%expr fun ?rewrite:_ ?dont_hash:_ ?dont_hash_prefixes:_ _ -> ()]
    ]
;;

module Mint_hygenic_identifier = struct
  type result =
    { expression : expression
    ; pattern : pattern
    }

  let f ~loc ?prefix () =
    let open (val Ast_builder.make loc) in
    let string = gen_symbol ?prefix () in
    let expression = pexp_ident (Located.mk (Lident string)) in
    let pattern = ppat_var (Located.mk string) in
    { expression; pattern }
  ;;
end

(* Produces:
   {[
     module Variables = struct
       let set ?var1 ?var_2 () =
         let acc = [] in
         let acc = match var1 with | None -> acc
                                   | Some value -> ("--var1", value) :: acc
         in
         Vdom.Attr.__vars_kebabless acc
       ;;
     end
   ]} *)
let var_builder_structure ~loc ~variables : structure_item option =
  let open (val Ast_builder.make loc) in
  match List.is_empty variables with
  | true -> None
  | false ->
    let variables =
      List.sort variables ~compare:(fun (a, _) (b, _) -> String.compare a b)
    in
    let { Mint_hygenic_identifier.expression = acc_expression; pattern = acc_pattern } =
      Mint_hygenic_identifier.f ~loc ~prefix:"ppx_css_acc" ()
    in
    let initial_acc_binding ~in_ =
      (* produces {[ let acc = [] in in_ ]} *)
      pexp_let Nonrecursive [ value_binding ~pat:acc_pattern ~expr:[%expr []] ] in_
    in
    let inline_folding_of_acc ~in_ =
      (* Produces:

         {[
           let acc = match var1 with
             | None -> acc
             | Some value -> ("--var1", value) :: acc
           in
           let acc = match var2 with
             | None -> acc
             | Some value -> ("--var2", value) :: acc
           in
           in_ ]}
      *)
      let { Mint_hygenic_identifier.expression = value_expression
          ; pattern = value_pattern
          }
        =
        Mint_hygenic_identifier.f ~loc ~prefix:"ppx_css_value" ()
      in
      List.fold_right
        variables
        ~init:in_
        ~f:(fun (ocaml_identifier, variable_expression) acc ->
          let ocaml_identifier_expression =
            pexp_ident (Located.mk (Lident ocaml_identifier))
          in
          let expr =
            [%expr
              match [%e ocaml_identifier_expression] with
              | None -> [%e acc_expression]
              | Some [%p value_pattern] ->
                ([%e variable_expression], [%e value_expression]) :: [%e acc_expression]]
          in
          pexp_let Nonrecursive [ value_binding ~pat:acc_pattern ~expr ] acc)
    in
    let call_to_vdom_attr_acc =
      [%expr Virtual_dom.Vdom.Attr.__css_vars_no_kebabs [%e acc_expression]]
    in
    let set_function_body =
      initial_acc_binding ~in_:(inline_folding_of_acc ~in_:call_to_vdom_attr_acc)
    in
    let set_function_expression =
      List.fold_right
        variables
        ~init:[%expr fun () -> [%e set_function_body]]
        ~f:(fun (k, _) acc -> pexp_fun (Optional k) None (ppat_var (Located.mk k)) acc)
    in
    let set =
      pstr_value
        Nonrecursive
        [ value_binding ~pat:[%pat? set] ~expr:set_function_expression ]
    in
    let expr = pmod_structure [ set ] in
    let out = pstr_module (module_binding ~name:(Located.mk (Some "Variables")) ~expr) in
    Some out
;;

let validate_no_collisions_after_warnings_and_rewrites
      ~loc
      ~(identifiers : (label * [ `Both | `Only_class | `Only_id ]) list)
  =
  (* This function only checks that there are no collisions from the potentially newly
     minted names that occur from occurrances on `Both. Since original ^ "_id" and
     original ^ "_class"  are added, these conditions must be checked for. *)
  let all_identifiers = String.Set.of_list (List.map identifiers ~f:Tuple2.get1) in
  let newly_minted_names =
    String.Set.of_list
      (List.concat_map identifiers ~f:(fun (label, case) ->
         match case with
         | `Both -> [ label ^ "_id"; label ^ "_class" ]
         | `Only_class | `Only_id -> []))
  in
  let conflicts = Set.inter all_identifiers newly_minted_names in
  match Set.is_empty conflicts with
  | true -> ()
  | false ->
    Location.raise_errorf
      ~loc
      "Collision between identifiers! This occurs when a disambiguated identifier \
       matches an existing identifier. To resolve this, rename the following \
       identifiers: %s."
      (Sexp.to_string_hum ([%sexp_of: String.Set.t] conflicts))
;;

(* Creates the module struct that - given "var1" and "var2" as variables, and "classname_1"
   as an identifier  will create the below code:

   {[
     module Default = struct
       module Variables = struct
         let set ?var1 ?var2 () =
           let acc = [] in
           let acc = match var1 with
             | None -> acc
             | Some value -> ("--var1", value) :: acc
           in
           let acc = match var2 with
             | None -> acc
             | Some value -> ("--var2", value) :: acc
           in
           Vdom.Attr.__vars_kebabless acc
         ;;
       end
       let classname_1 = "classname-1_hash_2341"
     end
   ]}*)
let create_default_module_struct
      ~loc
      ~(identifiers : (label * ([ `Both | `Only_class | `Only_id ] * expression)) list)
      ~variables
  : module_expr
  =
  validate_no_collisions_after_warnings_and_rewrites
    ~loc
    ~identifiers:(List.map identifiers ~f:(Tuple2.map_snd ~f:Tuple2.get1));
  let open (val Ast_builder.make loc) in
  let variable_module = var_builder_structure ~loc ~variables in
  let identifiers_structure_items =
    identifiers
    |> List.concat_map ~f:(fun (original_name, (case, e)) ->
      match case with
      | `Both ->
        let id_string = original_name ^ "_id" in
        let class_string = original_name ^ "_class" in
        let original_pattern = ppat_var (Located.mk original_name) in
        let id_pattern = ppat_var (Located.mk id_string) in
        let class_pattern = ppat_var (Located.mk class_string) in
        [ [%stri let [%p original_pattern] = Virtual_dom.Vdom.Attr.empty]
        ; [%stri let [%p class_pattern] = Virtual_dom.Vdom.Attr.class_ [%e e]]
        ; [%stri let [%p id_pattern] = Virtual_dom.Vdom.Attr.id [%e e]]
        ]
      | `Only_class ->
        [ [%stri
          let [%p ppat_var (Located.mk original_name)] =
            Virtual_dom.Vdom.Attr.class_ [%e e]
          ;;]
        ]
      | `Only_id ->
        [ [%stri
          let [%p ppat_var (Located.mk original_name)] =
            Virtual_dom.Vdom.Attr.id [%e e]
          ;;]
        ])
  in
  let identifiers_and_variables_as_string =
    List.map identifiers ~f:(fun (label, (_, expression)) -> label, expression)
    @ variables
    |> List.map ~f:(fun (k, e) -> [%stri let [%p ppat_var (Located.mk k)] = [%e e]])
  in
  let string_module =
    pstr_module
      (module_binding
         ~name:(Located.mk (Some "For_referencing"))
         ~expr:(pmod_structure identifiers_and_variables_as_string))
  in
  let base = string_module :: identifiers_structure_items in
  let structure_items =
    Option.value_map variable_module ~default:base ~f:(fun variable_module ->
      variable_module :: base)
  in
  pmod_structure structure_items |> loc_ghoster#module_expr
;;

let generate_struct_from_css_string_and_options
      ~allow_potential_accidental_hashing
      ~loc
      ~options
  =
  let open (val Ast_builder.make loc) in
  let { Traverse_css.Transform.css_string; identifier_mapping; reference_order } =
    Traverse_css.Transform.f
      ~allow_potential_accidental_hashing
      ~loc
      ~pos:loc.loc_start
      ~options
  in
  let identifier_mapping = Hashtbl.to_alist identifier_mapping in
  let css_string = css_string_to_expression ~loc ~css_string ~reference_order in
  let register = [%stri let () = Inline_css.Private.append [%e css_string]] in
  let type_info_function =
    create_type_info_function ~loc ~stylesheet_location:options.stylesheet_location
  in
  let variables =
    List.filter_map identifier_mapping ~f:(fun (k, (identifier_kinds, e)) ->
      match Set.mem identifier_kinds Variable with
      | false -> None
      | true -> Some (k, e))
  in
  let identifiers =
    List.filter_map identifier_mapping ~f:(fun (k, (identifier_kinds, e)) ->
      match Set.mem identifier_kinds Class, Set.mem identifier_kinds Id with
      | true, true -> Some (k, (`Both, e))
      | true, false -> Some (k, (`Only_class, e))
      | false, true -> Some (k, (`Only_id, e))
      | false, false -> None)
  in
  let t_sig =
    module_type_of_identifiers
      ~loc
      ~identifiers:(List.map identifiers ~f:(Tuple2.map_snd ~f:Tuple2.get1))
      ~variables:(List.map variables ~f:fst)
    |> pmty_signature
  in
  let t_module = create_default_module_struct ~loc ~identifiers ~variables in
  pmod_structure
    [ pstr_attribute (disable_warning_32 ~loc)
    ; register
    ; type_info_function
    ; [%stri module type S = [%m t_sig]]
    ; [%stri type t = (module S)]
    ; [%stri module Default : S = [%m t_module]]
    ; [%stri include Default]
    ; [%stri let default : t = (module Default)]
    ]
;;

let generate_struct ~allow_potential_accidental_hashing ~loc ~path:_ (expr : expression) =
  let loc = { loc with loc_ghost = true } in
  let expr = loc_ghoster#expression expr in
  let options = Options.parse expr in
  generate_struct_from_css_string_and_options
    ~allow_potential_accidental_hashing
    ~loc
    ~options
;;

let create_sig_from_idents
      ~loc
      ~(identifiers : (string * [> `Both | `Only_class | `Only_id ]) list)
      ~variables
  =
  let open (val Ast_builder.make loc) in
  validate_no_collisions_after_warnings_and_rewrites ~loc ~identifiers;
  let basic_sig = module_type_of_identifiers ~loc ~identifiers ~variables in
  pmty_signature
    ([ [%sigi: module type S = [%m pmty_signature basic_sig]]
     ; [%sigi: type t = (module S)]
     ; [%sigi: val default : t]
     ]
     @ basic_sig)
;;

module For_css_inliner = struct
  let gen_struct ~options =
    let buffer = Buffer.create 1024 in
    let loc = Location.none in
    generate_struct_from_css_string_and_options
      (* NOTE: It is safe to set [allow_potential_accidental_hashing] to true since the css inliner
         change should happen on top/after the change that potentially makes hashing new
         variables dangerous.
      *)
      ~allow_potential_accidental_hashing:true
      ~loc
      ~options
    |> Pprintast.module_expr (Format.formatter_of_buffer buffer);
    Buffer.contents buffer
  ;;

  open Traverse_css

  let gen_sig css =
    let buffer = Buffer.create 1024 in
    let stylesheet = Stylesheet.of_string css in
    let { Get_all_identifiers.identifiers; variables } =
      Get_all_identifiers.f stylesheet
    in
    let mli_as_an_ast =
      create_sig_from_idents ~loc:Location.none ~identifiers ~variables
    in
    Pprintast.module_type (Format.formatter_of_buffer buffer) mli_as_an_ast;
    Buffer.contents buffer
  ;;
end

let ml_extension =
  Extension.declare
    "css"
    Extension.Context.module_expr
    Ast_pattern.(single_expr_payload __)
    (generate_struct ~allow_potential_accidental_hashing:false)
;;

let ml_extension_with_safe_to_hash_variables_names =
  Extension.declare
    "css.hash_variables"
    Extension.Context.module_expr
    Ast_pattern.(single_expr_payload __)
    (generate_struct ~allow_potential_accidental_hashing:true)
;;

let () =
  Driver.register_transformation
    "css"
    ~extensions:[ ml_extension; ml_extension_with_safe_to_hash_variables_names ]
;;

module For_testing = struct
  let generate_struct = generate_struct ~loc:Location.none ~path:()
  let map_style_sheet = Traverse_css.For_testing.map_style_sheet

  module Traverse_css = Traverse_css
end
