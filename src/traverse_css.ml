open! Core
open! Ppxlib
open Css_jane

let map_loc (v, loc) ~f = f v, loc

module Identifier_kind = struct
  module T = struct
    type t =
      | Class
      | Id
      | Variable
    [@@deriving compare, sexp]
  end

  include T
  include Comparable.Make (T)
end

module Prev_delimeter = struct
  type t =
    | Other
    | Dot
    | Colon
end

open Prev_delimeter

(* Hashes ".a" within :not(.a). We are taking a "not hash by default" approach rather than
   immediately hashing every identifier in the AST to not break existing apps. *)
let hash_the_contents_of_these_selector_functions =
  String.Set.of_list [ "not"; "has"; "where"; "is" ]
;;

let potentially_accidental_hashing_error_message ~identifiers =
  sprintf
    {|The following identifiers will be hashed when they previously were not: %s
If your application relies on the identifiers, being unhashed, this could
potentially break the styles of your app. To enable hashing, please use
[%%css.hash_variables] instead of [%%css].

To disable hashing an keep the default behavior you can make use of the [~rewrite]
flag. To ppx_css. You can do so by adding:

~dont_hash:[%s]
  |}
    (Sexp.to_string_hum ([%sexp_of: String.Set.t] identifiers))
    (Set.to_list identifiers
     |> List.map ~f:(fun s -> [%string {|"%{s}"|}])
     |> String.concat ~sep:"; ")
;;

let rec fold_c_value ~allow_potential_accidental_hashing ~rewrite ~f prev v =
  match prev, v with
  | _, ((Component_value.Delim "." as d), loc) -> Dot, (d, loc)
  | _, ((Delim ":" as d), loc) -> Colon, (d, loc)
  | Dot, (Ident s, loc) -> Other, (Ident (f (`Class s) loc), loc)
  | _, (Hash s, loc) -> Other, (Hash (f (`Id s) loc), loc)
  | Colon, (Function (((fn_name, _) as first), second), loc)
    when Set.mem hash_the_contents_of_these_selector_functions fn_name ->
    let f ((`Class i | `Id i | `Variable i) as case) loc =
      match Map.mem rewrite i with
      | true -> f case loc
      | false when allow_potential_accidental_hashing -> f case loc
      | false ->
        Location.raise_errorf
          ~loc
          "%s"
          (potentially_accidental_hashing_error_message
             ~identifiers:(String.Set.singleton i))
    in
    let component_value =
      let second =
        Tuple2.map_fst
          second
          ~f:(map_component_value_list ~allow_potential_accidental_hashing ~rewrite ~f)
      in
      Component_value.Function (first, second)
    in
    Other, (component_value, loc)
  | _, other -> Other, other

and map_component_value_list ~allow_potential_accidental_hashing ~f ~rewrite =
  List.folding_map
    ~init:Other
    ~f:(fold_c_value ~allow_potential_accidental_hashing ~rewrite ~f)
;;

let map_stylesheet ~allow_potential_accidental_hashing ~rewrite stylesheet ~f =
  let mapper =
    object
      inherit Css_jane.Traverse.map as super

      method! style_rule (style_rule : Style_rule.t) =
        let prelude =
          map_loc
            style_rule.prelude
            ~f:
              (List.folding_map
                 ~init:Other
                 ~f:(fold_c_value ~allow_potential_accidental_hashing ~rewrite ~f))
        in
        super#style_rule { style_rule with prelude }

      method! declaration (declaration : Declaration.t) =
        let name, loc = declaration.name in
        let name =
          match String.is_prefix name ~prefix:"--" with
          | true -> f (`Variable name) loc
          | false -> name
        in
        let name = name, loc in
        let declaration = { declaration with name } in
        super#declaration declaration

      method! component_value (component_value : Component_value.t) =
        let component_value =
          match component_value with
          | Function ((("var", _) as first), (((Ident s, loc) :: remaining, _) as second))
            when String.is_prefix s ~prefix:"--" ->
            let second =
              Tuple2.map_fst second ~f:(fun _ ->
                (Component_value.Ident (f (`Variable s) loc), loc) :: remaining)
            in
            Component_value.Function (first, second)
          | _ -> component_value
        in
        super#component_value component_value
    end
  in
  mapper#stylesheet stylesheet
;;

(* Iterates over class, id, and variables in the file *)
let iter_identifiers ~allow_potential_accidental_hashing ~rewrite stylesheet ~f =
  let f ((`Class identifier | `Id identifier | `Variable identifier) as case) _loc =
    f case;
    identifier
  in
  (ignore : Stylesheet.t -> unit)
    (map_stylesheet stylesheet ~rewrite ~allow_potential_accidental_hashing ~f)
;;

let fix_identifier =
  let swap_kebab_case =
    String.map ~f:(function
      | '-' -> '_'
      | x -> x)
  in
  Fn.compose swap_kebab_case (String.chop_prefix_if_exists ~prefix:"--")
;;

let raise_due_to_collision_with_existing_ident ~loc ~original_identifier ~fixed_identifier
  =
  Location.raise_errorf
    ~loc
    "Unsafe collision of names. Cannot rename '%s' to '%s' because '%s' already exists"
    original_identifier
    fixed_identifier
    fixed_identifier
;;

let raise_due_to_collision_with_newly_minted_identifier
      ~loc
      ~previously_computed_ocaml_identifier
      ~original_identifier
      ~fixed_identifier
  =
  Location.raise_errorf
    ~loc
    "Unsafe collisions of names. Two different unsafe names map to the same fixed name \
     which might lead to unintended results. Both '%s' and '%s' map to '%s'"
    previously_computed_ocaml_identifier
    original_identifier
    fixed_identifier
;;

let get_ocaml_identifier original_identifier ~loc ~original_identifiers ~fixed_to_original
  =
  match String.exists original_identifier ~f:(Char.equal '-') with
  | false -> original_identifier
  | true ->
    let fixed_identifier = fix_identifier original_identifier in
    (match Set.mem original_identifiers fixed_identifier with
     | true ->
       raise_due_to_collision_with_existing_ident
         ~loc
         ~original_identifier
         ~fixed_identifier
     | false ->
       let previously_computed_ocaml_identifier =
         Hashtbl.find fixed_to_original fixed_identifier
       in
       (match previously_computed_ocaml_identifier with
        | None ->
          Hashtbl.set fixed_to_original ~key:fixed_identifier ~data:original_identifier;
          fixed_identifier
        | Some previously_computed_ocaml_identifier ->
          (match String.equal previously_computed_ocaml_identifier original_identifier with
           | true -> fixed_identifier
           | false ->
             raise_due_to_collision_with_newly_minted_identifier
               ~loc
               ~previously_computed_ocaml_identifier
               ~original_identifier
               ~fixed_identifier)))
;;

let string_constant ~loc l =
  let open (val Ast_builder.make loc) in
  pexp_constant (Pconst_string (l, loc, Some ""))
;;

let raise_if_unused_rewrite_identifiers ~loc ~unused_rewrite_identifiers =
  match Hash_set.is_empty unused_rewrite_identifiers with
  | true -> ()
  | false ->
    Location.raise_errorf
      ~loc
      "Unused keys: %s"
      (Sexp.to_string_hum ([%sexp_of: String.Hash_set.t] unused_rewrite_identifiers))
;;

let raise_if_unused_prefixes ~loc ~used_prefixes ~dont_hash_prefixes =
  let unused_prefixes =
    Set.diff dont_hash_prefixes (String.Set.of_hash_set used_prefixes)
  in
  match Set.is_empty unused_prefixes with
  | true -> ()
  | false ->
    Location.raise_errorf
      ~loc
      "Unused prefixes: %s"
      (Sexp.to_string_hum ([%sexp_of: String.Set.t] unused_prefixes))
;;

module Transform = struct
  type result =
    { css_string : string
    ; identifier_mapping : (Identifier_kind.Set.t * expression) String.Table.t
    ; reference_order : expression list
    }

  let f
        ~allow_potential_accidental_hashing
        ~loc
        ~pos
        ~options:
        { Options.rewrite; css_string = s; dont_hash_prefixes; stylesheet_location = _ }
    =
    let parsed = Stylesheet.of_string ~pos s in
    let hash =
      let filename = Ppx_here_expander.expand_filename pos.pos_fname in
      let hash_prefix = 10 in
      parsed
      |> Stylesheet.sexp_of_t
      |> Sexp.to_string_mach
      |> sprintf "%s:%s" filename
      |> Md5.digest_string
      |> Md5.to_hex
      |> Fn.flip String.prefix hash_prefix
    in
    let identifier_mapping = String.Table.create () in
    let original_identifiers = String.Hash_set.create () in
    let reference_order = ref Reversed_list.[] in
    let unused_rewrite_identifiers = String.Hash_set.of_list (Map.keys rewrite) in
    let newly_hashed_variables = String.Hash_set.create () in
    iter_identifiers ~allow_potential_accidental_hashing ~rewrite parsed ~f:(function
      | `Class _ | `Id _ -> ()
      | `Variable identifier -> Hash_set.add newly_hashed_variables identifier);
    let unfixed_variables =
      Set.diff (String.Set.of_hash_set newly_hashed_variables) (Map.key_set rewrite)
    in
    (match Set.is_empty unfixed_variables with
     | true -> ()
     | false when allow_potential_accidental_hashing -> ()
     | false ->
       Location.raise_errorf
         ~loc
         "%s"
         (potentially_accidental_hashing_error_message ~identifiers:unfixed_variables));
    iter_identifiers
      ~allow_potential_accidental_hashing
      ~rewrite
      parsed
      ~f:(fun (`Class identifier | `Id identifier | `Variable identifier) ->
        Hash_set.add original_identifiers identifier;
        Hash_set.remove unused_rewrite_identifiers identifier);
    raise_if_unused_rewrite_identifiers ~loc ~unused_rewrite_identifiers;
    let original_identifiers = Set.of_hash_set (module String) original_identifiers in
    let fixed_to_original = String.Table.create () in
    let used_prefixes = String.Hash_set.create () in
    let is_matched_by_a_prefix =
      let dont_hash_prefixes =
        (* Sorted from most general to least general (i.e. shorter prefix to longest
           prefix)*)
        List.sort
          ~compare:(fun a b -> Int.compare (String.length a) (String.length b))
          (Set.to_list dont_hash_prefixes)
      in
      fun identifier ->
        List.exists dont_hash_prefixes ~f:(fun prefix ->
          match String.is_prefix identifier ~prefix with
          | true ->
            Hash_set.add used_prefixes prefix;
            true
          | false -> false)
    in
    let sheet =
      map_stylesheet
        ~rewrite
        ~allow_potential_accidental_hashing
        parsed
        ~f:(fun ((`Class identifier | `Id identifier | `Variable identifier) as token) loc
             ->
               let ocaml_identifier =
                 get_ocaml_identifier identifier ~loc ~original_identifiers ~fixed_to_original
               in
               let ret, expression =
                 match Map.find rewrite identifier with
                 | None ->
                   (match is_matched_by_a_prefix identifier with
                    | false ->
                      let ret = sprintf "%s_hash_%s" identifier hash in
                      ret, string_constant ~loc ret
                    | true -> identifier, string_constant ~loc identifier)
                 | Some
                     { pexp_desc = Pexp_constant (Pconst_string (identifier, _, _))
                     ; pexp_loc = loc
                     ; _
                     } -> identifier, string_constant ~loc identifier
                 | Some expression_to_use ->
                   (reference_order := Reversed_list.(expression_to_use :: !reference_order));
                   "%s", expression_to_use
               in
               let identifier_kind =
                 match token with
                 | `Class _ -> Identifier_kind.Class
                 | `Id _ -> Id
                 | `Variable _ -> Variable
               in
               Hashtbl.update identifier_mapping ocaml_identifier ~f:(fun prev ->
                 match prev with
                 | None -> Identifier_kind.Set.singleton identifier_kind, expression
                 | Some (prev, expression) -> Set.add prev identifier_kind, expression);
               ret)
    in
    raise_if_unused_prefixes ~loc ~used_prefixes ~dont_hash_prefixes;
    let css_string = Stylesheet.to_string_hum sheet in
    let css_string =
      sprintf
        "\n/* %s */\n\n%s"
        (Ppx_here_expander.expand_filename pos.pos_fname)
        (String.strip css_string)
    in
    { css_string
    ; identifier_mapping
    ; reference_order = Reversed_list.rev !reference_order
    }
  ;;
end

module Get_all_identifiers = struct
  type result =
    { variables : string list
    ; identifiers : (string * [ `Both | `Only_class | `Only_id ]) list
    }
  [@@deriving sexp_of]

  let get_all_original_identifiers stylesheet =
    let out = String.Hash_set.create () in
    iter_identifiers
      (* NOTE: Safe to set [allow_potential_accidental_hashing] to true since the css inliner
         change should happen on top/after the change that potentially makes hashing new
         variables dangerous.
      *)
      ~allow_potential_accidental_hashing:true
      ~rewrite:String.Map.empty
      stylesheet
      ~f:(fun (`Class identifier | `Id identifier | `Variable identifier) ->
        Hash_set.add out identifier);
    String.Set.of_hash_set out
  ;;

  let f stylesheet =
    let identifiers = String.Table.create () in
    let variables = String.Hash_set.create () in
    let fixed_to_original = String.Table.create () in
    let original_identifiers = get_all_original_identifiers stylesheet in
    iter_identifiers
      ~allow_potential_accidental_hashing:true
      ~rewrite:String.Map.empty
      stylesheet
      ~f:(fun current_item ->
        let (`Class identifier | `Id identifier | `Variable identifier) = current_item in
        let fixed_identifier =
          get_ocaml_identifier
            identifier
            ~loc:Location.none
            ~original_identifiers
            ~fixed_to_original
        in
        match current_item with
        | `Variable _ -> Hash_set.add variables fixed_identifier
        | `Class _ ->
          Hashtbl.update identifiers fixed_identifier ~f:(function
            | None | Some `Only_class -> `Only_class
            | Some `Only_id | Some `Both -> `Both)
        | `Id _ ->
          Hashtbl.update identifiers fixed_identifier ~f:(function
            | None | Some `Only_id -> `Only_id
            | Some `Only_class | Some `Both -> `Both));
    { identifiers = Hashtbl.to_alist identifiers; variables = Hash_set.to_list variables }
  ;;
end

module For_testing = struct
  let map_style_sheet s ~allow_potential_accidental_hashing ~rewrite ~f =
    map_stylesheet s ~f ~allow_potential_accidental_hashing ~rewrite
  ;;
end
